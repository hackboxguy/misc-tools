#!/bin/bash
# ==============================================================================
# Script 2: Download and Configure Raspberry Pi Kernel Source
# ==============================================================================
# This script clones the Raspberry Pi Linux kernel source and configures it
# for cross-compilation targeting Raspberry Pi 4 (64-bit).
#
# Based on: https://www.raspberrypi.com/documentation/computers/linux_kernel.html
#
# Usage: ./02-download-kernel.sh [--fresh] [--branch <branch>] [--config <config>]
#   --fresh            : Remove existing source and re-clone
#   --branch <name>    : Use specific kernel branch (default: rpi-6.12.y)
#                        Examples: rpi-6.1.y, rpi-6.6.y, rpi-6.12.y
#   --config <config>  : Kernel configuration to use:
#                        - "defconfig" : Use default bcm2711_defconfig
#                        - <path>      : Use custom config file at specified path
#                        If not specified, uses CUSTOM_KERNEL_CONFIG from config.env
#   --defconfig        : (deprecated) Alias for --config defconfig
# ==============================================================================

set -e

# Source configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"

# Should NOT run as root
check_not_root

echo "=============================================================================="
echo " Raspberry Pi Kernel - Download and Configure"
echo "=============================================================================="
echo ""
echo " Target: Raspberry Pi 4 (64-bit)"
echo " Kernel: $KERNEL"
echo " Branch: $KERNEL_BRANCH"
echo " Architecture: $ARCH"
echo ""

# ------------------------------------------------------------------------------
# Parse Arguments
# ------------------------------------------------------------------------------
FRESH_CLONE=0
CUSTOM_BRANCH=""
CONFIG_ARG=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --fresh)
            FRESH_CLONE=1
            shift
            ;;
        --branch)
            CUSTOM_BRANCH="$2"
            shift 2
            ;;
        --branch=*)
            CUSTOM_BRANCH="${1#*=}"
            shift
            ;;
        --config)
            CONFIG_ARG="$2"
            shift 2
            ;;
        --config=*)
            CONFIG_ARG="${1#*=}"
            shift
            ;;
        --defconfig)
            # Deprecated: kept for backwards compatibility
            CONFIG_ARG="defconfig"
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Usage: $0 [--fresh] [--branch <branch>] [--config <config>]"
            echo "  --fresh            : Remove existing source and re-clone"
            echo "  --branch <name>    : Use specific kernel branch (e.g., rpi-6.1.y)"
            echo "  --config <config>  : Kernel config: 'defconfig' or path to config file"
            exit 1
            ;;
    esac
done

# Override KERNEL_BRANCH if custom branch specified
if [[ -n "$CUSTOM_BRANCH" ]]; then
    log_info "Using custom kernel branch: $CUSTOM_BRANCH"
    KERNEL_BRANCH="$CUSTOM_BRANCH"
fi

# Process --config argument
if [[ -n "$CONFIG_ARG" ]]; then
    if [[ "$CONFIG_ARG" == "defconfig" ]]; then
        log_info "Using default defconfig (bcm2711_defconfig)"
        CUSTOM_KERNEL_CONFIG=""
    elif [[ -f "$CONFIG_ARG" ]]; then
        log_info "Using custom config file: $CONFIG_ARG"
        CUSTOM_KERNEL_CONFIG="$CONFIG_ARG"
    else
        log_error "Config file not found: $CONFIG_ARG"
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# Prepare Build Directory
# ------------------------------------------------------------------------------
log_info "Preparing build directory: $BUILD_BASE"
mkdir -p "$BUILD_BASE"
cd "$BUILD_BASE"

# ------------------------------------------------------------------------------
# Clone or Update Kernel Source
# ------------------------------------------------------------------------------
if [[ -d "$KERNEL_SRC" ]]; then
    if [[ $FRESH_CLONE -eq 1 ]]; then
        log_warn "Removing existing kernel source (--fresh flag)..."
        rm -rf "$KERNEL_SRC"
    else
        log_info "Kernel source exists. Checking for updates..."
        cd "$KERNEL_SRC"

        # Check current branch
        CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        if [[ "$CURRENT_BRANCH" != "$KERNEL_BRANCH" ]]; then
            log_warn "Current branch ($CURRENT_BRANCH) differs from target ($KERNEL_BRANCH)"
            log_info "Consider running with --fresh flag to re-clone"
        fi

        # Try to pull updates
        log_info "Pulling latest changes from $KERNEL_BRANCH..."
        git fetch origin "$KERNEL_BRANCH" --depth=1 || true
        git checkout FETCH_HEAD 2>/dev/null || git checkout "$KERNEL_BRANCH" || true

        cd "$BUILD_BASE"
    fi
fi

if [[ ! -d "$KERNEL_SRC" ]]; then
    log_info "Cloning Raspberry Pi kernel source..."
    log_info "Repository: $KERNEL_REPO"
    log_info "Branch: $KERNEL_BRANCH"
    log_info "This may take a few minutes..."
    echo ""

    # Clone with depth=1 for faster download (as per official RPi docs)
    # The official docs recommend: git clone --depth=1 --branch <branch> <repo>
    git clone --depth="$CLONE_DEPTH" --branch "$KERNEL_BRANCH" "$KERNEL_REPO" linux

    log_success "Kernel source cloned successfully!"
fi

cd "$KERNEL_SRC"

# ------------------------------------------------------------------------------
# Show Kernel Version Info
# ------------------------------------------------------------------------------
log_info "Kernel source information:"

# Get the kernel version from Makefile
KVERSION=$(make -s kernelversion 2>/dev/null || echo "unknown")
log_info "  Kernel version: $KVERSION"

# Get the git commit
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
log_info "  Git commit: $GIT_COMMIT"

# Show localversion if present
if [[ -f "localversion" ]]; then
    log_info "  Local version: $(cat localversion)"
fi

echo ""

# ------------------------------------------------------------------------------
# Configure Kernel
# ------------------------------------------------------------------------------
log_info "Configuring kernel for Raspberry Pi 4 (64-bit)..."

# Clean any previous configuration (optional, but recommended for fresh builds)
# make mrproper

# Set cross-compilation environment
export ARCH="$ARCH"
export CROSS_COMPILE="$CROSS_COMPILE"

# Check if custom kernel config is provided
if [[ -n "$CUSTOM_KERNEL_CONFIG" ]] && [[ -f "$CUSTOM_KERNEL_CONFIG" ]]; then
    log_info "Using custom kernel config from: $CUSTOM_KERNEL_CONFIG"
    cp "$CUSTOM_KERNEL_CONFIG" .config

    # Update config for any new options (answer defaults for new symbols)
    make olddefconfig

    log_success "Kernel configured with custom config"
else
    # Apply the default config for Pi 4
    # bcm2711_defconfig is for Raspberry Pi 4 (64-bit) as per official docs
    log_info "Applying default configuration: $DEFCONFIG"
    make "$DEFCONFIG"

    log_success "Kernel configured with $DEFCONFIG"
fi

# ------------------------------------------------------------------------------
# Disable LOCALVERSION_AUTO to prevent version mismatch
# ------------------------------------------------------------------------------
# CONFIG_LOCALVERSION_AUTO adds a '+' suffix when git tree is dirty or not at
# an exact tag. This causes module version mismatch issues (modules installed to
# 6.12.59-v8 but kernel runs as 6.12.59-v8+). Disable it for consistent versioning.
log_info "Disabling CONFIG_LOCALVERSION_AUTO to prevent version mismatch..."
./scripts/config --disable CONFIG_LOCALVERSION_AUTO

# Apply the change
make olddefconfig

# Verify the change
if grep -q "CONFIG_LOCALVERSION_AUTO=y" .config 2>/dev/null; then
    log_warn "CONFIG_LOCALVERSION_AUTO is still enabled - you may see version mismatch"
else
    log_success "CONFIG_LOCALVERSION_AUTO disabled"
fi

# ------------------------------------------------------------------------------
# Show Configuration Summary
# ------------------------------------------------------------------------------
echo ""
log_info "Configuration summary:"

# Extract some key config values
if [[ -f ".config" ]]; then
    # Show some relevant config options
    grep -E "^CONFIG_LOCALVERSION=" .config 2>/dev/null || true
    grep -E "^CONFIG_ARM64=y" .config 2>/dev/null && log_info "  Architecture: ARM64 ✓"
    grep -E "^CONFIG_SMP=y" .config 2>/dev/null && log_info "  SMP enabled ✓"
    grep -E "^CONFIG_MODULES=y" .config 2>/dev/null && log_info "  Loadable modules enabled ✓"
    grep -E "^CONFIG_I2C=y" .config 2>/dev/null && log_info "  I2C support enabled ✓"
    grep -E "^CONFIG_INPUT_TOUCHSCREEN=y" .config 2>/dev/null && log_info "  Touchscreen support enabled ✓"
    grep -q "CONFIG_LOCALVERSION_AUTO=y" .config 2>/dev/null || log_info "  LOCALVERSION_AUTO disabled ✓ (prevents version mismatch)"
fi

# ------------------------------------------------------------------------------
# Optional: Customize Configuration
# ------------------------------------------------------------------------------
echo ""
log_info "Optional: You can customize the kernel configuration by running:"
log_info "  cd $KERNEL_SRC"
log_info "  ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE make menuconfig"
echo ""

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "=============================================================================="
echo " Download and Configure Complete!"
echo "=============================================================================="
echo ""
echo " Kernel source: $KERNEL_SRC"
echo " Kernel version: $KVERSION"
echo " Configuration: $DEFCONFIG"
echo ""
echo " IMPORTANT: Your target kernel is 6.12.47+rpt-rpi-v8"
echo " Downloaded version: $KVERSION"
echo ""
echo " If the versions don't match exactly, you may get 'version magic' errors."
echo " The modules should still work if the kernel ABI is compatible."
echo ""
echo " Next step: Run ./03-build-kernel.sh"
echo ""
echo "=============================================================================="

# Save kernel version for later scripts
echo "$KVERSION" > "$BUILD_BASE/kernel-version.txt"
