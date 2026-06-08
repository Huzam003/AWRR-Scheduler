# 🐧 AWRR: Hardened Adaptive Weighted Round-Robin Linux Kernel Scheduler

<div align="center">

**Air University · Operating Systems & Systems Security Project**

[![C Language](https://img.shields.io/badge/Language-C_GNU99-00599C.svg?style=for-the-badge&logo=c&logoColor=white)](https://en.wikipedia.org/wiki/C_(programming_language))
[![Security](https://img.shields.io/badge/Security-Kernel_Hardened-red.svg?style=for-the-badge&logo=linux&logoColor=white)](https://en.wikipedia.org/wiki/Hardening_(computing))
[![Kernel](https://img.shields.io/badge/Target_Kernel-Linux_6.1_LTS-blue.svg?style=for-the-badge&logo=linux&logoColor=white)](https://kernel.org/)
[![Platform](https://img.shields.io/badge/Platform-ARM64_/_UTM-orange.svg?style=for-the-badge&logo=virtualbox&logoColor=white)](https://mac.getutm.app/)

A real, working custom Linux scheduling class (`awrr_sched_class` / policy `7`) featuring dynamic behavior classification, timing side-channel obfuscation, transient starvation boost recovery, and behavioral anomaly anti-gaming heuristic penalties. **Every component is genuinely functional at Ring 0—compiled directly into a custom Linux kernel.**

---

### 👤 Developer
**Syed Wasif Ali Shah** (242334)  
Air University NCSA  

</div>

---

## 🗺️ Table of Contents
1. [What It Does](#-what-it-does)
2. [Setup & Installation](#%EF%B8%8F-setup--installation)
3. [Running the System](#%EF%B8%8F-running-the-system)
4. [Walkthrough & Testing](#-walkthrough--try-it-yourself)
5. [Architecture](#-architecture)
6. [How Hardening & Security Works](#-how-hardening--security-works-your-novelty)
7. [Security & Feature Status](#%EF%B8%8F-security--feature-status)
8. [Sysctl Interface & CLI Utilities](#-sysctl-interface--cli-utilities)
9. [Tech Stack](#-tech-stack)
10. [Kernel Realness Check](#-why-this-is-a-real-kernel-scheduler-not-a-simulation)
11. [Known Limitations](#-known-limitations-honest)

---

## ⚡ What It Does

### ⛓️ Core Scheduler
* **Custom Scheduling Class (`SCHED_AWRR` / Policy 7)**: Sits in the scheduling hierarchy between the Real-Time (`rt_sched_class`) and Completely Fair (`fair_sched_class`) schedulers.
* **Behavior Classification Engine**: Tracks three real-time runtime metrics per task:
  * **CPU Burst Ratio ($B$)**: Percentage of allocated timeslice consumed.
  * **Voluntary Yield Frequency ($Y$)**: Frequency of voluntary context switches via `sched_yield()`.
  * **I/O Wait Ratio ($W$)**: Time spent sleeping in I/O states relative to running time.
* **EWMA Score Smoothing**: Smoothes behavior metrics using an Exponentially Weighted Moving Average (smoothing factor $\alpha=0.3$) at epoch boundaries (100ms) to prevent priority oscillation.
* **Dynamic Weight Allocator**: Dynamically increases or decreases task weights in the range $[1..10]$ to compute timeslices:
  * CPU-bound tasks: Weight decremented (min 1).
  * I/O-bound tasks: Weight incremented (max 10).

### 🛡️ Security Hardening & Mitigations
* **Timing Side-Channel Jitter**: Adds pseudo-random timing noise ($\pm 10\%$) to execution timeslices, disrupting timeslice-modulation eavesdropping attacks and covert timing channels.
* **Anti-Gaming Clamping Heuristic**: Detects anomalous behavior (high CPU consumption combined with high voluntary yields) that malicious tasks use to masquerade as I/O-bound. The engine clamps the gaming task's weight to `2` for `3` consecutive epochs.
* **Transient Starvation Boost Restorer**: Solves the priority leak bug. Starved processes are boosted to weight `10` to get CPU access, but their priority is immediately restored to pre-boost levels once they run, preventing permanent priority leaks.

---

## ⚙️ Setup & Installation

Requires an ARM64 VM (recommended: Ubuntu Server 22.04 LTS run via UTM on macOS Apple Silicon).

### 1. Install VM & Build Dependencies
```bash
# Update and install dependencies
sudo apt update && sudo apt upgrade -y
sudo apt install -y build-essential git flex bison libssl-dev libelf-dev bc \
    dwarves cpio libncurses-dev zstd wget curl rsync python3
```

### 2. Download Linux 6.1 Source & Extract
```bash
cd ~
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.1.tar.xz
tar xf linux-6.1.tar.xz
cd linux-6.1
```

### 3. Copy files & Apply Patches
Copy patch contents into the kernel source tree:
* Add `#define SCHED_AWRR 7` to `include/uapi/linux/sched.h`
* Define `struct sched_awrr_entity` and embed it in `struct task_struct` inside `include/linux/sched.h` (using [task_struct.patch](awrr-scheduler/kernel-patch/task_struct.patch))
* Update `kernel/sched/sched.h` to declare `awrr_sched_class` and embed `struct awrr_rq` in `struct rq` (using [sched.h.patch](awrr-scheduler/kernel-patch/sched.h.patch))
* Update `include/asm-generic/vmlinux.lds.h` and `kernel/sched/Makefile`
* Copy the custom code files:
```bash
cp ~/awrr-scheduler/kernel-patch/awrr.h ~/linux-6.1/kernel/sched/awrr.h
cp ~/awrr-scheduler/kernel-patch/awrr.c ~/linux-6.1/kernel/sched/awrr.c
```

### 4. Build and Install the Kernel
```bash
make defconfig
make -j$(nproc)
sudo make modules_install
sudo make install
sudo update-grub
sudo reboot
```

---

## 🕹️ Running the System

After rebooting, verify that you are running the patched kernel:
```bash
uname -r
# Expected: 6.1.0 or 6.1.0+
```

### A. Assigning a Process to AWRR
Use the included benchmark helper script to launch or move a process to policy `7` (`SCHED_AWRR`):
```bash
# Run a sleep task under AWRR
sudo ./benchmarks/assign_awrr.sh --run "sleep 60"

# Or assign an existing process
sleep 300 &
sudo ./benchmarks/assign_awrr.sh --pid $!
```

### B. Live Real-Time Monitoring
Monitor the active AWRR scheduler runqueue and task metrics:
```bash
sudo ./benchmarks/monitor_awrr.sh
```

---

## 🚶 Walkthrough — Try It Yourself

1. **Launch a monitor**: Open a terminal window in your VM and run `sudo ./benchmarks/monitor_awrr.sh`.
2. **Execute standard task**: Launch a standard sleep or CPU benchmark command under AWRR using `assign_awrr.sh --run`.
3. **Verify Dynamic Weighting**: Watch the behavior score. An active CPU workload will decrease to weight `1` (CPU-bound), while a sleeping process will rise toward weight `10` (I/O-bound).
4. **Trigger Starvation Boost**: Launch an AWRR process and heavily load the VM CPU with RT/DL workloads to starve it. Note in the monitor that its weight is boosted to `10` after 500ms of wait latency.
5. **Verify Starvation Recovery**: Once the starved task runs, watch its weight immediately restore to its pre-boosted value (demonstrating the starvation restorer).
6. **Trigger Anti-Gaming Clamping**: Run a gaming task that executes heavy math loops but immediately calls `sched_yield()` repeatedly. Watch the monitor clamp its weight to `2` for `3` epochs as a penalty.

---

## 🏗️ Architecture

```text
awrr-scheduler/
├── kernel-patch/   # Rings 0 Kernel modifications
│   ├── awrr.c      # Core AWRR scheduling class implementation
│   ├── awrr.h      # Shared data structures and metric tunables
│   ├── core.c.patch # Hook registration and setscheduler policy verification
│   ├── sched.h.patch # Embeds awrr_rq in rq, declares class, adds helpers
│   ├── sched_uapi.h.patch # Registers policy constant (7)
│   └── task_struct.patch # Embeds sched_awrr_entity in task_struct
├── benchmarks/     # User-space monitoring and evaluation
│   ├── assign_awrr.sh # Script to launch/move PIDs to policy 7
│   ├── awrr_setpolicy.c # C interface to invoke sched_setscheduler()
│   ├── monitor_awrr.sh # Real-time statistics telemetry reader (/proc/sys)
│   ├── run_benchmarks.sh # Automation script for hackbench, schbench, sysbench
│   ├── install_benchtools.sh # Compiles and installs evaluation utilities
│   └── compare_results.sh # Evaluation reporting comparing AWRR vs CFS
└── guide/
    └── SETUP_GUIDE.md # Comprehensive VM configure & compilation guide
```

---

## 🧠 How Hardening & Security Works (Your Novelty)

### 1. Timing Jitter Side-Channel Mitigation
In standard scheduling classes, execution timeslices are completely deterministic:
$$\text{slice} = \frac{\text{BASE\_SLICE} \times \text{weight}}{\text{total\_weight}}$$
This allow an attacker task running in the same scheduler class to measure its own timeslice duration and infer the weight changes (and thus cryptographic behavior) of a co-located victim process.
* **Hardening Implementation**: We introduce a randomized jitter of up to $\pm 10\%$ to the slice in `awrr_calc_timeslice`:
```c
if (slice > 2 * NSEC_PER_MSEC) {
    u32 max_jitter = (u32)(slice / 10);
    u32 jitter = get_random_u32() % (max_jitter + 1);
    if (get_random_u32() % 2)
        slice += jitter;
    else
        slice -= jitter;
}
```
This introduces timing noise, drastically lowering the signal-to-noise ratio (SNR) for side-channel timed attacks.

### 2. Behavioral Anti-Gaming Heuristics
Malicious user-space programs can game traditional MLFQ or weight-adaptive schedulers by executing massive CPU bursts and yielding at the last tick to appear I/O-bound, retaining high priority (weight 10).
* **Hardening Implementation**: We detect anomalous behavior combinations—where a task has both high yield rates and high CPU execution in a single epoch—and penalize the task:
```c
if (se->yield_freq > 6 && se->burst_ratio > 6) {
    se->weight = AWRR_WEIGHT_MIN + 1; /* Clamp weight to 2 */
    se->penalty_epochs = 3;           /* Force penalty for 3 epochs */
}
```

### 3. Starvation Boost Restorer
Starved processes must receive priority boosts, but permanent priority updates allow priority-hijacking attacks.
* **Hardening Implementation**: We store the original weight before boosting (`pre_boost_weight = weight`). Once the starved task runs for its epoch, we clear the boost flag and immediately restore `weight = pre_boost_weight`, updating the runqueue `total_weight` correctly.

---

## 🧪 Security & Feature Status

| Threat Scenario / Feature | Mitigation Mechanism | Status |
| :--- | :--- | :---: |
| **Scheduler Timing Side-Channel** | Pseudo-random timeslice timing jitter | 🟢 **ACTIVE** |
| **Scheduler Covert Channel** | Obfuscated total weight timeslice variance | 🟢 **ACTIVE** |
| **Dynamic Scheduler Gaming** | High yield & burst rate anomaly clamp (weight 2) | 🟢 **ACTIVE** |
| **Starvation Priority Hijacking** | Transient boost & weight restorer | 🟢 **ACTIVE** |
| **Dynamic Priority Tuning** | EWMA metric smoothing ($\alpha=0.3$) | 🟢 **ACTIVE** |

---

## 📡 Sysctl Interface & CLI Utilities

### `/proc/sys/kernel/sched_awrr/` Interface

| Parameter | Default Value | Description |
| :--- | :--- | :--- |
| `base_slice_ns` | `10000000` (10ms) | The baseline timeslice allocated to standard tasks |
| `epoch_ticks` | `100` (~100ms) | Duration of a metric tracking epoch |
| `ewma_alpha_num` | `3` (0.3) | EWMA smoothing factor numerator |
| `starve_threshold_ns` | `500000000` (500ms) | Maximum wait time on runqueue before starvation boost |
| `cpu_bound_threshold` | `7` | Score threshold ($S > 0.7$) to decrement weight |
| `io_bound_threshold` | `3` | Score threshold ($S < 0.3$) to increment weight |

### Command-Line Benchmarking Suite

| Script | Purpose |
| :--- | :--- |
| `monitor_awrr.sh` | CLI Dashboard that pings kernel `/proc/PID/sched` statistics and displays weights |
| `assign_awrr.sh` | Sets task policies to policy `7` via user-space helper |
| `run_benchmarks.sh` | Automated benchmark suite for hackbench, sysbench, and schbench |
| `compare_results.sh` | Processes output metrics and logs performance delta vs CFS |

---

## 🛠️ Tech Stack

* **Programming Language**: C (GNU99 Standard)
* **Kernel Tree**: Linux 6.1 LTS Source (Ring 0 Kernel Space)
* **Compilers & Build**: GCC, GNU Make
* **VM Hypervisor**: UTM (ARM64 Virtualization)
* **Linux Environment**: Ubuntu Server 22.04 LTS
* **Scripting**: Bash (telemetry scripts & benchmarking)
* **Benchmarking tools**: Hackbench, Schbench, Sysbench

---

## 🔍 Why This Is a Real Kernel Scheduler (Not a Simulation)

| Operating System Attribute | Implementation Details |
| :--- | :--- |
| **Native Integration** | ✅ **Yes** — Hooks directly into `DEFINE_SCHED_CLASS(awrr)` alongside standard classes. |
| **Ring 0 Context** | ✅ **Yes** — Functions execute in supervisor mode with full kernel privilege levels. |
| **Real Dynamic Weighting** | ✅ **Yes** — Modifies active process timeslices and forces dynamic re-schedulers. |
| **Kernel Randomness** | ✅ **Yes** — Cryptographically feeds timing jitter from `<linux/random.h>` get_random_u32(). |
| **System Compatibility** | ✅ **Yes** — Co-exists with standard system daemons running under CFS/RT. |
| **Persistence & Interface** | ✅ **Yes** — Exposes runtime metrics to `/proc/sys/kernel/sched_awrr` and `/proc/PID/sched`. |

---

## ⚠️ Known Limitations (Honest)

* **No SMP Load Balancing**: The scheduler stubs balance functions (`select_task_rq_awrr` and `balance_awrr`). Tasks remain on their parent execution core.
* **Low Jitter Range**: Noise is clamped at 10% of the slice to preserve execution performance while mitigating timing side-channels.
* **Local Privilege Bounds**: Switching scheduler policies requires `CAP_SYS_NICE` capabilities (root authentication).

---

## 📄 License

Academic Project — Air University. Free for educational use.
