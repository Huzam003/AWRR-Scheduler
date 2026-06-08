/* SPDX-License-Identifier: GPL-2.0 */
/*
 * AWRR (Adaptive Weighted Round-Robin) Scheduler - Internal Header
 *
 * kernel/sched/awrr.h
 *
 * Defines constants, data structures, and helper declarations for the
 * AWRR scheduling class. This scheduler sits between RT and CFS in the
 * scheduling class hierarchy and dynamically adjusts per-task weights
 * based on observed runtime behavior (CPU-bound vs I/O-bound).
 */
#ifndef _KERNEL_SCHED_AWRR_H
#define _KERNEL_SCHED_AWRR_H

#include <linux/sched.h>
#include <linux/list.h>
#include <linux/types.h>

/*
 * Weight bounds and defaults.
 * Weight determines a task's share of CPU in the WRR cycle.
 */
#define AWRR_WEIGHT_MIN		1
#define AWRR_WEIGHT_MAX		10
#define AWRR_WEIGHT_DEFAULT	5

/*
 * EWMA smoothing factor for behavior metrics.
 * alpha = ALPHA_NUM / ALPHA_DENOM = 3/10 = 0.3
 * new_val = (ALPHA_NUM * observed + (DENOM - ALPHA_NUM) * old) / DENOM
 */
#define AWRR_EWMA_ALPHA_NUM	3
#define AWRR_EWMA_ALPHA_DENOM	10

/*
 * Epoch length in scheduler ticks.
 * At each epoch boundary, behavior classification and weight
 * adjustment are performed.
 */
#define AWRR_EPOCH_TICKS	100

/*
 * Anti-starvation threshold in nanoseconds.
 * If a task waits longer than this without running, it receives
 * an emergency weight boost to AWRR_WEIGHT_MAX.
 */
#define AWRR_STARVE_THRESH_NS	(500ULL * NSEC_PER_MSEC)

/*
 * Short-lived process threshold in ticks.
 * Tasks that have existed for fewer than this many ticks keep
 * their default weight to avoid classification overhead.
 */
#define AWRR_SHORT_LIVED_TICKS	10

/*
 * Behavior score thresholds (in tenths).
 * Score > 7 (0.7) => CPU-bound  => decrease weight
 * Score < 3 (0.3) => I/O-bound  => increase weight
 * Otherwise       => mixed      => move toward default
 */
#define AWRR_CPU_BOUND_THRESH	7
#define AWRR_IO_BOUND_THRESH	3

/*
 * Base time slice in nanoseconds (10ms).
 * Actual slice = BASE_SLICE * weight / total_weight.
 */
#define AWRR_BASE_SLICE_NS	(10ULL * NSEC_PER_MSEC)

/*
 * Behavior score component weights (in tenths, must sum to 10).
 * S = (BURST_W * B + YIELD_W * (10 - Y) + IOWAIT_W * (10 - W)) / 10
 */
#define AWRR_BURST_WEIGHT	5
#define AWRR_YIELD_WEIGHT	3
#define AWRR_IOWAIT_WEIGHT	2

/*
 * Per-task AWRR scheduling entity.
 * Embedded in task_struct as task_struct.awrr.
 */
struct sched_awrr_entity {
	struct list_head	run_list;	/* node in awrr_rq task list */

	unsigned int		weight;		/* current adaptive weight [1..10] */
	unsigned int		pre_boost_weight;	/* saved weight prior to starvation boost */
	unsigned int		penalty_epochs;		/* remaining epochs of gaming penalty */
	unsigned int		time_slice;	/* remaining slice in ns */

	u64			exec_start;	/* timestamp when current run began */
	u64			sum_exec_runtime;/* total CPU time consumed (ns) */
	u64			prev_sum_exec;	/* sum_exec at start of epoch */

	u64			wait_start;	/* timestamp when waiting began */
	u64			sum_wait_time;	/* cumulative wait time (ns) */

	u64			io_wait_start;	/* timestamp when I/O wait began */
	u64			sum_io_wait;	/* cumulative I/O wait time (ns) */
	u64			epoch_io_wait;	/* I/O wait accumulated this epoch */
	u64			epoch_exec;	/* execution time this epoch */

	/* Smoothed behavior metrics (stored in tenths, 0..10) */
	unsigned int		burst_ratio;	/* B: actual_runtime / quantum */
	unsigned int		yield_freq;	/* Y: yields per epoch (normalized) */
	unsigned int		io_wait_ratio;	/* W: io_wait / (io_wait + exec) */
	unsigned int		behavior_score;	/* S: composite score */

	unsigned int		nr_yields;	/* yield count this epoch */
	unsigned int		tick_count;	/* ticks since last epoch */
	unsigned int		total_ticks;	/* lifetime tick count */
	unsigned int		epoch_count;	/* number of completed epochs */

	unsigned int		starve_boosted;	/* 1 if emergency boosted */
	unsigned int		on_rq;		/* currently on AWRR runqueue */
	unsigned int		initialized;	/* entity has been set up */
};

/*
 * Per-CPU AWRR run queue.
 * Embedded in struct rq as rq.awrr.
 */
struct awrr_rq {
	struct list_head	task_list;	/* circular list of runnable tasks */
	unsigned int		nr_running;	/* number of runnable AWRR tasks */
	unsigned int		total_weight;	/* sum of all task weights */
};

/* awrr.c: initialization */
extern void init_awrr_rq(struct awrr_rq *awrr_rq);

/* awrr.c: sysctl registration */
extern void __init awrr_sysctl_init(void);

#endif /* _KERNEL_SCHED_AWRR_H */
