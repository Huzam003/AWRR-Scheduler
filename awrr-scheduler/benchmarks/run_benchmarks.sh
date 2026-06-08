#!/usr/bin/env bash
# ==============================================================================
# AWRR Scheduler Benchmark Suite
# run_benchmarks.sh — Automated benchmark runner with statistical analysis
#
# Usage: sudo ./run_benchmarks.sh <scheduler>
#   scheduler: awrr | cfs | eevdf | static-wrr
#
# Runs 10 iterations of hackbench, schbench, sysbench, and a mixed workload.
# Collects system stats, computes mean/stddev, outputs CSV and text report.
# ==============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
ITERATIONS=10
SCHEDULER="${1:-}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="${BASE_DIR}/results/${SCHEDULER}_${TIMESTAMP}"
AWRR_SETPOLICY="${BASE_DIR}/awrr_setpolicy"
ASSIGN_AWRR="${BASE_DIR}/assign_awrr.sh"

# hackbench parameters
HB_GROUPS=10
HB_FDS=40
HB_LOOPS=100
HB_SIZE=100

# schbench parameters
SB_WORKERS=4
SB_THREADS=1
SB_RUNTIME=30
SB_SLEEP=30000
SB_CPU=1000

# sysbench parameters
SYS_PRIME=20000
SYS_THREADS=8
SYS_THREADS_MIXED=4

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Functions ─────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: sudo $0 <scheduler>"
    echo "  scheduler: awrr | cfs | eevdf | static-wrr"
    echo ""
    echo "Example:"
    echo "  sudo $0 cfs       # Run baseline CFS benchmarks"
    echo "  sudo $0 awrr      # Run AWRR benchmarks"
    exit 1
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_progress() {
    echo -e "${CYAN}[${1}/${ITERATIONS}]${NC} $2"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (sudo)."
        exit 1
    fi
}

check_tools() {
    local missing=0

    for tool in hackbench schbench sysbench bc; do
        if ! command -v "$tool" &>/dev/null; then
            log_error "Missing tool: $tool"
            missing=1
        fi
    done

    if [[ "$SCHEDULER" == "awrr" ]]; then
        if [[ ! -x "$AWRR_SETPOLICY" ]]; then
            log_warn "awrr_setpolicy not compiled. Attempting to build..."
            if [[ -f "${BASE_DIR}/awrr_setpolicy.c" ]]; then
                gcc -o "$AWRR_SETPOLICY" "${BASE_DIR}/awrr_setpolicy.c"
                log_info "Built awrr_setpolicy successfully."
            else
                log_error "awrr_setpolicy.c not found in ${BASE_DIR}"
                missing=1
            fi
        fi
    fi

    if [[ $missing -eq 1 ]]; then
        log_error "Install missing tools with: ./install_benchtools.sh"
        exit 1
    fi

    log_info "All required tools found."
}

# Calculate mean from a file of numbers (one per line)
calc_mean() {
    local file="$1"
    awk '{ sum += $1; n++ } END { if (n > 0) printf "%.4f", sum / n }' "$file"
}

# Calculate standard deviation from a file of numbers
calc_stddev() {
    local file="$1"
    awk '{
        sum += $1; sumsq += ($1 * $1); n++
    } END {
        if (n > 1) {
            mean = sum / n
            variance = (sumsq - n * mean * mean) / (n - 1)
            if (variance < 0) variance = 0
            printf "%.4f", sqrt(variance)
        } else {
            printf "0.0000"
        }
    }' "$file"
}

# Collect system stats snapshot
collect_system_stats() {
    local outfile="$1"
    echo "--- System Stats Snapshot $(date) ---" > "$outfile"

    if [[ -f /proc/vmstat ]]; then
        echo "# Context Switches:" >> "$outfile"
        grep -E '^(nr_|pgfault|pgmajfault)' /proc/vmstat >> "$outfile" 2>/dev/null || true
        grep 'ctxt' /proc/stat >> "$outfile" 2>/dev/null || true
    fi

    if [[ -f /proc/loadavg ]]; then
        echo "# Load Average:" >> "$outfile"
        cat /proc/loadavg >> "$outfile"
    fi

    echo "# Running Processes:" >> "$outfile"
    ps -eo pid,policy,pri,ni,comm --no-headers | head -20 >> "$outfile" 2>/dev/null || true
}

# Wrapper: run command under AWRR if needed, otherwise run directly
run_under_scheduler() {
    local cmd="$1"
    if [[ "$SCHEDULER" == "awrr" ]]; then
        "$ASSIGN_AWRR" --run "$cmd"
    else
        eval "$cmd"
    fi
}

# ── Benchmark: hackbench ──────────────────────────────────────────────────────

run_hackbench() {
    local run_dir="${RESULTS_DIR}/hackbench"
    mkdir -p "$run_dir"
    local times_file="${run_dir}/times.txt"
    > "$times_file"

    log_info "Running hackbench ($ITERATIONS iterations)..."

    for i in $(seq 1 $ITERATIONS); do
        log_progress "$i" "hackbench"
        collect_system_stats "${run_dir}/stats_run${i}_before.txt"

        local raw="${run_dir}/raw_run${i}.txt"
        local cmd="hackbench -g ${HB_GROUPS} -f ${HB_FDS} -l ${HB_LOOPS} -s ${HB_SIZE} -P"

        if [[ "$SCHEDULER" == "awrr" ]]; then
            "$AWRR_SETPOLICY" --run "$cmd" > "$raw" 2>&1 || true
        else
            eval "$cmd" > "$raw" 2>&1 || true
        fi

        # Parse "Time: X.XXX" from hackbench output
        local time_val
        time_val=$(grep -oP 'Time:\s*\K[0-9]+\.[0-9]+' "$raw" 2>/dev/null || echo "")

        if [[ -z "$time_val" ]]; then
            log_warn "hackbench run $i: could not parse time"
            echo "0" >> "$times_file"
        else
            echo "$time_val" >> "$times_file"
        fi

        collect_system_stats "${run_dir}/stats_run${i}_after.txt"
        sleep 1
    done

    # Calculate statistics
    local mean stddev
    mean=$(calc_mean "$times_file")
    stddev=$(calc_stddev "$times_file")

    echo "mean=$mean" > "${run_dir}/summary.txt"
    echo "stddev=$stddev" >> "${run_dir}/summary.txt"
    log_info "hackbench: mean=${mean}s, stddev=${stddev}s"
}

# ── Benchmark: schbench ───────────────────────────────────────────────────────

run_schbench() {
    local run_dir="${RESULTS_DIR}/schbench"
    mkdir -p "$run_dir"
    local p50_file="${run_dir}/p50.txt"
    local p95_file="${run_dir}/p95.txt"
    local p99_file="${run_dir}/p99.txt"
    > "$p50_file"
    > "$p95_file"
    > "$p99_file"

    log_info "Running schbench ($ITERATIONS iterations)..."

    for i in $(seq 1 $ITERATIONS); do
        log_progress "$i" "schbench"
        collect_system_stats "${run_dir}/stats_run${i}_before.txt"

        local raw="${run_dir}/raw_run${i}.txt"
        local cmd="schbench -m ${SB_WORKERS} -t ${SB_THREADS} -r ${SB_RUNTIME} -s ${SB_SLEEP} -c ${SB_CPU}"

        if [[ "$SCHEDULER" == "awrr" ]]; then
            "$AWRR_SETPOLICY" --run "$cmd" > "$raw" 2>&1 || true
        else
            eval "$cmd" > "$raw" 2>&1 || true
        fi

        # Parse percentile latencies from schbench output
        # schbench output format varies; common patterns:
        #   50.0th: 123 (or *50.0th: 123)
        #   95.0th: 456
        #   99.0th: 789
        local p50 p95 p99
        p50=$(grep -oP '\*?50\.0th:\s*\K[0-9]+' "$raw" 2>/dev/null | tail -1 || echo "")
        p95=$(grep -oP '\*?95\.0th:\s*\K[0-9]+' "$raw" 2>/dev/null | tail -1 || echo "")
        p99=$(grep -oP '\*?99\.0th:\s*\K[0-9]+' "$raw" 2>/dev/null | tail -1 || echo "")

        echo "${p50:-0}" >> "$p50_file"
        echo "${p95:-0}" >> "$p95_file"
        echo "${p99:-0}" >> "$p99_file"

        if [[ -z "$p50" ]]; then
            log_warn "schbench run $i: could not parse latencies"
        fi

        collect_system_stats "${run_dir}/stats_run${i}_after.txt"
        sleep 1
    done

    # Calculate statistics
    local mean_p50 mean_p95 mean_p99 sd_p50 sd_p95 sd_p99
    mean_p50=$(calc_mean "$p50_file")
    mean_p95=$(calc_mean "$p95_file")
    mean_p99=$(calc_mean "$p99_file")
    sd_p50=$(calc_stddev "$p50_file")
    sd_p95=$(calc_stddev "$p95_file")
    sd_p99=$(calc_stddev "$p99_file")

    cat > "${run_dir}/summary.txt" <<EOF
p50_mean=$mean_p50
p50_stddev=$sd_p50
p95_mean=$mean_p95
p95_stddev=$sd_p95
p99_mean=$mean_p99
p99_stddev=$sd_p99
EOF
    log_info "schbench: p50=${mean_p50}us, p95=${mean_p95}us, p99=${mean_p99}us"
}

# ── Benchmark: sysbench ───────────────────────────────────────────────────────

run_sysbench() {
    local run_dir="${RESULTS_DIR}/sysbench"
    mkdir -p "$run_dir"
    local eps_file="${run_dir}/events_per_sec.txt"
    local time_file="${run_dir}/total_time.txt"
    > "$eps_file"
    > "$time_file"

    log_info "Running sysbench ($ITERATIONS iterations)..."

    for i in $(seq 1 $ITERATIONS); do
        log_progress "$i" "sysbench"
        collect_system_stats "${run_dir}/stats_run${i}_before.txt"

        local raw="${run_dir}/raw_run${i}.txt"
        local cmd="sysbench cpu --cpu-max-prime=${SYS_PRIME} --threads=${SYS_THREADS} run"

        if [[ "$SCHEDULER" == "awrr" ]]; then
            "$AWRR_SETPOLICY" --run "$cmd" > "$raw" 2>&1 || true
        else
            eval "$cmd" > "$raw" 2>&1 || true
        fi

        # Parse events per second and total time
        local eps ttime
        eps=$(grep -oP 'events per second:\s*\K[0-9]+\.?[0-9]*' "$raw" 2>/dev/null || echo "")
        ttime=$(grep -oP 'total time:\s*\K[0-9]+\.?[0-9]*' "$raw" 2>/dev/null || echo "")

        echo "${eps:-0}" >> "$eps_file"
        echo "${ttime:-0}" >> "$time_file"

        if [[ -z "$eps" ]]; then
            log_warn "sysbench run $i: could not parse output"
        fi

        collect_system_stats "${run_dir}/stats_run${i}_after.txt"
        sleep 1
    done

    # Calculate statistics
    local mean_eps sd_eps mean_time sd_time
    mean_eps=$(calc_mean "$eps_file")
    sd_eps=$(calc_stddev "$eps_file")
    mean_time=$(calc_mean "$time_file")
    sd_time=$(calc_stddev "$time_file")

    cat > "${run_dir}/summary.txt" <<EOF
events_per_sec_mean=$mean_eps
events_per_sec_stddev=$sd_eps
total_time_mean=$mean_time
total_time_stddev=$sd_time
EOF
    log_info "sysbench: ${mean_eps} events/sec (stddev=${sd_eps}), time=${mean_time}s"
}

# ── Benchmark: Mixed Workload ─────────────────────────────────────────────────

run_mixed() {
    local run_dir="${RESULTS_DIR}/mixed"
    mkdir -p "$run_dir"
    local sys_eps_file="${run_dir}/sysbench_eps.txt"
    local sb_p50_file="${run_dir}/schbench_p50.txt"
    local sb_p95_file="${run_dir}/schbench_p95.txt"
    local sb_p99_file="${run_dir}/schbench_p99.txt"
    > "$sys_eps_file"
    > "$sb_p50_file"
    > "$sb_p95_file"
    > "$sb_p99_file"

    log_info "Running mixed workload ($ITERATIONS iterations)..."
    log_info "  sysbench (${SYS_THREADS_MIXED} threads) + schbench running concurrently"

    for i in $(seq 1 $ITERATIONS); do
        log_progress "$i" "mixed workload"
        collect_system_stats "${run_dir}/stats_run${i}_before.txt"

        local sys_raw="${run_dir}/sysbench_raw_run${i}.txt"
        local sb_raw="${run_dir}/schbench_raw_run${i}.txt"

        local sys_cmd="sysbench cpu --cpu-max-prime=${SYS_PRIME} --threads=${SYS_THREADS_MIXED} run"
        local sb_cmd="schbench -m ${SB_WORKERS} -t ${SB_THREADS} -r ${SB_RUNTIME} -s ${SB_SLEEP} -c ${SB_CPU}"

        if [[ "$SCHEDULER" == "awrr" ]]; then
            # Run both under AWRR concurrently
            "$AWRR_SETPOLICY" --run "$sb_cmd" > "$sb_raw" 2>&1 &
            local sb_pid=$!
            "$AWRR_SETPOLICY" --run "$sys_cmd" > "$sys_raw" 2>&1 &
            local sys_pid=$!
        else
            # Run both concurrently under default scheduler
            eval "$sb_cmd" > "$sb_raw" 2>&1 &
            local sb_pid=$!
            eval "$sys_cmd" > "$sys_raw" 2>&1 &
            local sys_pid=$!
        fi

        # Wait for both to finish
        wait "$sys_pid" 2>/dev/null || true
        wait "$sb_pid" 2>/dev/null || true

        # Parse sysbench output
        local eps
        eps=$(grep -oP 'events per second:\s*\K[0-9]+\.?[0-9]*' "$sys_raw" 2>/dev/null || echo "0")
        echo "$eps" >> "$sys_eps_file"

        # Parse schbench output
        local p50 p95 p99
        p50=$(grep -oP '\*?50\.0th:\s*\K[0-9]+' "$sb_raw" 2>/dev/null | tail -1 || echo "0")
        p95=$(grep -oP '\*?95\.0th:\s*\K[0-9]+' "$sb_raw" 2>/dev/null | tail -1 || echo "0")
        p99=$(grep -oP '\*?99\.0th:\s*\K[0-9]+' "$sb_raw" 2>/dev/null | tail -1 || echo "0")
        echo "${p50:-0}" >> "$sb_p50_file"
        echo "${p95:-0}" >> "$sb_p95_file"
        echo "${p99:-0}" >> "$sb_p99_file"

        collect_system_stats "${run_dir}/stats_run${i}_after.txt"
        sleep 2
    done

    # Calculate statistics
    local mean_eps sd_eps mean_p50 mean_p95 mean_p99
    mean_eps=$(calc_mean "$sys_eps_file")
    sd_eps=$(calc_stddev "$sys_eps_file")
    mean_p50=$(calc_mean "$sb_p50_file")
    mean_p95=$(calc_mean "$sb_p95_file")
    mean_p99=$(calc_mean "$sb_p99_file")

    cat > "${run_dir}/summary.txt" <<EOF
sysbench_eps_mean=$mean_eps
sysbench_eps_stddev=$sd_eps
schbench_p50_mean=$mean_p50
schbench_p95_mean=$mean_p95
schbench_p99_mean=$mean_p99
EOF
    log_info "mixed: sysbench=${mean_eps} eps, schbench p50=${mean_p50}us p95=${mean_p95}us p99=${mean_p99}us"
}

# ── Generate Summary CSV ──────────────────────────────────────────────────────

generate_csv() {
    local csv="${RESULTS_DIR}/summary.csv"
    log_info "Generating summary CSV: $csv"

    echo "benchmark,metric,mean,stddev" > "$csv"

    # hackbench
    if [[ -f "${RESULTS_DIR}/hackbench/summary.txt" ]]; then
        local hb_mean hb_sd
        hb_mean=$(grep 'mean=' "${RESULTS_DIR}/hackbench/summary.txt" | cut -d= -f2)
        hb_sd=$(grep 'stddev=' "${RESULTS_DIR}/hackbench/summary.txt" | cut -d= -f2)
        echo "hackbench,time_seconds,$hb_mean,$hb_sd" >> "$csv"
    fi

    # schbench
    if [[ -f "${RESULTS_DIR}/schbench/summary.txt" ]]; then
        while IFS='=' read -r key val; do
            echo "schbench,$key,$val," >> "$csv"
        done < "${RESULTS_DIR}/schbench/summary.txt"
    fi

    # sysbench
    if [[ -f "${RESULTS_DIR}/sysbench/summary.txt" ]]; then
        while IFS='=' read -r key val; do
            echo "sysbench,$key,$val," >> "$csv"
        done < "${RESULTS_DIR}/sysbench/summary.txt"
    fi

    # mixed
    if [[ -f "${RESULTS_DIR}/mixed/summary.txt" ]]; then
        while IFS='=' read -r key val; do
            echo "mixed,$key,$val," >> "$csv"
        done < "${RESULTS_DIR}/mixed/summary.txt"
    fi
}

# ── Generate Human-Readable Report ───────────────────────────────────────────

generate_report() {
    local report="${RESULTS_DIR}/report.txt"
    log_info "Generating report: $report"

    cat > "$report" <<EOF
================================================================================
  AWRR Scheduler Benchmark Report
================================================================================
  Scheduler:   ${SCHEDULER}
  Date:        $(date)
  Iterations:  ${ITERATIONS}
  Kernel:      $(uname -r)
  CPU:         $(lscpu 2>/dev/null | grep 'Model name' | sed 's/Model name:\s*//' || echo "N/A")
  Cores:       $(nproc 2>/dev/null || echo "N/A")
  Memory:      $(free -h 2>/dev/null | awk '/Mem:/{print $2}' || echo "N/A")
================================================================================

1. HACKBENCH (Process Scheduling Throughput)
   Command: hackbench -g ${HB_GROUPS} -f ${HB_FDS} -l ${HB_LOOPS} -s ${HB_SIZE} -P
   ────────────────────────────────────────────
EOF

    if [[ -f "${RESULTS_DIR}/hackbench/summary.txt" ]]; then
        local hb_mean hb_sd
        hb_mean=$(grep 'mean=' "${RESULTS_DIR}/hackbench/summary.txt" | cut -d= -f2)
        hb_sd=$(grep 'stddev=' "${RESULTS_DIR}/hackbench/summary.txt" | cut -d= -f2)
        echo "   Mean Time:   ${hb_mean} seconds" >> "$report"
        echo "   Std Dev:     ${hb_sd} seconds" >> "$report"
        echo "" >> "$report"
        echo "   Per-run times:" >> "$report"
        local n=1
        while read -r t; do
            printf "     Run %2d: %s s\n" "$n" "$t" >> "$report"
            n=$((n + 1))
        done < "${RESULTS_DIR}/hackbench/times.txt"
    else
        echo "   (no data)" >> "$report"
    fi

    cat >> "$report" <<EOF

2. SCHBENCH (Scheduling Latency)
   Command: schbench -m ${SB_WORKERS} -t ${SB_THREADS} -r ${SB_RUNTIME} -s ${SB_SLEEP} -c ${SB_CPU}
   ────────────────────────────────────────────
EOF

    if [[ -f "${RESULTS_DIR}/schbench/summary.txt" ]]; then
        source "${RESULTS_DIR}/schbench/summary.txt"
        echo "   p50 Latency:  ${p50_mean} us  (stddev: ${p50_stddev})" >> "$report"
        echo "   p95 Latency:  ${p95_mean} us  (stddev: ${p95_stddev})" >> "$report"
        echo "   p99 Latency:  ${p99_mean} us  (stddev: ${p99_stddev})" >> "$report"
    else
        echo "   (no data)" >> "$report"
    fi

    cat >> "$report" <<EOF

3. SYSBENCH CPU (Throughput)
   Command: sysbench cpu --cpu-max-prime=${SYS_PRIME} --threads=${SYS_THREADS} run
   ────────────────────────────────────────────
EOF

    if [[ -f "${RESULTS_DIR}/sysbench/summary.txt" ]]; then
        source "${RESULTS_DIR}/sysbench/summary.txt"
        echo "   Events/sec:   ${events_per_sec_mean}  (stddev: ${events_per_sec_stddev})" >> "$report"
        echo "   Total Time:   ${total_time_mean} s  (stddev: ${total_time_stddev})" >> "$report"
    else
        echo "   (no data)" >> "$report"
    fi

    cat >> "$report" <<EOF

4. MIXED WORKLOAD (sysbench ${SYS_THREADS_MIXED} threads + schbench concurrent)
   ────────────────────────────────────────────
EOF

    if [[ -f "${RESULTS_DIR}/mixed/summary.txt" ]]; then
        source "${RESULTS_DIR}/mixed/summary.txt"
        echo "   sysbench Events/sec:  ${sysbench_eps_mean}  (stddev: ${sysbench_eps_stddev})" >> "$report"
        echo "   schbench p50:         ${schbench_p50_mean} us" >> "$report"
        echo "   schbench p95:         ${schbench_p95_mean} us" >> "$report"
        echo "   schbench p99:         ${schbench_p99_mean} us" >> "$report"
    else
        echo "   (no data)" >> "$report"
    fi

    cat >> "$report" <<EOF

================================================================================
  Results directory: ${RESULTS_DIR}
  CSV data:          ${RESULTS_DIR}/summary.csv
================================================================================
EOF

    echo ""
    cat "$report"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    if [[ -z "$SCHEDULER" ]]; then
        usage
    fi

    case "$SCHEDULER" in
        awrr|cfs|eevdf|static-wrr) ;;
        *)
            log_error "Unknown scheduler: $SCHEDULER"
            usage
            ;;
    esac

    check_root
    check_tools

    mkdir -p "$RESULTS_DIR"

    log_info "========================================"
    log_info "Benchmark Suite: ${SCHEDULER}"
    log_info "Iterations: ${ITERATIONS}"
    log_info "Results: ${RESULTS_DIR}"
    log_info "========================================"

    # Save environment info
    cat > "${RESULTS_DIR}/environment.txt" <<EOF
scheduler=$SCHEDULER
timestamp=$TIMESTAMP
kernel=$(uname -r)
hostname=$(hostname)
nproc=$(nproc 2>/dev/null || echo "N/A")
date=$(date)
EOF

    run_hackbench
    run_schbench
    run_sysbench
    run_mixed
    generate_csv
    generate_report

    log_info "All benchmarks complete!"
    log_info "Results saved to: ${RESULTS_DIR}"
}

main "$@"
