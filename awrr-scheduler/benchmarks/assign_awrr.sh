#!/usr/bin/env bash
# ==============================================================================
# assign_awrr.sh — Assign a process to the SCHED_AWRR scheduling policy
#
# Uses the awrr_setpolicy helper (compiled C program) since standard tools
# like chrt do not know about the custom SCHED_AWRR policy.
#
# Usage:
#   sudo ./assign_awrr.sh --pid 1234
#   sudo ./assign_awrr.sh --pid 1234 --weight 8
#   sudo ./assign_awrr.sh --run "sysbench cpu --threads=4 run"
#   sudo ./assign_awrr.sh --run "hackbench -g 10 -P"
#
# The --weight flag is informational (the kernel manages weights dynamically),
# but it is passed through to awrr_setpolicy for logging.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETPOLICY="${SCRIPT_DIR}/awrr_setpolicy"
SETPOLICY_SRC="${SCRIPT_DIR}/awrr_setpolicy.c"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ── Check Prerequisites ──────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} This script must be run as root (sudo)."
    exit 1
fi

# Build awrr_setpolicy if not present
if [[ ! -x "$SETPOLICY" ]]; then
    if [[ -f "$SETPOLICY_SRC" ]]; then
        echo -e "${YELLOW}[INFO]${NC} Compiling awrr_setpolicy..."
        gcc -o "$SETPOLICY" "$SETPOLICY_SRC"
        echo -e "${GREEN}[OK]${NC} Built: $SETPOLICY"
    else
        echo -e "${RED}[ERROR]${NC} awrr_setpolicy binary not found and source missing."
        echo "Expected source at: $SETPOLICY_SRC"
        echo "Compile manually: gcc -o awrr_setpolicy awrr_setpolicy.c"
        exit 1
    fi
fi

# ── Parse Arguments ──────────────────────────────────────────────────────────

MODE=""
TARGET_PID=""
RUN_CMD=""
WEIGHT=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pid)
            MODE="pid"
            TARGET_PID="$2"
            shift 2
            ;;
        --run)
            MODE="run"
            RUN_CMD="$2"
            shift 2
            ;;
        --weight)
            WEIGHT="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage:"
            echo "  sudo $0 --pid <PID>              Assign existing process to SCHED_AWRR"
            echo "  sudo $0 --run \"command args\"      Run command under SCHED_AWRR"
            echo "  sudo $0 --pid <PID> --weight <W>  Assign with weight hint (1-10)"
            echo ""
            echo "Examples:"
            echo "  sudo $0 --pid 1234"
            echo "  sudo $0 --run \"sysbench cpu --threads=4 run\""
            echo "  sudo $0 --run \"hackbench -g 10 -f 40 -l 100 -s 100 -P\""
            exit 0
            ;;
        *)
            echo -e "${RED}[ERROR]${NC} Unknown argument: $1"
            echo "Use --help for usage."
            exit 1
            ;;
    esac
done

if [[ -z "$MODE" ]]; then
    echo -e "${RED}[ERROR]${NC} Specify --pid or --run"
    echo "Use --help for usage."
    exit 1
fi

# ── Build awrr_setpolicy Args ────────────────────────────────────────────────

ARGS=()

if [[ "$MODE" == "pid" ]]; then
    if [[ -z "$TARGET_PID" ]]; then
        echo -e "${RED}[ERROR]${NC} --pid requires a PID number."
        exit 1
    fi
    # Verify the PID exists
    if ! kill -0 "$TARGET_PID" 2>/dev/null; then
        echo -e "${RED}[ERROR]${NC} PID $TARGET_PID does not exist."
        exit 1
    fi
    ARGS+=(--pid "$TARGET_PID")
fi

if [[ "$MODE" == "run" ]]; then
    if [[ -z "$RUN_CMD" ]]; then
        echo -e "${RED}[ERROR]${NC} --run requires a command string."
        exit 1
    fi
    ARGS+=(--run "$RUN_CMD")
fi

if [[ -n "$WEIGHT" ]]; then
    ARGS+=(--weight "$WEIGHT")
fi

# ── Execute ───────────────────────────────────────────────────────────────────

exec "$SETPOLICY" "${ARGS[@]}"
