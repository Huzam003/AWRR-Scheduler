#!/usr/bin/env bash
# ==============================================================================
# install_benchtools.sh — Install benchmark tools on Ubuntu (ARM64 or x86_64)
#
# Installs: hackbench, schbench, sysbench, bc, jq
# Run as root: sudo ./install_benchtools.sh
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    log_error "Run this script as root: sudo $0"
    exit 1
fi

log_info "Updating package lists..."
apt-get update -qq

# ── 1. Essential build tools ──────────────────────────────────────────────────

log_info "Installing build essentials..."
apt-get install -y -qq \
    build-essential \
    git \
    bc \
    jq \
    wget \
    curl \
    linux-tools-common \
    2>/dev/null || true

# ── 2. hackbench ──────────────────────────────────────────────────────────────

if command -v hackbench &>/dev/null; then
    log_info "hackbench already installed: $(which hackbench)"
else
    log_info "Installing hackbench..."

    # Try rt-tests package first (contains hackbench)
    if apt-get install -y -qq rt-tests 2>/dev/null; then
        log_info "hackbench installed via rt-tests package."
    else
        # Try linux-tools-generic (some Ubuntu versions)
        if apt-get install -y -qq "linux-tools-$(uname -r)" 2>/dev/null; then
            log_info "hackbench installed via linux-tools."
        else
            # Build from source as last resort
            log_warn "Package install failed. Building hackbench from source..."
            TMPDIR=$(mktemp -d)
            cd "$TMPDIR"
            git clone https://git.kernel.org/pub/scm/utils/rt-tests/rt-tests.git --depth 1
            cd rt-tests
            make hackbench
            cp hackbench /usr/local/bin/
            cd /
            rm -rf "$TMPDIR"
            log_info "hackbench built and installed to /usr/local/bin/hackbench"
        fi
    fi
fi

# ── 3. schbench ───────────────────────────────────────────────────────────────

if command -v schbench &>/dev/null; then
    log_info "schbench already installed: $(which schbench)"
else
    log_info "Building schbench from source..."
    TMPDIR=$(mktemp -d)
    cd "$TMPDIR"

    git clone https://git.kernel.org/pub/scm/linux/kernel/git/mason/schbench.git --depth 1
    cd schbench
    make
    cp schbench /usr/local/bin/
    cd /
    rm -rf "$TMPDIR"

    log_info "schbench built and installed to /usr/local/bin/schbench"
fi

# ── 4. sysbench ───────────────────────────────────────────────────────────────

if command -v sysbench &>/dev/null; then
    log_info "sysbench already installed: $(which sysbench)"
else
    log_info "Installing sysbench..."
    apt-get install -y -qq sysbench
    log_info "sysbench installed."
fi

# ── 5. Verify all tools ──────────────────────────────────────────────────────

echo ""
log_info "============================================"
log_info "Verification:"
echo ""

TOOLS=("hackbench" "schbench" "sysbench" "bc" "jq" "gcc")
ALL_OK=1

for tool in "${TOOLS[@]}"; do
    if command -v "$tool" &>/dev/null; then
        echo -e "  ${GREEN}[OK]${NC}  $tool -> $(which $tool)"
    else
        echo -e "  ${RED}[MISSING]${NC}  $tool"
        ALL_OK=0
    fi
done

echo ""
if [[ $ALL_OK -eq 1 ]]; then
    log_info "All tools installed successfully!"
else
    log_warn "Some tools are missing. Check errors above."
fi

log_info "============================================"
