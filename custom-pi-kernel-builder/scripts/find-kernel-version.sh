#!/bin/bash
# ==============================================================================
# Helper: Find Exact Kernel Source Version
# ==============================================================================
# Run this after 02-download-kernel.sh to find the exact commit/tag
# that matches your Pi's kernel version.
#
# Your Pi runs: 6.12.47+rpt-rpi-v8 (built 2025-09-16)
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"

if [[ ! -d "$KERNEL_SRC" ]]; then
    echo "ERROR: Kernel source not found. Run 02-download-kernel.sh first."
    exit 1
fi

cd "$KERNEL_SRC"

echo "=============================================================================="
echo " Finding Kernel Version Information"
echo "=============================================================================="
echo ""

# Current version from source
KVERSION=$(make -s kernelversion 2>/dev/null)
echo "Downloaded kernel version: $KVERSION"
echo ""

# Fetch all tags (may need to unshallow first)
echo "Fetching tags (this may take a moment)..."
git fetch --tags --depth=100 2>/dev/null || git fetch --tags 2>/dev/null || true

echo ""
echo "Available tags matching 6.12:"
git tag -l "*6.12*" 2>/dev/null | tail -20

echo ""
echo "Tags from around September 2025:"
git tag -l "stable_202509*" 2>/dev/null || echo "(no stable_202509* tags found)"

echo ""
echo "Recent commits in rpi-6.12.y branch:"
git log --oneline -10 2>/dev/null || true

echo ""
echo "=============================================================================="
echo " Your Pi's kernel: 6.12.47+rpt-rpi-v8 (Debian 1:6.12.47-1+rpt1 built 2025-09-16)"
echo ""
echo " If the version doesn't match, try:"
echo "   1. git fetch --unshallow  # Get full history"
echo "   2. git checkout <tag>     # Switch to exact version"
echo "   3. Re-run 02-download-kernel.sh"
echo "=============================================================================="
