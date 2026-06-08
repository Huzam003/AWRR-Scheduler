// SPDX-License-Identifier: GPL-2.0
/*
 * AWRR (Adaptive Weighted Round-Robin) Scheduler
 *
 * kernel/sched/awrr.c
 *
 * A scheduling class that dynamically adjusts per-task weights based on
 * observed CPU burst ratio, voluntary yield frequency, and I/O wait ratio.
 * Sits between RT and CFS in the scheduling hierarchy.
 *
 * Key design points:
 *   - All math is integer (no floating point); metrics stored in tenths.
 *   - EWMA smoothing (alpha=0.3) prevents oscillation.
 *   - Anti-starvation: tasks waiting > 500ms get an emergency boost.
 *   - Short-lived tasks (< 10 ticks) keep default weight.
 */

#include "sched.h"
#include "awrr.h"

#include <linux/slab.h>
#include <linux/sysctl.h>
#include <linux/random.h>

/*
 * Tunable parameters (exposed via /proc/sys/kernel/sched_awrr/).
 */
static unsigned int sysctl_awrr_base_slice_ns = AWRR_BASE_SLICE_NS;
static unsigned int sysctl_awrr_ewma_alpha_num = AWRR_EWMA_ALPHA_NUM;
static unsigned int sysctl_awrr_epoch_ticks = AWRR_EPOCH_TICKS;
static unsigned int sysctl_awrr_starve_thresh_ns = AWRR_STARVE_THRESH_NS;
static unsigned int sysctl_awrr_cpu_bound_thresh = AWRR_CPU_BOUND_THRESH;
static unsigned int sysctl_awrr_io_bound_thresh = AWRR_IO_BOUND_THRESH;

/* Min/max bounds for sysctl validation */
static int awrr_min_slice = 1000000;		/* 1ms */
static int awrr_max_slice = 100000000;		/* 100ms */
static int awrr_min_alpha = 1;
static int awrr_max_alpha = 9;
static int awrr_min_epoch = 10;
static int awrr_max_epoch = 10000;
static int awrr_min_starve = 100000000;		/* 100ms */
static int awrr_max_starve = 2000000000;	/* 2s */
static int awrr_min_thresh = 1;
static int awrr_max_thresh = 9;

/* -----------------------------------------------------------------------
 * Helper: get the awrr_rq from a struct rq
 * ----------------------------------------------------------------------- */
static inline struct awrr_rq *awrr_rq_of_rq(struct rq *rq)
{
	return &rq->awrr;
}

/* -----------------------------------------------------------------------
 * Helper: get the sched_awrr_entity from a task_struct
 * ----------------------------------------------------------------------- */
static inline struct sched_awrr_entity *awrr_se_of(struct task_struct *p)
{
	return &p->awrr;
}

/* -----------------------------------------------------------------------
 * Helper: get the task_struct from a sched_awrr_entity run_list
 * ----------------------------------------------------------------------- */
static inline struct task_struct *awrr_task_of(struct sched_awrr_entity *se)
{
	return container_of(se, struct task_struct, awrr);
}

/* -----------------------------------------------------------------------
 * Helper: get task from a list_head in the awrr_rq task_list
 * ----------------------------------------------------------------------- */
static inline struct task_struct *awrr_task_of_list(struct list_head *entry)
{
	struct sched_awrr_entity *se;

	se = list_entry(entry, struct sched_awrr_entity, run_list);
	return awrr_task_of(se);
}

/* -----------------------------------------------------------------------
 * Run queue initialization
 * ----------------------------------------------------------------------- */
void init_awrr_rq(struct awrr_rq *awrr_rq)
{
	INIT_LIST_HEAD(&awrr_rq->task_list);
	awrr_rq->nr_running = 0;
	awrr_rq->total_weight = 0;
}

/* -----------------------------------------------------------------------
 * Entity initialization
 * ----------------------------------------------------------------------- */
static void init_awrr_entity(struct sched_awrr_entity *se)
{
	INIT_LIST_HEAD(&se->run_list);
	se->weight = AWRR_WEIGHT_DEFAULT;
	se->time_slice = 0;
	se->exec_start = 0;
	se->sum_exec_runtime = 0;
	se->prev_sum_exec = 0;
	se->wait_start = 0;
	se->sum_wait_time = 0;
	se->io_wait_start = 0;
	se->sum_io_wait = 0;
	se->epoch_io_wait = 0;
	se->epoch_exec = 0;
	se->burst_ratio = 5;	/* start neutral */
	se->yield_freq = 0;
	se->io_wait_ratio = 5;	/* start neutral */
	se->behavior_score = 5;	/* start neutral */
	se->nr_yields = 0;
	se->tick_count = 0;
	se->total_ticks = 0;
	se->epoch_count = 0;
	se->starve_boosted = 0;
	se->pre_boost_weight = AWRR_WEIGHT_DEFAULT;
	se->penalty_epochs = 0;
	se->on_rq = 0;
	se->initialized = 1;
}

/* -----------------------------------------------------------------------
 * EWMA update (fixed-point, tenths precision)
 *
 * result = (ALPHA_NUM * new_val + (DENOM - ALPHA_NUM) * old_val) / DENOM
 * ----------------------------------------------------------------------- */
static inline unsigned int awrr_ewma_update(unsigned int old_val,
					     unsigned int new_val)
{
	return (sysctl_awrr_ewma_alpha_num * new_val +
		(AWRR_EWMA_ALPHA_DENOM - sysctl_awrr_ewma_alpha_num) * old_val)
		/ AWRR_EWMA_ALPHA_DENOM;
}

/* -----------------------------------------------------------------------
 * Behavior metric: CPU burst ratio
 *
 * B = (actual_runtime_this_epoch * 10) / allocated_quantum_this_epoch
 * Values in tenths [0..10], capped at 10.
 * ----------------------------------------------------------------------- */
static void awrr_update_burst_ratio(struct sched_awrr_entity *se)
{
	unsigned int raw_burst;
	u64 quantum;

	quantum = se->time_slice;
	if (!quantum)
		quantum = sysctl_awrr_base_slice_ns;

	if (!quantum) {
		raw_burst = 5;
	} else {
		raw_burst = (unsigned int)((se->epoch_exec * 10ULL) / quantum);
		if (raw_burst > 10)
			raw_burst = 10;
	}

	se->burst_ratio = awrr_ewma_update(se->burst_ratio, raw_burst);
}

/* -----------------------------------------------------------------------
 * Behavior metric: voluntary yield frequency (normalized)
 *
 * Y_norm = (nr_yields * 10) / epoch_ticks, capped at 10.
 * ----------------------------------------------------------------------- */
static void awrr_update_yield_freq(struct sched_awrr_entity *se)
{
	unsigned int raw_yield;
	unsigned int epoch = sysctl_awrr_epoch_ticks;

	if (!epoch)
		epoch = AWRR_EPOCH_TICKS;

	raw_yield = (se->nr_yields * 10) / epoch;
	if (raw_yield > 10)
		raw_yield = 10;

	se->yield_freq = awrr_ewma_update(se->yield_freq, raw_yield);
}

/* -----------------------------------------------------------------------
 * Behavior metric: I/O wait ratio
 *
 * W = (io_wait_time * 10) / (io_wait_time + exec_time), in tenths.
 * ----------------------------------------------------------------------- */
static void awrr_update_io_wait_ratio(struct sched_awrr_entity *se)
{
	unsigned int raw_io;
	u64 total;

	total = se->epoch_io_wait + se->epoch_exec;
	if (!total) {
		raw_io = 0;
	} else {
		raw_io = (unsigned int)((se->epoch_io_wait * 10ULL) / total);
		if (raw_io > 10)
			raw_io = 10;
	}

	se->io_wait_ratio = awrr_ewma_update(se->io_wait_ratio, raw_io);
}

/* -----------------------------------------------------------------------
 * Composite behavior score
 *
 * S = (BURST_W * B + YIELD_W * (10 - Y) + IOWAIT_W * (10 - W)) / 10
 *
 * High S => CPU-bound; Low S => I/O-bound.
 * ----------------------------------------------------------------------- */
static void awrr_compute_behavior_score(struct sched_awrr_entity *se)
{
	unsigned int score;

	score = AWRR_BURST_WEIGHT * se->burst_ratio +
		AWRR_YIELD_WEIGHT * (10 - se->yield_freq) +
		AWRR_IOWAIT_WEIGHT * (10 - se->io_wait_ratio);
	score /= 10;

	if (score > 10)
		score = 10;

	se->behavior_score = score;
}

/* -----------------------------------------------------------------------
 * Weight adjustment (called at each epoch boundary)
 *
 * CPU-bound (S > 7):  weight -= 1, min WEIGHT_MIN
 * I/O-bound (S < 3):  weight += 1, max WEIGHT_MAX
 * Mixed:              move toward WEIGHT_DEFAULT by 1
 * ----------------------------------------------------------------------- */
static void awrr_adjust_weight(struct awrr_rq *awrr_rq,
			       struct sched_awrr_entity *se)
{
	unsigned int old_weight = se->weight;

	/* Clear any previous starvation boost and restore original weight */
	if (se->starve_boosted) {
		unsigned int post_starve_weight = se->weight;
		se->weight = se->pre_boost_weight;
		se->starve_boosted = 0;
		if (se->on_rq && post_starve_weight != se->weight)
			awrr_rq->total_weight += se->weight - post_starve_weight;
		old_weight = se->weight;
	}

	/* Skip classification for short-lived tasks */
	if (se->total_ticks < AWRR_SHORT_LIVED_TICKS)
		return;

	/* Handle active gaming penalty */
	if (se->penalty_epochs > 0) {
		se->penalty_epochs--;
		se->weight = AWRR_WEIGHT_MIN + 1; /* Clamp weight at 2 */
		if (se->on_rq && old_weight != se->weight)
			awrr_rq->total_weight += se->weight - old_weight;
		return;
	}

	/* Anti-Gaming Detection:
	 * If a process consumes substantial CPU (burst_ratio > 6) but voluntary yields
	 * excessively (yield_freq > 6), it is attempting to manipulate behavior classification.
	 */
	if (se->yield_freq > 6 && se->burst_ratio > 6) {
		se->weight = AWRR_WEIGHT_MIN + 1; /* Apply penalty weight (2) */
		se->penalty_epochs = 3;           /* Lock weight for 3 epochs */
		if (se->on_rq && old_weight != se->weight)
			awrr_rq->total_weight += se->weight - old_weight;
		return;
	}

	if (se->behavior_score > sysctl_awrr_cpu_bound_thresh) {
		if (se->weight > AWRR_WEIGHT_MIN)
			se->weight--;
	} else if (se->behavior_score < sysctl_awrr_io_bound_thresh) {
		if (se->weight < AWRR_WEIGHT_MAX)
			se->weight++;
	} else {
		/* Mixed: move toward default */
		if (se->weight > AWRR_WEIGHT_DEFAULT)
			se->weight--;
		else if (se->weight < AWRR_WEIGHT_DEFAULT)
			se->weight++;
	}

	/* Update total_weight on the rq if weight changed */
	if (se->on_rq && old_weight != se->weight)
		awrr_rq->total_weight += se->weight - old_weight;
}

/* -----------------------------------------------------------------------
 * Anti-starvation check
 *
 * If a task has been waiting longer than STARVE_THRESH, boost its weight
 * to WEIGHT_MAX for one epoch.
 * ----------------------------------------------------------------------- */
static void awrr_check_starvation(struct rq *rq, struct awrr_rq *awrr_rq)
{
	struct sched_awrr_entity *se;
	struct list_head *pos;
	u64 now = rq_clock_task(rq);
	unsigned int old_weight;

	list_for_each(pos, &awrr_rq->task_list) {
		se = list_entry(pos, struct sched_awrr_entity, run_list);

		if (!se->wait_start)
			continue;

		if ((now - se->wait_start) > sysctl_awrr_starve_thresh_ns) {
			if (!se->starve_boosted) {
				se->pre_boost_weight = se->weight;
				se->weight = AWRR_WEIGHT_MAX;
				se->starve_boosted = 1;
				if (se->on_rq)
					awrr_rq->total_weight +=
						se->weight - se->pre_boost_weight;
			}
		}
	}
}

/* -----------------------------------------------------------------------
 * Time slice calculation
 *
 * slice = BASE_SLICE * weight / total_weight
 * With rounding: (base * weight + total/2) / total
 * Minimum slice of 1ms.
 * ----------------------------------------------------------------------- */
static unsigned int awrr_calc_timeslice(struct sched_awrr_entity *se,
					struct awrr_rq *awrr_rq)
{
	u64 slice;
	unsigned int total = awrr_rq->total_weight;

	if (!total)
		return sysctl_awrr_base_slice_ns;

	slice = (u64)sysctl_awrr_base_slice_ns * se->weight;
	slice = (slice + total / 2) / total;

	/* 
	 * Side-Channel Mitigation: Introduce pseudo-random timing jitter.
	 * Adds or subtracts up to 10% of the calculated timeslice value.
	 */
	if (slice > 2 * NSEC_PER_MSEC) {
		u32 max_jitter = (u32)(slice / 10);
		u32 jitter = get_random_u32() % (max_jitter + 1);
		if (get_random_u32() % 2)
			slice += jitter;
		else
			slice -= jitter;
	}

	/* Guarantee a minimum slice of 1ms */
	if (slice < NSEC_PER_MSEC)
		slice = NSEC_PER_MSEC;

	return (unsigned int)slice;
}

/* -----------------------------------------------------------------------
 * update_curr_awrr: update current task's runtime accounting
 * ----------------------------------------------------------------------- */
static void update_curr_awrr(struct rq *rq)
{
	struct task_struct *curr = rq->curr;
	struct sched_awrr_entity *se;
	u64 now, delta_exec;

	if (!task_has_awrr_policy(curr))
		return;

	se = awrr_se_of(curr);
	now = rq_clock_task(rq);

	if (unlikely(!se->exec_start))
		return;

	delta_exec = now - se->exec_start;
	if (unlikely((s64)delta_exec <= 0))
		return;

	se->exec_start = now;
	se->sum_exec_runtime += delta_exec;
	se->epoch_exec += delta_exec;
}

/* -----------------------------------------------------------------------
 * enqueue_task_awrr: add task to the AWRR run queue
 * ----------------------------------------------------------------------- */
static void
enqueue_task_awrr(struct rq *rq, struct task_struct *p, int flags)
{
	struct sched_awrr_entity *se = awrr_se_of(p);
	struct awrr_rq *awrr_rq = awrr_rq_of_rq(rq);

	if (!se->initialized)
		init_awrr_entity(se);

	if (se->on_rq)
		return;

	list_add_tail(&se->run_list, &awrr_rq->task_list);
	se->on_rq = 1;
	awrr_rq->nr_running++;
	awrr_rq->total_weight += se->weight;
	add_nr_running(rq, 1);

	/* Record when this task started waiting */
	se->wait_start = rq_clock_task(rq);

	/* Calculate initial time slice */
	se->time_slice = awrr_calc_timeslice(se, awrr_rq);

	/* Track I/O wait: if waking from sleep, accumulate I/O wait time */
	if ((flags & ENQUEUE_WAKEUP) && se->io_wait_start) {
		u64 io_delta = rq_clock_task(rq) - se->io_wait_start;

		se->sum_io_wait += io_delta;
		se->epoch_io_wait += io_delta;
		se->io_wait_start = 0;
	}
}

/* -----------------------------------------------------------------------
 * dequeue_task_awrr: remove task from the AWRR run queue
 * ----------------------------------------------------------------------- */
static void
dequeue_task_awrr(struct rq *rq, struct task_struct *p, int flags)
{
	struct sched_awrr_entity *se = awrr_se_of(p);
	struct awrr_rq *awrr_rq = awrr_rq_of_rq(rq);

	if (!se->on_rq)
		return;

	update_curr_awrr(rq);

	list_del_init(&se->run_list);
	se->on_rq = 0;
	awrr_rq->nr_running--;
	awrr_rq->total_weight -= se->weight;
	sub_nr_running(rq, 1);

	se->wait_start = 0;

	/* Mark start of I/O wait if task is sleeping */
	if (flags & DEQUEUE_SLEEP)
		se->io_wait_start = rq_clock_task(rq);
}

/* -----------------------------------------------------------------------
 * pick_next_task_awrr: select the next task to run (O(1) - head of list)
 * ----------------------------------------------------------------------- */
static struct task_struct *
pick_next_task_awrr(struct rq *rq)
{
	struct awrr_rq *awrr_rq = awrr_rq_of_rq(rq);
	struct sched_awrr_entity *se;

	if (!awrr_rq->nr_running)
		return NULL;

	se = list_first_entry_or_null(&awrr_rq->task_list,
				      struct sched_awrr_entity, run_list);
	if (!se)
		return NULL;

	return awrr_task_of(se);
}

/* -----------------------------------------------------------------------
 * set_next_task_awrr: prepare task to become the current running task
 * ----------------------------------------------------------------------- */
static void
set_next_task_awrr(struct rq *rq, struct task_struct *p, bool first)
{
	struct sched_awrr_entity *se = awrr_se_of(p);

	se->exec_start = rq_clock_task(rq);

	/* Clear wait accounting since task is now running */
	if (se->wait_start) {
		u64 wait_delta = rq_clock_task(rq) - se->wait_start;

		se->sum_wait_time += wait_delta;
		se->wait_start = 0;
	}
}

/* -----------------------------------------------------------------------
 * put_prev_task_awrr: called when task is being switched out
 *
 * Update runtime accounting and move to tail for round-robin rotation.
 * ----------------------------------------------------------------------- */
static void
put_prev_task_awrr(struct rq *rq, struct task_struct *p)
{
	struct sched_awrr_entity *se = awrr_se_of(p);
	struct awrr_rq *awrr_rq = awrr_rq_of_rq(rq);

	update_curr_awrr(rq);

	if (se->on_rq) {
		/* Move to tail for round-robin rotation */
		list_move_tail(&se->run_list, &awrr_rq->task_list);
		/* Start waiting again */
		se->wait_start = rq_clock_task(rq);
	}
}

/* -----------------------------------------------------------------------
 * task_tick_awrr: called on each timer tick for AWRR tasks
 *
 * - Update burst tracking
 * - At epoch boundary: classify behavior, adjust weight, check starvation
 * - Check if time slice has expired
 * ----------------------------------------------------------------------- */
static void
task_tick_awrr(struct rq *rq, struct task_struct *p, int queued)
{
	struct sched_awrr_entity *se = awrr_se_of(p);
	struct awrr_rq *awrr_rq = awrr_rq_of_rq(rq);

	update_curr_awrr(rq);

	se->tick_count++;
	se->total_ticks++;

	/* Epoch boundary: perform classification and weight adjustment */
	if (se->tick_count >= sysctl_awrr_epoch_ticks) {
		awrr_update_burst_ratio(se);
		awrr_update_yield_freq(se);
		awrr_update_io_wait_ratio(se);
		awrr_compute_behavior_score(se);
		awrr_adjust_weight(awrr_rq, se);
		awrr_check_starvation(rq, awrr_rq);

		/* Reset per-epoch counters */
		se->tick_count = 0;
		se->nr_yields = 0;
		se->epoch_io_wait = 0;
		se->epoch_exec = 0;
		se->prev_sum_exec = se->sum_exec_runtime;
		se->epoch_count++;

		/* Recalculate time slice with new weight */
		se->time_slice = awrr_calc_timeslice(se, awrr_rq);
	}

	/* Check if the current time slice has expired */
	if (se->epoch_exec >= se->time_slice) {
		se->time_slice = awrr_calc_timeslice(se, awrr_rq);
		se->epoch_exec = 0;
		resched_curr(rq);
	}
}

/* -----------------------------------------------------------------------
 * check_preempt_curr_awrr: check if a newly woken task should preempt
 *
 * Preempt if the new task has a strictly higher weight.
 * ----------------------------------------------------------------------- */
static void
check_preempt_curr_awrr(struct rq *rq, struct task_struct *p, int flags)
{
	struct sched_awrr_entity *se_curr, *se_new;

	if (rq->curr->sched_class != &awrr_sched_class)
		return;

	se_curr = awrr_se_of(rq->curr);
	se_new = awrr_se_of(p);

	if (se_new->weight > se_curr->weight)
		resched_curr(rq);
}

/* -----------------------------------------------------------------------
 * yield_task_awrr: handle sched_yield() for AWRR tasks
 * ----------------------------------------------------------------------- */
static void yield_task_awrr(struct rq *rq)
{
	struct task_struct *curr = rq->curr;
	struct sched_awrr_entity *se = awrr_se_of(curr);
	struct awrr_rq *awrr_rq = awrr_rq_of_rq(rq);

	se->nr_yields++;

	if (se->on_rq && awrr_rq->nr_running > 1) {
		list_move_tail(&se->run_list, &awrr_rq->task_list);
		se->wait_start = rq_clock_task(rq);
	}

	resched_curr(rq);
}

/* -----------------------------------------------------------------------
 * task_fork_awrr: initialize child's AWRR entity on fork
 * ----------------------------------------------------------------------- */
static void task_fork_awrr(struct task_struct *p)
{
	struct sched_awrr_entity *se = awrr_se_of(p);

	init_awrr_entity(se);
}

/* -----------------------------------------------------------------------
 * task_dead_awrr: cleanup when an AWRR task exits
 * ----------------------------------------------------------------------- */
static void task_dead_awrr(struct task_struct *p)
{
	struct sched_awrr_entity *se = awrr_se_of(p);

	WARN_ON_ONCE(se->on_rq);
}

/* -----------------------------------------------------------------------
 * switched_to_awrr: called when a task switches to AWRR policy
 * ----------------------------------------------------------------------- */
static void
switched_to_awrr(struct rq *rq, struct task_struct *p)
{
	struct sched_awrr_entity *se = awrr_se_of(p);

	if (!se->initialized)
		init_awrr_entity(se);

	if (task_on_rq_queued(p) && rq->curr != p)
		check_preempt_curr_awrr(rq, p, 0);
}

/* -----------------------------------------------------------------------
 * switched_from_awrr: called when a task switches away from AWRR
 * ----------------------------------------------------------------------- */
static void
switched_from_awrr(struct rq *rq, struct task_struct *p)
{
	/*
	 * If the task is still queued on the AWRR rq, it will be properly
	 * dequeued by the core scheduler before being enqueued in the new
	 * class, so no explicit dequeue is needed here.
	 */
}

/* -----------------------------------------------------------------------
 * prio_changed_awrr: called when priority changes while in AWRR
 * ----------------------------------------------------------------------- */
static void
prio_changed_awrr(struct rq *rq, struct task_struct *p, int oldprio)
{
	if (task_on_rq_queued(p) && rq->curr != p)
		check_preempt_curr_awrr(rq, p, 0);
}

/* -----------------------------------------------------------------------
 * get_rr_interval_awrr: return current time slice in jiffies
 * ----------------------------------------------------------------------- */
static unsigned int
get_rr_interval_awrr(struct rq *rq, struct task_struct *p)
{
	struct sched_awrr_entity *se = awrr_se_of(p);
	struct awrr_rq *awrr_rq = awrr_rq_of_rq(rq);
	unsigned int slice_ns;

	slice_ns = awrr_calc_timeslice(se, awrr_rq);

	/* Convert nanoseconds to jiffies, rounding up */
	return (slice_ns + TICK_NSEC - 1) / TICK_NSEC;
}

/* -----------------------------------------------------------------------
 * select_task_rq_awrr: select which CPU a task should run on
 *
 * Uniprocessor focus: return the current CPU.
 * ----------------------------------------------------------------------- */
#ifdef CONFIG_SMP
static int
select_task_rq_awrr(struct task_struct *p, int task_cpu, int flags)
{
	return task_cpu;
}

/* -----------------------------------------------------------------------
 * balance_awrr: SMP load balancing (no-op for uniprocessor focus)
 * ----------------------------------------------------------------------- */
static int
balance_awrr(struct rq *rq, struct task_struct *prev, struct rq_flags *rf)
{
	return sched_stop_runnable(rq) || sched_dl_runnable(rq) ||
	       sched_rt_runnable(rq);
}

/* -----------------------------------------------------------------------
 * pick_task_awrr: pick a task for core scheduling (read-only)
 * ----------------------------------------------------------------------- */
static struct task_struct *
pick_task_awrr(struct rq *rq)
{
	return pick_next_task_awrr(rq);
}
#endif /* CONFIG_SMP */

/* -----------------------------------------------------------------------
 * Scheduling class definition
 * ----------------------------------------------------------------------- */
DEFINE_SCHED_CLASS(awrr) = {
	.enqueue_task		= enqueue_task_awrr,
	.dequeue_task		= dequeue_task_awrr,
	.yield_task		= yield_task_awrr,

	.check_preempt_curr	= check_preempt_curr_awrr,

	.pick_next_task		= pick_next_task_awrr,
	.put_prev_task		= put_prev_task_awrr,
	.set_next_task		= set_next_task_awrr,

#ifdef CONFIG_SMP
	.balance		= balance_awrr,
	.pick_task		= pick_task_awrr,
	.select_task_rq		= select_task_rq_awrr,
	.set_cpus_allowed	= set_cpus_allowed_common,
#endif

	.task_tick		= task_tick_awrr,
	.task_fork		= task_fork_awrr,
	.task_dead		= task_dead_awrr,

	.switched_from		= switched_from_awrr,
	.switched_to		= switched_to_awrr,
	.prio_changed		= prio_changed_awrr,

	.get_rr_interval	= get_rr_interval_awrr,

	.update_curr		= update_curr_awrr,
};

/* -----------------------------------------------------------------------
 * Sysctl interface: /proc/sys/kernel/sched_awrr/
 * ----------------------------------------------------------------------- */
static struct ctl_table awrr_sysctls[] = {
	{
		.procname	= "base_slice_ns",
		.data		= &sysctl_awrr_base_slice_ns,
		.maxlen		= sizeof(unsigned int),
		.mode		= 0644,
		.proc_handler	= proc_dointvec_minmax,
		.extra1		= &awrr_min_slice,
		.extra2		= &awrr_max_slice,
	},
	{
		.procname	= "ewma_alpha_num",
		.data		= &sysctl_awrr_ewma_alpha_num,
		.maxlen		= sizeof(unsigned int),
		.mode		= 0644,
		.proc_handler	= proc_dointvec_minmax,
		.extra1		= &awrr_min_alpha,
		.extra2		= &awrr_max_alpha,
	},
	{
		.procname	= "epoch_ticks",
		.data		= &sysctl_awrr_epoch_ticks,
		.maxlen		= sizeof(unsigned int),
		.mode		= 0644,
		.proc_handler	= proc_dointvec_minmax,
		.extra1		= &awrr_min_epoch,
		.extra2		= &awrr_max_epoch,
	},
	{
		.procname	= "starve_threshold_ns",
		.data		= &sysctl_awrr_starve_thresh_ns,
		.maxlen		= sizeof(unsigned int),
		.mode		= 0644,
		.proc_handler	= proc_dointvec_minmax,
		.extra1		= &awrr_min_starve,
		.extra2		= &awrr_max_starve,
	},
	{
		.procname	= "cpu_bound_threshold",
		.data		= &sysctl_awrr_cpu_bound_thresh,
		.maxlen		= sizeof(unsigned int),
		.mode		= 0644,
		.proc_handler	= proc_dointvec_minmax,
		.extra1		= &awrr_min_thresh,
		.extra2		= &awrr_max_thresh,
	},
	{
		.procname	= "io_bound_threshold",
		.data		= &sysctl_awrr_io_bound_thresh,
		.maxlen		= sizeof(unsigned int),
		.mode		= 0644,
		.proc_handler	= proc_dointvec_minmax,
		.extra1		= &awrr_min_thresh,
		.extra2		= &awrr_max_thresh,
	},
	{}	/* sentinel */
};

void __init awrr_sysctl_init(void)
{
	register_sysctl("kernel/sched_awrr", awrr_sysctls);
}
