#!/bin/bash
# Build a complete pi4-touch-demo image from scratch
#
# Usage:
#   ./build-image.sh [OPTIONS]
#
# Options:
#   --baseimage <path>     Path to RaspiOS base image (.img.xz)
#                          Default: downloads 2025-10-01-raspios-bookworm-arm64-lite.img.xz
#   --work-dir <path>      Working directory (default: ~/pi4-img-builder)
#   --password <pass>      Pi user password (default: brb0x)
#   --version <ver>        Image version string (default: 01.02)
#   --skip-base            Skip stage 1 (reuse existing base image)
#   --skip-kernel          Skip stage 2 (reuse existing kernel)
#   --skip-apps            Skip stage 3 (skip app installation)
#   --kernel-branch <br>   Kernel branch (default: rpi-6.12.y)
#   --br-wrapper-branch <br> br-wrapper branch (default: 983-dynamic-config)
#   --help                 Show this help
#
# Example:
#   # Full build from scratch (downloads RaspiOS image)
#   sudo ./build-image.sh
#
#   # Full build with existing base image
#   sudo ./build-image.sh --baseimage ~/2025-10-01-raspios-bookworm-arm64-lite.img.xz
#
#   # Rebuild only apps (kernel already built)
#   sudo ./build-image.sh --skip-base --skip-kernel
set -e

# Defaults
WORK_DIR="$HOME/pi4-img-builder"
PASSWORD="brb0x"
VERSION="01.02"
EXTEND_SIZE_MB=1800
KERNEL_BRANCH="rpi-6.12.y"
BR_WRAPPER_BRANCH="983-dynamic-config"
RASPIOS_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-10-13/2025-10-01-raspios-bookworm-arm64-lite.img.xz"
BASE_IMAGE=""
SKIP_BASE=false
SKIP_KERNEL=false
SKIP_APPS=false

# Resolve script directory (board config location)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MISC_TOOLS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOARD_CFG="$SCRIPT_DIR"

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --baseimage)    BASE_IMAGE="$2"; shift 2 ;;
        --baseimage=*)  BASE_IMAGE="${1#*=}"; shift ;;
        --work-dir)     WORK_DIR="$2"; shift 2 ;;
        --work-dir=*)   WORK_DIR="${1#*=}"; shift ;;
        --password)     PASSWORD="$2"; shift 2 ;;
        --password=*)   PASSWORD="${1#*=}"; shift ;;
        --version)      VERSION="$2"; shift 2 ;;
        --version=*)    VERSION="${1#*=}"; shift ;;
        --skip-base)    SKIP_BASE=true; shift ;;
        --skip-kernel)  SKIP_KERNEL=true; shift ;;
        --skip-apps)    SKIP_APPS=true; shift ;;
        --kernel-branch)       KERNEL_BRANCH="$2"; shift 2 ;;
        --kernel-branch=*)     KERNEL_BRANCH="${1#*=}"; shift ;;
        --br-wrapper-branch)   BR_WRAPPER_BRANCH="$2"; shift 2 ;;
        --br-wrapper-branch=*) BR_WRAPPER_BRANCH="${1#*=}"; shift ;;
        --help|-h) sed -n '2,/^set -e/{ /^#/s/^# \?//p }' "$0"; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Derived paths
IMAGER="$MISC_TOOLS_DIR/custom-pi-imager/custom-pi-imager.sh"
KERNEL_BUILDER="$MISC_TOOLS_DIR/custom-pi-kernel-builder/scripts/00-build-all.sh"
KERNEL_CONFIG="$MISC_TOOLS_DIR/custom-pi-kernel-builder/configs/config-6.12.47+rpt-rpi-v8"
BR_WRAPPER_DIR="$WORK_DIR/br-wrapper"

echo "======================================"
echo "  pi4-touch-demo Image Builder"
echo "======================================"
echo ""
echo "  Work dir:       $WORK_DIR"
echo "  Board config:   $BOARD_CFG"
echo "  Misc-tools:     $MISC_TOOLS_DIR"
echo "  Version:        $VERSION"
echo "  Kernel branch:  $KERNEL_BRANCH"
echo "  br-wrapper:     $BR_WRAPPER_BRANCH"
echo ""

# Ensure work directory exists
mkdir -p "$WORK_DIR"

# Determine base image filename (without .xz)
if [ -n "$BASE_IMAGE" ]; then
    RASPIOS_XZ="$BASE_IMAGE"
else
    RASPIOS_XZ="$WORK_DIR/$(basename "$RASPIOS_URL")"
fi
RASPIOS_NAME="$(basename "$RASPIOS_XZ" .xz)"
BASE_IMG="$WORK_DIR/${RASPIOS_NAME%.img}-base-micropanel-${VERSION}.img"

# ==========================================
# Stage 0: Download and clone prerequisites
# ==========================================
echo "=== Stage 0: Prerequisites ==="

# Download RaspiOS if needed
if [ -z "$BASE_IMAGE" ] && [ ! -f "$RASPIOS_XZ" ]; then
    echo "Downloading RaspiOS image..."
    wget -O "$RASPIOS_XZ" "$RASPIOS_URL"
fi

# Clone br-wrapper for kernel driver build (stage 2)
if [ ! -d "$BR_WRAPPER_DIR" ]; then
    echo "Cloning br-wrapper ($BR_WRAPPER_BRANCH)..."
    git clone -b "$BR_WRAPPER_BRANCH" https://github.com/hackboxguy/br-wrapper.git "$BR_WRAPPER_DIR"
else
    echo "br-wrapper already cloned at $BR_WRAPPER_DIR"
    # Ensure correct branch
    cd "$BR_WRAPPER_DIR"
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [ "$CURRENT_BRANCH" != "$BR_WRAPPER_BRANCH" ]; then
        echo "Switching br-wrapper to branch: $BR_WRAPPER_BRANCH"
        git checkout "$BR_WRAPPER_BRANCH"
    fi
    git pull --ff-only 2>/dev/null || true
    cd "$WORK_DIR"
fi

# ==========================================
# Stage 1: Base OS image
# ==========================================
if [ "$SKIP_BASE" = false ]; then
    echo ""
    echo "=== Stage 1: Base OS Image ==="
    "$IMAGER" \
        --mode=base \
        --baseimage="$RASPIOS_XZ" \
        --output=/tmp/pi4-touch-base \
        --password="$PASSWORD" \
        --extend-size-mb="$EXTEND_SIZE_MB" \
        --runtime-package="$BOARD_CFG/pi4-touch-demo-runtime-deps.txt" \
        --builddep-package="$BOARD_CFG/pi4-touch-demo-build-deps.txt" \
        --version="$VERSION"

    chown -R "${SUDO_USER:-$USER}:$(id -gn "${SUDO_USER:-$USER}")" /tmp/pi4-touch-base
    mv "/tmp/pi4-touch-base/$RASPIOS_NAME" "$BASE_IMG"
    echo "Base image: $BASE_IMG"
else
    echo ""
    echo "=== Stage 1: SKIPPED (--skip-base) ==="
    if [ ! -f "$BASE_IMG" ]; then
        echo "ERROR: Base image not found: $BASE_IMG"
        echo "Run without --skip-base first."
        exit 1
    fi
fi

# ==========================================
# Stage 2: Kernel drivers
# ==========================================
if [ "$SKIP_KERNEL" = false ]; then
    echo ""
    echo "=== Stage 2: Kernel Drivers ==="
    "$KERNEL_BUILDER" \
        --branch "$KERNEL_BRANCH" \
        --config "$KERNEL_CONFIG" \
        --drivers "$BR_WRAPPER_DIR/package" \
        --image "$BASE_IMG" \
        --build-dir "$WORK_DIR/kernel-build" \
        --backup
else
    echo ""
    echo "=== Stage 2: SKIPPED (--skip-kernel) ==="
fi

# ==========================================
# Stage 3: Apps and services
# ==========================================
if [ "$SKIP_APPS" = false ]; then
    echo ""
    echo "=== Stage 3: Apps & Services ==="
    "$IMAGER" \
        --mode=incremental \
        --baseimage="$BASE_IMG" \
        --output=/tmp/pi4-touch-final \
        --builddep-package="$BOARD_CFG/pi4-touch-demo-build-deps.txt" \
        --setup-hook-list="$BOARD_CFG/pi4-touch-demo-packages.txt" \
        --version="$VERSION"

    echo ""
    echo "======================================"
    echo "  Build Complete!"
    echo "======================================"
    echo "  Final image: /tmp/pi4-touch-final/$RASPIOS_NAME"
    echo "======================================"
else
    echo ""
    echo "=== Stage 3: SKIPPED (--skip-apps) ==="
fi
