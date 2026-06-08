#!/usr/bin/env bash
# ==============================================================================
# monitor_awrr.sh — Live monitoring of AWRR scheduler state
#
# Displays:
#   - AWRR sysctl parameters from /proc/sys/kernel/sched_awrr/
#   - All processes running under SCHED_AWRR with their stats
#   - Per-process weight, behavior score, classification
#
# Refreshes every 2 seconds. Press Ctrl+C to exit.
#
# Usage: sudo ./monitor_awrr.sh
# ==============================================================================

set -uo pipefail

REFRESH=2
SCHED_AWRR_POLICY=7

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Cleanup on exit ──────────────────────────────────────────────────────────

cleanup() {
    tput cnorm 2>/dev/null    # Restore cursor
    echo ""
    echo -e "${NC}Monitor stopped."
    exit 0
}

trap cleanup INT TERM

# ── Helper Functions ──────────────────────────────────────────────────────────

# Classify behavior score
classify_score() {
    local score="$1"
    if [[ -z "$score" || "$score" == "N/A" ]]; then
        echo "unknown"
        return
    fi

    # Score is in tenths (0-10), thresholds: >7 CPU-bound, <3 I/O-bound
    if (( score > 7 )); then
        echo -e "${RED}CPU-bound${NC}"
    elif (( score < 3 )); then
        echo -e "${GREEN}I/O-bound${NC}"
    else
        echo -e "${YELLOW}Mixed${NC}"
    fi
}

# Read AWRR sysctl parameters
read_sysctl_params() {
    local sysctl_dir="/proc/sys/kernel/sched_awrr"

    echo -e "${BOLD}  AWRR Sysctl Parameters${NC}"
    echo "  ─────────────────────────────────────────"

    if [[ ! -d "$sysctl_dir" ]]; then
        echo -e "  ${RED}Directory $sysctl_dir not found${NC}"
        echo "  AWRR sysctl interface is not available."
        echo "  Make sure you are running an AWRR-enabled kernel."
        return
    fi

    for param_file in "$sysctl_dir"/*; do
        if [[ -f "$param_file" ]]; then
            local name val
            name=$(basename "$param_file")
            val=$(cat "$param_file" 2>/dev/null || echo "N/A")
            printf "  %-28s %s\n" "$name:" "$val"
        fi
    done
}

# Find all processes using SCHED_AWRR
find_awrr_processes() {
    echo -e "\n${BOLD}  AWRR Processes${NC}"
    echo "  ─────────────────────────────────────────────────────────────────────────"
    printf "  ${DIM}%-8s %-20s %-8s %-8s %-12s %-10s %-12s${NC}\n" \
        "PID" "COMMAND" "WEIGHT" "SCORE" "CLASS" "TICKS" "STATE"
    echo "  ─────────────────────────────────────────────────────────────────────────"

    local count=0

    for pid_dir in /proc/[0-9]*; do
        local pid
        pid=$(basename "$pid_dir")

        # Skip if process disappeared
        [[ ! -d "$pid_dir" ]] && continue

        # Check scheduling policy
        # Method 1: Read /proc/PID/sched if available
        local policy=""

        # Try reading the policy field from /proc/PID/status
        if [[ -f "$pid_dir/status" ]]; then
            # Some kernels expose the policy in /proc/PID/status
            policy=$(grep -i 'policy' "$pid_dir/status" 2>/dev/null | awk '{print $2}' || echo "")
        fi

        # Method 2: Use chrt -p to check (works for standard policies)
        if [[ -z "$policy" ]]; then
            local chrt_out
            chrt_out=$(chrt -p "$pid" 2>/dev/null || echo "")
            if echo "$chrt_out" | grep -qi "SCHED_AWRR\|policy.*${SCHED_AWRR_POLICY}"; then
                policy="$SCHED_AWRR_POLICY"
            fi
        fi

        # Method 3: Check /proc/PID/sched for awrr indicators
        if [[ -z "$policy" || "$policy" != "$SCHED_AWRR_POLICY" ]]; then
            if [[ -f "$pid_dir/sched" ]]; then
                if grep -qi 'awrr\|SCHED_AWRR' "$pid_dir/sched" 2>/dev/null; then
                    policy="$SCHED_AWRR_POLICY"
                fi
            fi
        fi

        # Skip non-AWRR processes
        [[ "$policy" != "$SCHED_AWRR_POLICY" ]] && continue

        # Gather process info
        local comm weight score ticks state classification
        comm=$(cat "$pid_dir/comm" 2>/dev/null || echo "?")
        state=$(awk '{print $3}' "$pid_dir/stat" 2>/dev/null || echo "?")

        # Try to read AWRR-specific info from /proc/PID/sched
        weight="N/A"
        score="N/A"
        ticks="N/A"

        if [[ -f "$pid_dir/sched" ]]; then
            # Look for AWRR-specific fields the kernel might expose
            weight=$(grep -oP 'awrr\.weight\s*:\s*\K[0-9]+' "$pid_dir/sched" 2>/dev/null || echo "N/A")
            score=$(grep -oP 'awrr\.behavior_score\s*:\s*\K[0-9]+' "$pid_dir/sched" 2>/dev/null || echo "N/A")
            ticks=$(grep -oP 'awrr\.total_ticks\s*:\s*\K[0-9]+' "$pid_dir/sched" 2>/dev/null || echo "N/A")

            # Alternative field names
            if [[ "$weight" == "N/A" ]]; then
                weight=$(grep -oP 'weight\s*:\s*\K[0-9]+' "$pid_dir/sched" 2>/dev/null | head -1 || echo "N/A")
            fi
        fi

        classification=$(classify_score "$score")

        # Map state letter to human-readable
        case "$state" in
            R) state="Running" ;;
            S) state="Sleeping" ;;
            D) state="Disk IO" ;;
            T) state="Stopped" ;;
            Z) state="Zombie" ;;
            *) state="$state" ;;
        esac

        printf "  %-8s %-20s %-8s %-8s %-12b %-10s %-12s\n" \
            "$pid" "${comm:0:20}" "$weight" "$score" "$classification" "$ticks" "$state"

        count=$((count + 1))
    done

    if [[ $count -eq 0 ]]; then
        echo -e "  ${DIM}(no processes using SCHED_AWRR found)${NC}"
        echo ""
        echo -e "  ${DIM}Assign a process with:${NC}"
        echo -e "  ${DIM}  sudo ./assign_awrr.sh --pid <PID>${NC}"
        echo -e "  ${DIM}  sudo ./assign_awrr.sh --run \"your_command\"${NC}"
    fi

    echo ""
    echo -e "  ${DIM}Total AWRR processes: $count${NC}"
}

# ── Main Loop ─────────────────────────────────────────────────────────────────

main() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR]${NC} This script must be run as root (sudo)."
        exit 1
    fi

    tput civis 2>/dev/null    # Hide cursor

    while true; do
        clear

        echo -e "${BOLD}================================================================================${NC}"
        echo -e "${BOLD}  AWRR Scheduler Monitor${NC}    $(date '+%Y-%m-%d %H:%M:%S')    Kernel: $(uname -r)"
        echo -e "${BOLD}================================================================================${NC}"
        echo ""

        read_sysctl_params
        find_awrr_processes

        echo ""
        echo -e "  ${DIM}Refreshing every ${REFRESH}s | Press Ctrl+C to exit${NC}"
        echo -e "${BOLD}================================================================================${NC}"

        sleep "$REFRESH"
    done
}

main "$@"
