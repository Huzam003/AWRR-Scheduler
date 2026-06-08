#!/usr/bin/env bash
# ==============================================================================
# compare_results.sh — Compare benchmark results across schedulers
#
# Usage: ./compare_results.sh <results_dir_1> <results_dir_2> [results_dir_3] ...
#
# Example:
#   ./compare_results.sh results/cfs_20260525_120000 results/awrr_20260525_130000
#
# Outputs a comparison table to terminal and saves comparison.csv
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Argument Handling ─────────────────────────────────────────────────────────

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <results_dir_1> <results_dir_2> [results_dir_3] ..."
    echo ""
    echo "Each results_dir should be a directory created by run_benchmarks.sh,"
    echo "e.g., results/cfs_20260525_120000"
    echo ""
    echo "Available result directories:"
    BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [[ -d "${BASE_DIR}/results" ]]; then
        ls -d "${BASE_DIR}"/results/*/ 2>/dev/null | while read -r d; do
            local_sched=$(grep 'scheduler=' "$d/environment.txt" 2>/dev/null | cut -d= -f2 || basename "$d")
            echo "  $d  ($local_sched)"
        done
    else
        echo "  (no results directory found)"
    fi
    exit 1
fi

DIRS=("$@")
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${BASE_DIR}/results"
CSV_FILE="${OUTPUT_DIR}/comparison.csv"

# ── Helper Functions ──────────────────────────────────────────────────────────

# Read a value from a summary.txt file: get_val <dir> <benchmark> <key>
get_val() {
    local dir="$1" bench="$2" key="$3"
    local file="${dir}/${bench}/summary.txt"
    if [[ -f "$file" ]]; then
        grep "^${key}=" "$file" 2>/dev/null | cut -d= -f2 || echo "N/A"
    else
        echo "N/A"
    fi
}

# Get scheduler name from environment.txt
get_sched_name() {
    local dir="$1"
    if [[ -f "${dir}/environment.txt" ]]; then
        grep 'scheduler=' "${dir}/environment.txt" 2>/dev/null | cut -d= -f2 || basename "$dir"
    else
        basename "$dir"
    fi
}

# Calculate percentage change: pct_change <baseline> <test>
# Positive = test is higher, Negative = test is lower
pct_change() {
    local base="$1" test="$2"
    if [[ "$base" == "N/A" || "$test" == "N/A" || "$base" == "0" || "$base" == "0.0000" ]]; then
        echo "N/A"
        return
    fi
    awk "BEGIN { printf \"%.2f\", (($test - $base) / $base) * 100 }"
}

# Format percentage with color: green if improvement, red if regression
# For "lower is better" metrics (time, latency): negative = green
# For "higher is better" metrics (throughput): positive = green
format_pct() {
    local pct="$1" lower_is_better="${2:-1}"

    if [[ "$pct" == "N/A" ]]; then
        echo "  N/A"
        return
    fi

    local is_good=0
    if [[ "$lower_is_better" -eq 1 ]]; then
        # Lower is better: negative change = improvement
        is_good=$(awk "BEGIN { print ($pct < 0) ? 1 : 0 }")
    else
        # Higher is better: positive change = improvement
        is_good=$(awk "BEGIN { print ($pct > 0) ? 1 : 0 }")
    fi

    if [[ "$is_good" -eq 1 ]]; then
        echo -e "${GREEN}${pct}%${NC}"
    else
        # Check if it's exactly 0
        local is_zero
        is_zero=$(awk "BEGIN { print ($pct == 0) ? 1 : 0 }")
        if [[ "$is_zero" -eq 1 ]]; then
            echo -e "${YELLOW}${pct}%${NC}"
        else
            echo -e "${RED}+${pct}%${NC}"
        fi
    fi
}

# ── Collect Data ──────────────────────────────────────────────────────────────

# Arrays to store names and values
declare -a NAMES
for dir in "${DIRS[@]}"; do
    if [[ ! -d "$dir" ]]; then
        echo -e "${RED}[ERROR]${NC} Directory not found: $dir"
        exit 1
    fi
    NAMES+=("$(get_sched_name "$dir")")
done

# ── Print Comparison Table ────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}================================================================================${NC}"
echo -e "${BOLD}  Scheduler Benchmark Comparison${NC}"
echo -e "${BOLD}================================================================================${NC}"
echo ""

# Header row
printf "  %-30s" "Metric"
for name in "${NAMES[@]}"; do
    printf "%-18s" "$name"
done
# Add change column if exactly 2 dirs
if [[ ${#DIRS[@]} -eq 2 ]]; then
    printf "%-14s" "Change"
fi
echo ""
printf "  %-30s" "-----"
for name in "${NAMES[@]}"; do
    printf "%-18s" "-----"
done
if [[ ${#DIRS[@]} -eq 2 ]]; then
    printf "%-14s" "-----"
fi
echo ""

# ── hackbench ──

echo -e "\n${CYAN}  HACKBENCH (lower = better)${NC}"

printf "  %-30s" "Time (seconds)"
declare -a hb_means
for dir in "${DIRS[@]}"; do
    val=$(get_val "$dir" "hackbench" "mean")
    hb_means+=("$val")
    printf "%-18s" "$val"
done
if [[ ${#DIRS[@]} -eq 2 ]]; then
    pct=$(pct_change "${hb_means[0]}" "${hb_means[1]}")
    printf "%-14b" "$(format_pct "$pct" 1)"
fi
echo ""
unset hb_means

printf "  %-30s" "Stddev"
for dir in "${DIRS[@]}"; do
    printf "%-18s" "$(get_val "$dir" "hackbench" "stddev")"
done
echo ""

# ── schbench ──

echo -e "\n${CYAN}  SCHBENCH Latency (lower = better)${NC}"

for percentile in p50 p95 p99; do
    printf "  %-30s" "${percentile} (us)"
    declare -a sb_vals
    for dir in "${DIRS[@]}"; do
        val=$(get_val "$dir" "schbench" "${percentile}_mean")
        sb_vals+=("$val")
        printf "%-18s" "$val"
    done
    if [[ ${#DIRS[@]} -eq 2 ]]; then
        pct=$(pct_change "${sb_vals[0]}" "${sb_vals[1]}")
        printf "%-14b" "$(format_pct "$pct" 1)"
    fi
    echo ""
    unset sb_vals
done

# ── sysbench ──

echo -e "\n${CYAN}  SYSBENCH CPU (higher throughput = better, lower time = better)${NC}"

printf "  %-30s" "Events/sec"
declare -a sys_eps
for dir in "${DIRS[@]}"; do
    val=$(get_val "$dir" "sysbench" "events_per_sec_mean")
    sys_eps+=("$val")
    printf "%-18s" "$val"
done
if [[ ${#DIRS[@]} -eq 2 ]]; then
    pct=$(pct_change "${sys_eps[0]}" "${sys_eps[1]}")
    printf "%-14b" "$(format_pct "$pct" 0)"
fi
echo ""
unset sys_eps

printf "  %-30s" "Total Time (s)"
declare -a sys_time
for dir in "${DIRS[@]}"; do
    val=$(get_val "$dir" "sysbench" "total_time_mean")
    sys_time+=("$val")
    printf "%-18s" "$val"
done
if [[ ${#DIRS[@]} -eq 2 ]]; then
    pct=$(pct_change "${sys_time[0]}" "${sys_time[1]}")
    printf "%-14b" "$(format_pct "$pct" 1)"
fi
echo ""
unset sys_time

# ── mixed workload ──

echo -e "\n${CYAN}  MIXED WORKLOAD${NC}"

printf "  %-30s" "sysbench Events/sec"
declare -a mix_eps
for dir in "${DIRS[@]}"; do
    val=$(get_val "$dir" "mixed" "sysbench_eps_mean")
    mix_eps+=("$val")
    printf "%-18s" "$val"
done
if [[ ${#DIRS[@]} -eq 2 ]]; then
    pct=$(pct_change "${mix_eps[0]}" "${mix_eps[1]}")
    printf "%-14b" "$(format_pct "$pct" 0)"
fi
echo ""
unset mix_eps

for percentile in p50 p95 p99; do
    printf "  %-30s" "schbench ${percentile} (us)"
    declare -a mix_sb
    for dir in "${DIRS[@]}"; do
        val=$(get_val "$dir" "mixed" "schbench_${percentile}_mean")
        mix_sb+=("$val")
        printf "%-18s" "$val"
    done
    if [[ ${#DIRS[@]} -eq 2 ]]; then
        pct=$(pct_change "${mix_sb[0]}" "${mix_sb[1]}")
        printf "%-14b" "$(format_pct "$pct" 1)"
    fi
    echo ""
    unset mix_sb
done

echo ""
echo -e "${BOLD}================================================================================${NC}"
echo ""

# ── Generate CSV ──────────────────────────────────────────────────────────────

mkdir -p "$OUTPUT_DIR"

{
    # Header
    printf "benchmark,metric"
    for name in "${NAMES[@]}"; do
        printf ",%s" "$name"
    done
    if [[ ${#DIRS[@]} -eq 2 ]]; then
        printf ",pct_change"
    fi
    echo ""

    # hackbench
    printf "hackbench,time_seconds"
    declare -a row_vals
    for dir in "${DIRS[@]}"; do
        val=$(get_val "$dir" "hackbench" "mean")
        row_vals+=("$val")
        printf ",%s" "$val"
    done
    if [[ ${#DIRS[@]} -eq 2 ]]; then
        printf ",%s" "$(pct_change "${row_vals[0]}" "${row_vals[1]}")"
    fi
    echo ""
    unset row_vals

    # schbench
    for p in p50 p95 p99; do
        printf "schbench,%s_us" "$p"
        declare -a row_vals
        for dir in "${DIRS[@]}"; do
            val=$(get_val "$dir" "schbench" "${p}_mean")
            row_vals+=("$val")
            printf ",%s" "$val"
        done
        if [[ ${#DIRS[@]} -eq 2 ]]; then
            printf ",%s" "$(pct_change "${row_vals[0]}" "${row_vals[1]}")"
        fi
        echo ""
        unset row_vals
    done

    # sysbench
    printf "sysbench,events_per_sec"
    declare -a row_vals
    for dir in "${DIRS[@]}"; do
        val=$(get_val "$dir" "sysbench" "events_per_sec_mean")
        row_vals+=("$val")
        printf ",%s" "$val"
    done
    if [[ ${#DIRS[@]} -eq 2 ]]; then
        printf ",%s" "$(pct_change "${row_vals[0]}" "${row_vals[1]}")"
    fi
    echo ""
    unset row_vals

    printf "sysbench,total_time_s"
    declare -a row_vals
    for dir in "${DIRS[@]}"; do
        val=$(get_val "$dir" "sysbench" "total_time_mean")
        row_vals+=("$val")
        printf ",%s" "$val"
    done
    if [[ ${#DIRS[@]} -eq 2 ]]; then
        printf ",%s" "$(pct_change "${row_vals[0]}" "${row_vals[1]}")"
    fi
    echo ""
    unset row_vals

    # mixed
    printf "mixed,sysbench_eps"
    declare -a row_vals
    for dir in "${DIRS[@]}"; do
        val=$(get_val "$dir" "mixed" "sysbench_eps_mean")
        row_vals+=("$val")
        printf ",%s" "$val"
    done
    if [[ ${#DIRS[@]} -eq 2 ]]; then
        printf ",%s" "$(pct_change "${row_vals[0]}" "${row_vals[1]}")"
    fi
    echo ""
    unset row_vals

    for p in p50 p95 p99; do
        printf "mixed,schbench_%s_us" "$p"
        declare -a row_vals
        for dir in "${DIRS[@]}"; do
            val=$(get_val "$dir" "mixed" "schbench_${p}_mean")
            row_vals+=("$val")
            printf ",%s" "$val"
        done
        if [[ ${#DIRS[@]} -eq 2 ]]; then
            printf ",%s" "$(pct_change "${row_vals[0]}" "${row_vals[1]}")"
        fi
        echo ""
        unset row_vals
    done

} > "$CSV_FILE"

echo -e "${GREEN}[INFO]${NC} Comparison CSV saved to: $CSV_FILE"
echo ""
