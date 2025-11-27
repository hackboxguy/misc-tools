#!/bin/bash
# ==============================================================================
# Script 4: Build Custom Out-of-Tree Drivers
# ==============================================================================
# This script cross-compiles the custom hh983-serializer and himax-touch
# kernel modules and their device tree overlays.
#
# Drivers:
#   - hh983-serializer: TI FPDLink serializer driver
#   - himax-touch: Himax TDDI touchscreen driver
#
# Usage: ./04-build-drivers.sh [OPTIONS]
#   --clean            : Clean driver build directories before building
#   --kernel <path>    : Path to kernel source directory (built by 03-build-kernel.sh)
#                        Default: $KERNEL_SRC from config.env
#   --drivers <path>   : Path to driver packages directory (containing hh983-serializer/
#                        and himax-touch/ subdirectories)
#                        Default: $DRIVER_PKG_DIR from config.env
#   --output <path>    : Output directory for built modules and overlays
#                        Default: $BUILD_OUTPUT from config.env
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
CUSTOM_KERNEL=""
CUSTOM_DRIVERS=""
CUSTOM_OUTPUT=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --clean)
            DO_CLEAN=1
            shift
            ;;
        --kernel)
            CUSTOM_KERNEL="$2"
            shift 2
            ;;
        --kernel=*)
            CUSTOM_KERNEL="${1#*=}"
            shift
            ;;
        --drivers)
            CUSTOM_DRIVERS="$2"
            shift 2
            ;;
        --drivers=*)
            CUSTOM_DRIVERS="${1#*=}"
            shift
            ;;
        --output)
            CUSTOM_OUTPUT="$2"
            shift 2
            ;;
        --output=*)
            CUSTOM_OUTPUT="${1#*=}"
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Usage: $0 [--clean] [--kernel <path>] [--drivers <path>] [--output <path>]"
            echo "  --clean          : Clean before building"
            echo "  --kernel <path>  : Kernel source directory"
            echo "  --drivers <path> : Driver packages directory (with hh983-serializer/ and himax-touch/)"
            echo "  --output <path>  : Output directory for built modules"
            exit 1
            ;;
    esac
done

# Override paths if custom arguments provided
if [[ -n "$CUSTOM_KERNEL" ]]; then
    if [[ ! -d "$CUSTOM_KERNEL" ]]; then
        log_error "Kernel directory not found: $CUSTOM_KERNEL"
        exit 1
    fi
    KERNEL_SRC="$CUSTOM_KERNEL"
    log_info "Using custom kernel source: $KERNEL_SRC"
fi

if [[ -n "$CUSTOM_DRIVERS" ]]; then
    if [[ ! -d "$CUSTOM_DRIVERS" ]]; then
        log_error "Drivers directory not found: $CUSTOM_DRIVERS"
        exit 1
    fi
    DRIVER_PKG_DIR="$CUSTOM_DRIVERS"
    # Update derived paths
    HH983_SRC="$DRIVER_PKG_DIR/hh983-serializer/src"
    HH983_DTS="$DRIVER_PKG_DIR/hh983-serializer/src/hh983-serializer-overlay.dts"
    HIMAX_SRC="$DRIVER_PKG_DIR/himax-touch/src"
    HIMAX_DTS="$DRIVER_PKG_DIR/himax-touch/dts/himax-touch-overlay.dts"
    log_info "Using custom drivers directory: $DRIVER_PKG_DIR"
fi

if [[ -n "$CUSTOM_OUTPUT" ]]; then
    BUILD_OUTPUT="$CUSTOM_OUTPUT"
    log_info "Using custom output directory: $BUILD_OUTPUT"
fi

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

# Check if kernel has been built (needed for Module.symvers)
if [[ ! -f "$KERNEL_SRC/Module.symvers" ]]; then
    log_error "Kernel not built. Run ./03-build-kernel.sh first"
    exit 1
fi

if [[ ! -d "$HH983_SRC" ]]; then
    log_error "hh983-serializer source not found at: $HH983_SRC"
    exit 1
fi

if [[ ! -d "$HIMAX_SRC" ]]; then
    log_error "himax-touch source not found at: $HIMAX_SRC"
    exit 1
fi

if ! command -v dtc &>/dev/null; then
    log_error "Device tree compiler (dtc) not found"
    log_error "Run sudo ./01-setup-arch-deps.sh first"
    exit 1
fi

# Get kernel release
KRELEASE=$(make -C "$KERNEL_SRC" -s kernelrelease 2>/dev/null)

echo "=============================================================================="
echo " Custom Driver Build - Cross-Compilation"
echo "=============================================================================="
echo ""
echo " Kernel source: $KERNEL_SRC"
echo " Kernel release: $KRELEASE"
echo " Architecture: $ARCH"
echo " Cross-compiler: $CROSS_COMPILE"
echo ""
echo " Drivers to build:"
echo "   - hh983-serializer: $HH983_SRC"
echo "   - himax-touch: $HIMAX_SRC"
echo ""

# Set cross-compilation environment
export ARCH="$ARCH"
export CROSS_COMPILE="$CROSS_COMPILE"

# Create output directory
mkdir -p "$BUILD_OUTPUT/modules"
mkdir -p "$BUILD_OUTPUT/overlays"

# ------------------------------------------------------------------------------
# Build hh983-serializer Driver
# ------------------------------------------------------------------------------
echo "=============================================================================="
log_info "Building hh983-serializer driver..."
echo "=============================================================================="

cd "$HH983_SRC"

if [[ $DO_CLEAN -eq 1 ]]; then
    log_info "Cleaning previous build..."
    make -C "$KERNEL_SRC" M="$(pwd)" clean || true
fi

# Build the kernel module
log_info "Compiling kernel module..."
make -C "$KERNEL_SRC" M="$(pwd)" modules

if [[ ! -f "hh983-serializer.ko" ]]; then
    log_error "Failed to build hh983-serializer.ko"
    exit 1
fi

log_success "hh983-serializer.ko built successfully!"

# Copy module to output
cp hh983-serializer.ko "$BUILD_OUTPUT/modules/"

# Show module info
log_info "Module information:"
modinfo hh983-serializer.ko 2>/dev/null | grep -E "^(filename|version|description|author|vermagic):" || true

# Build device tree overlay
log_info "Compiling device tree overlay..."
if [[ -f "$HH983_DTS" ]]; then
    dtc -@ -I dts -O dtb -o "$BUILD_OUTPUT/overlays/hh983-serializer.dtbo" "$HH983_DTS"
    log_success "hh983-serializer.dtbo built successfully!"
else
    log_warn "DTS file not found: $HH983_DTS"
fi

echo ""

# ------------------------------------------------------------------------------
# Build himax-touch Driver
# ------------------------------------------------------------------------------
echo "=============================================================================="
log_info "Building himax-touch driver..."
echo "=============================================================================="

cd "$HIMAX_SRC"

if [[ $DO_CLEAN -eq 1 ]]; then
    log_info "Cleaning previous build..."
    make -C "$KERNEL_SRC" M="$(pwd)" clean || true
fi

# Build the kernel module
log_info "Compiling kernel module..."
make -C "$KERNEL_SRC" M="$(pwd)" modules

if [[ ! -f "himax_mmi.ko" ]]; then
    log_error "Failed to build himax_mmi.ko"
    exit 1
fi

log_success "himax_mmi.ko built successfully!"

# Copy module to output
cp himax_mmi.ko "$BUILD_OUTPUT/modules/"

# Show module info
log_info "Module information:"
modinfo himax_mmi.ko 2>/dev/null | grep -E "^(filename|version|description|author|vermagic):" || true

# Build device tree overlay
log_info "Compiling device tree overlay..."
if [[ -f "$HIMAX_DTS" ]]; then
    dtc -@ -I dts -O dtb -o "$BUILD_OUTPUT/overlays/himax-touch.dtbo" "$HIMAX_DTS"
    log_success "himax-touch.dtbo built successfully!"
else
    log_warn "DTS file not found: $HIMAX_DTS"
fi

# ------------------------------------------------------------------------------
# Verify Built Artifacts
# ------------------------------------------------------------------------------
echo ""
echo "=============================================================================="
log_info "Verifying built artifacts..."
echo "=============================================================================="

echo ""
log_info "Kernel modules:"
ls -lh "$BUILD_OUTPUT/modules/"

echo ""
log_info "Device tree overlays:"
ls -lh "$BUILD_OUTPUT/overlays/"

# Verify module architecture
echo ""
log_info "Module architecture verification:"
for ko in "$BUILD_OUTPUT/modules/"*.ko; do
    ARCH_INFO=$(file "$ko" | grep -o "ARM aarch64" || echo "UNKNOWN")
    BASENAME=$(basename "$ko")
    if [[ "$ARCH_INFO" == "ARM aarch64" ]]; then
        log_success "  $BASENAME: ARM64 ✓"
    else
        log_warn "  $BASENAME: $ARCH_INFO (expected ARM aarch64)"
    fi
done

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "=============================================================================="
echo " Driver Build Complete!"
echo "=============================================================================="
echo ""
echo " Built modules:"
echo "   - $BUILD_OUTPUT/modules/hh983-serializer.ko"
echo "   - $BUILD_OUTPUT/modules/himax_mmi.ko"
echo ""
echo " Built overlays:"
echo "   - $BUILD_OUTPUT/overlays/hh983-serializer.dtbo"
echo "   - $BUILD_OUTPUT/overlays/himax-touch.dtbo"
echo ""
echo " Target kernel release: $KRELEASE"
echo ""
echo " Next step: Run sudo ./05-install-to-image.sh"
echo ""
echo "=============================================================================="
