#!/bin/bash
# ==============================================================================
# Script 3: Build Raspberry Pi Kernel and In-Tree Modules
# ==============================================================================
# This script cross-compiles the Raspberry Pi Linux kernel for Pi 4 (64-bit).
# It builds the kernel Image, device trees, and all in-tree modules.
#
# Based on: https://www.raspberrypi.com/documentation/computers/linux_kernel.html
#
# Usage: ./03-build-kernel.sh [--clean] [--modules-only]
#   --clean        : Run make clean before building
#   --modules-only : Only rebuild modules (skip Image and dtbs)
# ==============================================================================

set -e

# Source configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"

# Should NOT run as root
check_not_root

# ------------------------------------------------------------------------------
# Parse Arguments
# ------------------------------------------------------------------------------
DO_CLEAN=0
MODULES_ONLY=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --clean)
            DO_CLEAN=1
            shift
            ;;
        --modules-only)
            MODULES_ONLY=1
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Verify Prerequisites
# ------------------------------------------------------------------------------
log_info "Verifying prerequisites..."

if [[ ! -d "$KERNEL_SRC" ]]; then
    log_error "Kernel source not found at: $KERNEL_SRC"
    log_error "Run ./02-download-kernel.sh first"
    exit 1
fi

if [[ ! -f "$KERNEL_SRC/.config" ]]; then
    log_error "Kernel not configured. Run ./02-download-kernel.sh first"
    exit 1
fi

if ! command -v "${CROSS_COMPILE}gcc" &>/dev/null; then
    log_error "Cross-compiler not found: ${CROSS_COMPILE}gcc"
    log_error "Run sudo ./01-setup-arch-deps.sh first"
    exit 1
fi

cd "$KERNEL_SRC"

echo "=============================================================================="
echo " Raspberry Pi Kernel - Cross-Compilation Build"
echo "=============================================================================="
echo ""
echo " Kernel source: $KERNEL_SRC"
echo " Architecture: $ARCH"
echo " Cross-compiler: $CROSS_COMPILE"
echo " Parallel jobs: $JOBS"
echo ""

# Set cross-compilation environment
export ARCH="$ARCH"
export CROSS_COMPILE="$CROSS_COMPILE"

# Get kernel version for display
KVERSION=$(make -s kernelversion 2>/dev/null)
KRELEASE=$(make -s kernelrelease 2>/dev/null)
log_info "Building kernel version: $KVERSION (release: $KRELEASE)"

# ------------------------------------------------------------------------------
# Clean Build (Optional)
# ------------------------------------------------------------------------------
if [[ $DO_CLEAN -eq 1 ]]; then
    log_info "Cleaning previous build artifacts..."
    make clean
    log_success "Clean complete"
fi

# ------------------------------------------------------------------------------
# Build Kernel Image
# ------------------------------------------------------------------------------
if [[ $MODULES_ONLY -eq 0 ]]; then
    echo ""
    log_info "Building kernel Image..."
    log_info "This will take some time (using $JOBS parallel jobs)..."
    echo ""

    # Build the kernel Image
    # For Pi 4 64-bit, the target is 'Image' (not zImage or Image.gz)
    time make -j"$JOBS" Image

    log_success "Kernel Image built successfully!"
    ls -lh arch/arm64/boot/Image
fi

# ------------------------------------------------------------------------------
# Build Kernel Modules
# ------------------------------------------------------------------------------
echo ""
log_info "Building kernel modules..."

time make -j"$JOBS" modules

log_success "Kernel modules built successfully!"

# Count built modules
MODULE_COUNT=$(find . -name "*.ko" -type f 2>/dev/null | wc -l)
log_info "Built $MODULE_COUNT kernel modules"

# ------------------------------------------------------------------------------
# Build Device Trees
# ------------------------------------------------------------------------------
if [[ $MODULES_ONLY -eq 0 ]]; then
    echo ""
    log_info "Building device trees..."

    time make -j"$JOBS" dtbs

    log_success "Device trees built successfully!"

    # List relevant DTBs
    log_info "Broadcom device trees:"
    ls -lh arch/arm64/boot/dts/broadcom/*.dtb 2>/dev/null | head -5

    # Count overlays
    OVERLAY_COUNT=$(find arch/arm64/boot/dts/overlays -name "*.dtbo" 2>/dev/null | wc -l)
    log_info "Built $OVERLAY_COUNT device tree overlays"
fi

# ------------------------------------------------------------------------------
# Save Build Information
# ------------------------------------------------------------------------------
mkdir -p "$BUILD_OUTPUT"

# Save kernel release string (used for module installation path)
echo "$KRELEASE" > "$BUILD_OUTPUT/kernel-release.txt"
log_info "Kernel release: $KRELEASE (saved to $BUILD_OUTPUT/kernel-release.txt)"

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "=============================================================================="
echo " Kernel Build Complete!"
echo "=============================================================================="
echo ""
echo " Build artifacts:"
echo "   - Kernel Image:  $KERNEL_SRC/arch/arm64/boot/Image"
echo "   - Device trees:  $KERNEL_SRC/arch/arm64/boot/dts/broadcom/*.dtb"
echo "   - Overlays:      $KERNEL_SRC/arch/arm64/boot/dts/overlays/*.dtbo"
echo "   - Modules:       $MODULE_COUNT modules (in source tree)"
echo ""
echo " Kernel release: $KRELEASE"
echo ""
echo " Next step: Run ./04-build-drivers.sh"
echo ""
echo "=============================================================================="
