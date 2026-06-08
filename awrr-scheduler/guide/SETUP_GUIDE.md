# AWRR Scheduler — Complete Setup Guide

> For: Syed Wasif Ali Shah (242334) — Air University NCSA  
> OS: macOS (Apple Silicon) → Linux VM  
> Target Kernel: Linux 6.1 LTS

---

## Part 1: VM Setup (macOS Apple Silicon)

### 1.1 Install UTM

UTM is free, open-source, and works great on Apple Silicon.

```bash
brew install --cask utm
```

Or download from: https://mac.getutm.app/

### 1.2 Download Ubuntu Server ISO

Download **Ubuntu Server 22.04 LTS ARM64** (important — ARM64, not AMD64):

```
https://cdimage.ubuntu.com/releases/22.04/release/ubuntu-22.04.5-live-server-arm64.iso
```

### 1.3 Create the VM in UTM

1. Open UTM → click **"+"** → **Virtualize** → **Linux**
2. Browse and select the Ubuntu ISO you downloaded
3. Settings:
   - **CPU**: 4 cores
   - **RAM**: 4096 MB (4 GB)
   - **Storage**: 60 GB (kernel source + build needs space)
   - **Network**: Shared Network (default)
4. Click **Save**, then **Start** the VM

### 1.4 Install Ubuntu Server

1. Select **"Install Ubuntu Server"**
2. Language: English
3. Keyboard: Your preference
4. Network: Accept defaults (DHCP)
5. Proxy: Leave blank
6. Mirror: Accept default
7. Storage: **Use entire disk** → Confirm
8. Profile: Set your username/password (remember these!)
9. SSH: **Install OpenSSH server** ← Check this box
10. Featured snaps: Skip all → Done
11. Wait for install → **Reboot Now**
12. When it says "remove installation medium", just press Enter

### 1.5 Set Up SSH Access (Optional but Recommended)

After the VM boots and you log in:

```bash
# Inside the VM — find its IP address
ip addr show | grep "inet "
```

You'll see something like `192.168.64.X`. From your Mac terminal:

```bash
ssh your-username@192.168.64.X
```

This lets you copy-paste commands easily from this guide.

### 1.6 Install Build Dependencies

Run these inside the VM:

```bash
sudo apt update && sudo apt upgrade -y

sudo apt install -y \
    build-essential \
    git \
    flex \
    bison \
    libssl-dev \
    libelf-dev \
    bc \
    dwarves \
    cpio \
    libncurses-dev \
    zstd \
    wget \
    curl \
    rsync \
    python3
```

---

## Part 2: Get Kernel Source

### 2.1 Download Linux 6.1 LTS

```bash
cd ~
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.1.tar.xz
tar xf linux-6.1.tar.xz
cd linux-6.1
```

This will take a few minutes. The extracted source is about 1.3 GB.

### 2.2 Copy AWRR Files into the VM

From your Mac, copy the files using `scp`:

```bash
# Run this from your Mac terminal
# Replace USER and IP with your VM's username and IP

scp -r "/Users/syedwasifalishah/Documents/VS Code/awrr-scheduler" \
    USER@192.168.64.X:~/
```

Now inside the VM you'll have `~/awrr-scheduler/` with all the code.

---

## Part 3: Apply AWRR Patches

Do these steps one by one inside the VM. You're editing the kernel source in `~/linux-6.1/`.

### 3.1 Add the AWRR Policy Constant

Edit `include/uapi/linux/sched.h`:

```bash
nano ~/linux-6.1/include/uapi/linux/sched.h
```

Find the line with `#define SCHED_DEADLINE 6` and add after it:

```c
#define SCHED_AWRR		7
```

Save and exit (Ctrl+O, Enter, Ctrl+X).

### 3.2 Add sched_awrr_entity Struct and Embed in task_struct

Edit `include/linux/sched.h`:

```bash
nano ~/linux-6.1/include/linux/sched.h
```

**Step A:** Find the `struct sched_dl_entity` definition (search with Ctrl+W for `struct sched_dl_entity {`). Scroll to the end of that struct. **After** the closing `};` of `sched_dl_entity`, add:

```c
/*
 * AWRR scheduling entity - Adaptive Weighted Round-Robin
 */
struct sched_awrr_entity {
	struct list_head	run_list;

	unsigned int		weight;
	unsigned int		time_slice;

	u64			exec_start;
	u64			sum_exec_runtime;
	u64			prev_sum_exec;

	u64			wait_start;
	u64			sum_wait_time;

	u64			io_wait_start;
	u64			sum_io_wait;
	u64			epoch_io_wait;
	u64			epoch_exec;

	unsigned int		burst_ratio;
	unsigned int		yield_freq;
	unsigned int		io_wait_ratio;
	unsigned int		behavior_score;

	unsigned int		nr_yields;
	unsigned int		tick_count;
	unsigned int		total_ticks;
	unsigned int		epoch_count;

	unsigned int		starve_boosted;
	unsigned int		on_rq;
	unsigned int		initialized;
};
```

**Step B:** Find `struct task_struct` and look for these three lines close together:

```c
	struct sched_entity		se;
	struct sched_rt_entity		rt;
	struct sched_dl_entity		dl;
```

Add this line right after the `dl` line:

```c
	struct sched_awrr_entity	awrr;
```

Save and exit.

### 3.3 Modify the Internal Scheduler Header

Edit `kernel/sched/sched.h`:

```bash
nano ~/linux-6.1/kernel/sched/sched.h
```

**Step A:** Near the top, find the `#include "cpudeadline.h"` line. Add after it:

```c
#include "awrr.h"
```

**Step B:** Find the `extern const struct sched_class` declarations. Add AWRR between `rt` and `fair`:

```c
extern const struct sched_class stop_sched_class;
extern const struct sched_class dl_sched_class;
extern const struct sched_class rt_sched_class;
extern const struct sched_class awrr_sched_class;   /* ADD THIS LINE */
extern const struct sched_class fair_sched_class;
extern const struct sched_class idle_sched_class;
```

**Step C:** Find the policy check functions (search for `rt_policy`). After the `dl_policy`/`task_has_dl_policy` functions, add:

```c
static inline bool awrr_policy(int policy)
{
	return policy == SCHED_AWRR;
}

static inline bool task_has_awrr_policy(struct task_struct *p)
{
	return awrr_policy(p->policy);
}
```

**Step D:** Find `struct rq {` and look for the embedded runqueues:

```c
	struct cfs_rq		cfs;
	struct rt_rq		rt;
	struct dl_rq		dl;
```

Add AWRR between `rt` and `dl`:

```c
	struct cfs_rq		cfs;
	struct rt_rq		rt;
	struct awrr_rq		awrr;   /* ADD THIS LINE */
	struct dl_rq		dl;
```

**Step E:** After the `sched_rt_runnable()` function (or any similar helper), add:

```c
static inline bool sched_awrr_runnable(struct rq *rq)
{
	return rq->awrr.nr_running > 0;
}
```

Save and exit.

### 3.4 Modify the Linker Script

Edit `include/asm-generic/vmlinux.lds.h`:

```bash
nano ~/linux-6.1/include/asm-generic/vmlinux.lds.h
```

Search for `SCHED_DATA` (Ctrl+W). You'll find the macro that lists scheduling classes. Add the AWRR line between `rt` and `fair`:

```
#define SCHED_DATA				\
	STRUCT_ALIGN();				\
	__sched_class_highest = .;		\
	*(__stop_sched_class)			\
	*(__dl_sched_class)			\
	*(__rt_sched_class)			\
	*(__awrr_sched_class)			\
	*(__fair_sched_class)			\
	*(__idle_sched_class)			\
	__sched_class_lowest = .;
```

Save and exit.

### 3.5 Modify core.c

Edit `kernel/sched/core.c`:

```bash
nano ~/linux-6.1/kernel/sched/core.c
```

**Step A:** Find `valid_policy()` function. Add `|| awrr_policy(policy)`:

```c
static inline int valid_policy(int policy)
{
	return idle_policy(policy) || fair_policy(policy) ||
		rt_policy(policy) || dl_policy(policy) ||
		awrr_policy(policy);
}
```

**Step B:** Find where `sched_class` is assigned based on policy (in `__sched_setscheduler()` or `__setscheduler()`). Look for:

```c
	if (dl_policy(policy))
		p->sched_class = &dl_sched_class;
	else if (rt_policy(policy))
		p->sched_class = &rt_sched_class;
	else
		p->sched_class = &fair_sched_class;
```

Change it to:

```c
	if (dl_policy(policy))
		p->sched_class = &dl_sched_class;
	else if (rt_policy(policy))
		p->sched_class = &rt_sched_class;
	else if (awrr_policy(policy))
		p->sched_class = &awrr_sched_class;
	else
		p->sched_class = &fair_sched_class;
```

**Step C:** Find `sched_init()` function. Look for the `init_rt_rq` call inside the `for_each_possible_cpu` loop:

```c
	init_rt_rq(&rq->rt);
```

Add right after it:

```c
	init_awrr_rq(&rq->awrr);
```

**Step D:** Still in `sched_init()`, after the `for_each_possible_cpu` loop ends, add:

```c
	awrr_sysctl_init();
```

**Step E:** Find `__pick_next_task()`. There's an optimization check like:

```c
	if (likely(!sched_class_above(prev->sched_class, &fair_sched_class) &&
		   rq->nr_running == rq->cfs.h_nr_running)) {
```

Add `&& !rq->awrr.nr_running` to the condition:

```c
	if (likely(!sched_class_above(prev->sched_class, &fair_sched_class) &&
		   rq->nr_running == rq->cfs.h_nr_running &&
		   !rq->awrr.nr_running)) {
```

**Step F:** Find `__setscheduler_params()`. After the RT priority handling, add:

```c
	if (awrr_policy(policy)) {
		p->normal_prio = MAX_RT_PRIO;
		p->prio = p->normal_prio;
		p->rt_priority = 0;
	}
```

Save and exit.

### 3.6 Copy AWRR Source Files

```bash
cp ~/awrr-scheduler/kernel-patch/awrr.h ~/linux-6.1/kernel/sched/awrr.h
cp ~/awrr-scheduler/kernel-patch/awrr.c ~/linux-6.1/kernel/sched/awrr.c
```

### 3.7 Update the Scheduler Makefile

Edit `kernel/sched/Makefile`:

```bash
nano ~/linux-6.1/kernel/sched/Makefile
```

Find the line that starts with `obj-y +=` and lists scheduler object files. Add `awrr.o` to it:

```makefile
obj-y += core.o loadavg.o clock.o cputime.o idle.o fair.o rt.o deadline.o \
         build_policy.o build_utility.o awrr.o
```

Save and exit.

---

## Part 4: Configure and Build the Kernel

### 4.1 Create Default Config

```bash
cd ~/linux-6.1
make defconfig
```

### 4.2 Build the Kernel

```bash
make -j$(nproc)
```

**This will take 15-40 minutes** depending on your VM specs. If you get errors, see Part 7 (Troubleshooting).

Expected output at the end:
```
Kernel: arch/arm64/boot/Image.gz is ready
```

(On x86_64 it would say `arch/x86/boot/bzImage`)

### 4.3 Install Modules and Kernel

```bash
sudo make modules_install
sudo make install
```

### 4.4 Update GRUB

```bash
sudo update-grub
```

Verify your kernel appears:
```bash
grep -i "menuentry" /boot/grub/grub.cfg | head -5
```

You should see an entry with `6.1.0` or `6.1.0+`.

---

## Part 5: Boot and Test

### 5.1 Reboot into Custom Kernel

```bash
sudo reboot
```

If GRUB shows a menu, select the `6.1.0` entry. If it boots the wrong kernel, hold Shift during boot to access the GRUB menu.

### 5.2 Verify Kernel Version

```bash
uname -r
```

Expected: `6.1.0` or `6.1.0+`

### 5.3 Verify AWRR Is Loaded

```bash
# Check sysctl parameters exist
ls /proc/sys/kernel/sched_awrr/
```

Expected output:
```
base_slice_ns  cpu_bound_threshold  epoch_ticks  ewma_alpha_num  io_bound_threshold  starve_threshold_ns
```

Check default values:
```bash
cat /proc/sys/kernel/sched_awrr/base_slice_ns
# Expected: 10000000 (10ms)

cat /proc/sys/kernel/sched_awrr/epoch_ticks
# Expected: 100
```

### 5.4 Test Assigning a Process to AWRR

First, build the setpolicy tool:

```bash
cd ~/awrr-scheduler/benchmarks
gcc -o awrr_setpolicy awrr_setpolicy.c
chmod +x assign_awrr.sh
```

Test it:

```bash
# Run a simple command under AWRR
sudo ./assign_awrr.sh --run "sleep 5"

# Or assign an existing process
sleep 60 &
sudo ./assign_awrr.sh --pid $!
```

If no errors appear, AWRR is working.

### 5.5 Monitor AWRR Tasks

```bash
chmod +x monitor_awrr.sh
sudo ./monitor_awrr.sh
```

This shows live AWRR task information. Press Ctrl+C to stop.

---

## Part 6: Run Benchmarks

### 6.1 Install Benchmark Tools

```bash
cd ~/awrr-scheduler/benchmarks
chmod +x install_benchtools.sh
sudo ./install_benchtools.sh
```

This installs hackbench, schbench (compiled from source), and sysbench.

### 6.2 Run CFS Baseline

Run the CFS benchmarks first — this is your comparison baseline:

```bash
chmod +x run_benchmarks.sh
sudo ./run_benchmarks.sh cfs
```

This runs 10 iterations of each benchmark. Takes about 10-15 minutes. Results go to `results/cfs_<timestamp>/`.

### 6.3 Run AWRR Benchmarks

```bash
sudo ./run_benchmarks.sh awrr
```

The script automatically assigns benchmark processes to AWRR using the `awrr_setpolicy` tool.

### 6.4 Compare Results

```bash
chmod +x compare_results.sh
./compare_results.sh results/cfs_* results/awrr_*
```

This prints a side-by-side comparison with percentage differences.

### 6.5 Collect Your Data

Your results are in:
- `results/<scheduler>_<timestamp>/summary.csv` — Machine-readable data
- `results/<scheduler>_<timestamp>/report.txt` — Human-readable report
- `results/<scheduler>_<timestamp>/hackbench/` — Raw hackbench data
- `results/<scheduler>_<timestamp>/schbench/` — Raw schbench data
- `results/<scheduler>_<timestamp>/sysbench/` — Raw sysbench data
- `results/<scheduler>_<timestamp>/mixed/` — Mixed workload data

---

## Part 7: Troubleshooting

### Build Errors

**"implicit declaration of function 'init_awrr_rq'"**
- Make sure you added `#include "awrr.h"` in `kernel/sched/sched.h`
- Make sure `awrr.h` is in `kernel/sched/`

**"unknown type name 'struct sched_awrr_entity'"**
- Make sure you added the struct definition in `include/linux/sched.h` BEFORE `struct task_struct`

**"'SCHED_AWRR' undeclared"**
- Make sure you added `#define SCHED_AWRR 7` in `include/uapi/linux/sched.h`

**"undefined reference to 'awrr_sched_class'"**
- Make sure `awrr.o` is in `kernel/sched/Makefile`
- Make sure `*(__awrr_sched_class)` is in the linker script

**"struct rq has no member named 'awrr'"**
- Make sure you added `struct awrr_rq awrr;` inside `struct rq` in `kernel/sched/sched.h`

### Boot Issues

**Kernel panic on boot:**
- Don't panic (literally). Hold Shift on reboot to get GRUB menu
- Select **"Advanced options"** → your OLD kernel (the one that was working before)
- Fix the code, rebuild, try again

**Wrong kernel boots:**
```bash
# Set the new kernel as default
sudo nano /etc/default/grub
# Change GRUB_DEFAULT=0 to point to your kernel
sudo update-grub
sudo reboot
```

### Runtime Issues

**"Unknown scheduler policy" when using sched_setscheduler:**
- Verify with `uname -r` that you're running the custom kernel
- Check that `valid_policy()` includes `awrr_policy(policy)`
- Check that the `__sched_setscheduler()` routes AWRR to `awrr_sched_class`

**"/proc/sys/kernel/sched_awrr/ doesn't exist":**
- Check that `awrr_sysctl_init()` is called in `sched_init()`
- Check dmesg: `dmesg | grep -i awrr`

**Benchmark tool not found:**
```bash
# Reinstall
sudo ~/awrr-scheduler/benchmarks/install_benchtools.sh
```

### Performance Tuning

You can adjust AWRR parameters at runtime:

```bash
# Make AWRR more responsive (shorter epochs)
echo 50 | sudo tee /proc/sys/kernel/sched_awrr/epoch_ticks

# Increase base time slice to 20ms
echo 20000000 | sudo tee /proc/sys/kernel/sched_awrr/base_slice_ns

# Lower starvation threshold to 250ms
echo 250000000 | sudo tee /proc/sys/kernel/sched_awrr/starve_threshold_ns

# Make EWMA more reactive (alpha = 0.5)
echo 5 | sudo tee /proc/sys/kernel/sched_awrr/ewma_alpha_num
```

---

## Quick Reference

| Step | Command | Time |
|------|---------|------|
| Install deps | `sudo apt install build-essential ...` | 2 min |
| Download kernel | `wget .../linux-6.1.tar.xz && tar xf ...` | 5 min |
| Apply patches | Edit 6 files + copy 2 files | 15 min |
| Build kernel | `make -j$(nproc)` | 15-40 min |
| Install kernel | `sudo make modules_install && sudo make install` | 3 min |
| Reboot + verify | `sudo reboot` then `uname -r` | 2 min |
| Install benchtools | `sudo ./install_benchtools.sh` | 3 min |
| Run benchmarks | `sudo ./run_benchmarks.sh cfs` then `awrr` | 20-30 min |
| Compare | `./compare_results.sh results/cfs_* results/awrr_*` | instant |

**Total estimated time: ~1.5-2 hours from start to benchmark results.**
