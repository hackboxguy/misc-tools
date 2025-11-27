#!/bin/bash
# ==============================================================================
# Script 0: Top-Level Build Wrapper
# ==============================================================================
# This script orchestrates the complete build process for Raspberry Pi 4 kernel
# and custom drivers. It calls the individual build scripts in sequence.
#
# Usage: ./00-build-all.sh [OPTIONS]
#
# Required (at minimum --image must be specified):
#   --image <path>       : Path to Raspberry Pi OS image file
#
# Optional:
#   --branch <name>      : Kernel branch (default: rpi-6.12.y)
#   --config <config>    : Kernel config: 'defconfig' or path to config file
#   --drivers <path>     : Path to driver packages directory
#   --build-dir <path>   : Build directory (default: $HOME/rpi-kernel-build)
#   --output <path>      : Output directory for modules/overlays
#   --clean              : Clean build (pass --clean to sub-scripts)
#   --fresh              : Fresh kernel clone (removes existing source)
#   --skip-kernel        : Skip kernel download and build (steps 02-03)
#   --skip-drivers       : Skip driver build (step 04)
#   --backup             : Backup original kernel before installing
#   --dry-run            : Show what would be done without executing
#   --help               : Show this help message
#
# Examples:
#   # Full build with all custom paths
#   ./00-build-all.sh \
#       --branch rpi-6.12.y \
#       --config /path/to/config-6.12.47+rpt-rpi-v8 \
#       --drivers /path/to/br-wrapper/package \
#       --image /path/to/raspios.img \
#       --backup
#
#   # Rebuild only drivers and install (kernel already built)
#   ./00-build-all.sh --skip-kernel --image /path/to/raspios.img
#
#   # Use defaults from config.env, just specify image
#   ./00-build-all.sh --image /path/to/raspios.img
# ==============================================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ------------------------------------------------------------------------------
# Color Output Functions (standalone, not from config.env)
# ------------------------------------------------------------------------------
log_info() {
    echo -e "\033[1;34m[INFO]\033[0m $*"
}

log_success() {
    echo -e "\033[1;32m[SUCCESS]\033[0m $*"
}

log_warn() {
    echo -e "\033[1;33m[WARNING]\033[0m $*"
}

log_error() {
    echo -e "\033[1;31m[ERROR]\033[0m $*"
}

log_step() {
    echo ""
    echo -e "\033[1;35m==>\033[0m \033[1m$*\033[0m"
    echo ""
}

# ------------------------------------------------------------------------------
# Help Function
# ------------------------------------------------------------------------------
show_help() {
    cat << 'EOF'
Raspberry Pi 4 Kernel and Driver Build Script

Usage: ./00-build-all.sh [OPTIONS]

Required:
  --image <path>       Path to Raspberry Pi OS image file

Kernel Options:
  --branch <name>      Kernel branch (default: rpi-6.12.y)
                       Examples: rpi-6.1.y, rpi-6.6.y, rpi-6.12.y
  --config <config>    Kernel configuration:
                       - 'defconfig' : Use default bcm2711_defconfig
                       - <path>      : Path to custom config file
  --fresh              Remove existing kernel source and re-clone

Driver Options:
  --drivers <path>     Path to driver packages directory
                       Must contain hh983-serializer/ and himax-touch/ subdirs

Build Options:
  --build-dir <path>   Build directory (default: $HOME/rpi-kernel-build)
  --output <path>      Output directory for modules and overlays
  --clean              Clean build directories before building

Skip Options:
  --skip-kernel        Skip kernel download and build (steps 02-03)
  --skip-drivers       Skip driver build (step 04)

Install Options:
  --backup             Backup original kernel before installing

Other:
  --dry-run            Show what would be done without executing
  --help               Show this help message

Examples:
  # Full build with custom paths
  ./00-build-all.sh \
      --branch rpi-6.12.y \
      --config /path/to/config-file \
      --drivers /path/to/br-wrapper/package \
      --image /path/to/raspios.img \
      --backup

  # Rebuild drivers only (kernel already built)
  ./00-build-all.sh --skip-kernel --drivers /path/to/drivers --image /path/to/image.img

  # Quick rebuild with defaults
  ./00-build-all.sh --image /path/to/raspios.img

Usage modes:
  1. Normal user (recommended for interactive use):
     ./00-build-all.sh --image /path/to/image.img
     (Will prompt for sudo password at install step)

  2. With sudo (recommended for unattended builds):
     sudo ./00-build-all.sh --image /path/to/image.img
     (Drops privileges for build steps, runs install as root)

Note: Running as root directly (not via sudo) is not supported.
EOF
}

# ------------------------------------------------------------------------------
# Parse Arguments
# ------------------------------------------------------------------------------
ARG_IMAGE=""
ARG_BRANCH=""
ARG_CONFIG=""
ARG_DRIVERS=""
ARG_BUILD_DIR=""
ARG_OUTPUT=""
ARG_CLEAN=0
ARG_FRESH=0
ARG_SKIP_KERNEL=0
ARG_SKIP_DRIVERS=0
ARG_BACKUP=0
ARG_DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --image)
            ARG_IMAGE="$2"
            shift 2
            ;;
        --image=*)
            ARG_IMAGE="${1#*=}"
            shift
            ;;
        --branch)
            ARG_BRANCH="$2"
            shift 2
            ;;
        --branch=*)
            ARG_BRANCH="${1#*=}"
            shift
            ;;
        --config)
            ARG_CONFIG="$2"
            shift 2
            ;;
        --config=*)
            ARG_CONFIG="${1#*=}"
            shift
            ;;
        --drivers)
            ARG_DRIVERS="$2"
            shift 2
            ;;
        --drivers=*)
            ARG_DRIVERS="${1#*=}"
            shift
            ;;
        --build-dir)
            ARG_BUILD_DIR="$2"
            shift 2
            ;;
        --build-dir=*)
            ARG_BUILD_DIR="${1#*=}"
            shift
            ;;
        --output)
            ARG_OUTPUT="$2"
            shift 2
            ;;
        --output=*)
            ARG_OUTPUT="${1#*=}"
            shift
            ;;
        --clean)
            ARG_CLEAN=1
            shift
            ;;
        --fresh)
            ARG_FRESH=1
            shift
            ;;
        --skip-kernel)
            ARG_SKIP_KERNEL=1
            shift
            ;;
        --skip-drivers)
            ARG_SKIP_DRIVERS=1
            shift
            ;;
        --backup)
            ARG_BACKUP=1
            shift
            ;;
        --dry-run)
            ARG_DRY_RUN=1
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Validate Arguments and Detect Sudo
# ------------------------------------------------------------------------------

# Detect if running as root/sudo and set up user context
if [[ $EUID -eq 0 ]]; then
    # Running as root - check if via sudo
    if [[ -n "$SUDO_USER" ]]; then
        REAL_USER="$SUDO_USER"
        REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        RUN_MODE="sudo"
        log_info "Running as root via sudo (original user: $REAL_USER)"
    else
        log_error "Running as root directly is not supported"
        log_error "Please run with: sudo ./00-build-all.sh [OPTIONS]"
        log_error "Or run as normal user (will prompt for sudo at install step)"
        exit 1
    fi
else
    # Running as normal user
    REAL_USER="$USER"
    REAL_HOME="$HOME"
    RUN_MODE="user"
fi

# Helper function to run commands as the original user (for build steps)
run_as_user() {
    if [[ "$RUN_MODE" == "sudo" ]]; then
        # Running as root via sudo - drop privileges for build steps
        sudo -u "$REAL_USER" -H "$@"
    else
        # Running as normal user - execute directly
        "$@"
    fi
}

# Image is required
if [[ -z "$ARG_IMAGE" ]]; then
    log_error "Missing required argument: --image <path>"
    echo "Use --help for usage information"
    exit 1
fi

# Validate image exists
if [[ ! -f "$ARG_IMAGE" ]]; then
    log_error "Image file not found: $ARG_IMAGE"
    exit 1
fi

# Validate config file if specified (and not "defconfig")
if [[ -n "$ARG_CONFIG" ]] && [[ "$ARG_CONFIG" != "defconfig" ]]; then
    if [[ ! -f "$ARG_CONFIG" ]]; then
        log_error "Config file not found: $ARG_CONFIG"
        exit 1
    fi
fi

# Validate drivers directory if specified
if [[ -n "$ARG_DRIVERS" ]]; then
    if [[ ! -d "$ARG_DRIVERS" ]]; then
        log_error "Drivers directory not found: $ARG_DRIVERS"
        exit 1
    fi
    if [[ ! -d "$ARG_DRIVERS/hh983-serializer" ]]; then
        log_error "hh983-serializer not found in: $ARG_DRIVERS"
        exit 1
    fi
    if [[ ! -d "$ARG_DRIVERS/himax-touch" ]]; then
        log_error "himax-touch not found in: $ARG_DRIVERS"
        exit 1
    fi
fi

# Set defaults (use REAL_HOME to handle sudo case correctly)
BUILD_DIR="${ARG_BUILD_DIR:-$REAL_HOME/rpi-kernel-build}"
OUTPUT_DIR="${ARG_OUTPUT:-$BUILD_DIR/output}"
KERNEL_SRC="$BUILD_DIR/linux"

# ------------------------------------------------------------------------------
# Display Build Plan
# ------------------------------------------------------------------------------
echo "=============================================================================="
echo " Raspberry Pi 4 Kernel and Driver Build"
echo "=============================================================================="
echo ""
echo " Build Configuration:"
echo "   Build directory : $BUILD_DIR"
echo "   Output directory: $OUTPUT_DIR"
echo "   Target image    : $ARG_IMAGE"
if [[ "$RUN_MODE" == "sudo" ]]; then
    echo "   Run mode        : sudo (build as $REAL_USER, install as root)"
else
    echo "   Run mode        : user (will prompt for sudo at install)"
fi
echo ""
if [[ $ARG_SKIP_KERNEL -eq 0 ]]; then
    echo " Kernel Configuration:"
    echo "   Branch          : ${ARG_BRANCH:-<default from config.env>}"
    echo "   Config          : ${ARG_CONFIG:-<default from config.env>}"
    echo "   Fresh clone     : $([ $ARG_FRESH -eq 1 ] && echo 'Yes' || echo 'No')"
else
    echo " Kernel: SKIPPED (--skip-kernel)"
fi
echo ""
if [[ $ARG_SKIP_DRIVERS -eq 0 ]]; then
    echo " Driver Configuration:"
    echo "   Drivers path    : ${ARG_DRIVERS:-<default from config.env>}"
else
    echo " Drivers: SKIPPED (--skip-drivers)"
fi
echo ""
echo " Options:"
echo "   Clean build     : $([ $ARG_CLEAN -eq 1 ] && echo 'Yes' || echo 'No')"
echo "   Backup kernel   : $([ $ARG_BACKUP -eq 1 ] && echo 'Yes' || echo 'No')"
echo "   Dry run         : $([ $ARG_DRY_RUN -eq 1 ] && echo 'Yes' || echo 'No')"
echo ""
echo "=============================================================================="

if [[ $ARG_DRY_RUN -eq 1 ]]; then
    echo ""
    log_warn "DRY RUN MODE - Commands will be shown but not executed"
    echo ""
fi

# ------------------------------------------------------------------------------
# Step 02: Download and Configure Kernel
# ------------------------------------------------------------------------------
if [[ $ARG_SKIP_KERNEL -eq 0 ]]; then
    log_step "Step 1/4: Downloading and configuring kernel..."

    # Build command arguments
    CMD_ARGS=()
    [[ $ARG_FRESH -eq 1 ]] && CMD_ARGS+=("--fresh")
    [[ -n "$ARG_BRANCH" ]] && CMD_ARGS+=("--branch" "$ARG_BRANCH")
    [[ -n "$ARG_CONFIG" ]] && CMD_ARGS+=("--config" "$ARG_CONFIG")

    # Export BUILD_BASE for sub-script
    export BUILD_BASE="$BUILD_DIR"

    if [[ $ARG_DRY_RUN -eq 1 ]]; then
        echo "  [DRY-RUN] $SCRIPT_DIR/02-download-kernel.sh ${CMD_ARGS[*]}"
    else
        run_as_user env BUILD_BASE="$BUILD_DIR" "$SCRIPT_DIR/02-download-kernel.sh" "${CMD_ARGS[@]}"
    fi

    if [[ $ARG_DRY_RUN -eq 0 ]]; then
        log_success "Kernel downloaded and configured"
    fi
else
    log_step "Step 1/4: Skipping kernel download (--skip-kernel)"

    # Verify kernel exists if skipping
    if [[ ! -d "$KERNEL_SRC" ]] || [[ ! -f "$KERNEL_SRC/.config" ]]; then
        log_error "Kernel source not found or not configured at: $KERNEL_SRC"
        log_error "Cannot use --skip-kernel without existing kernel"
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# Step 03: Build Kernel
# ------------------------------------------------------------------------------
if [[ $ARG_SKIP_KERNEL -eq 0 ]]; then
    log_step "Step 2/4: Building kernel..."

    CMD_ARGS=()
    [[ $ARG_CLEAN -eq 1 ]] && CMD_ARGS+=("--clean")

    export BUILD_BASE="$BUILD_DIR"

    if [[ $ARG_DRY_RUN -eq 1 ]]; then
        echo "  [DRY-RUN] $SCRIPT_DIR/03-build-kernel.sh ${CMD_ARGS[*]}"
    else
        run_as_user env BUILD_BASE="$BUILD_DIR" "$SCRIPT_DIR/03-build-kernel.sh" "${CMD_ARGS[@]}"
    fi

    if [[ $ARG_DRY_RUN -eq 0 ]]; then
        log_success "Kernel built successfully"
    fi
else
    log_step "Step 2/4: Skipping kernel build (--skip-kernel)"

    # Verify kernel was built
    if [[ ! -f "$KERNEL_SRC/Module.symvers" ]]; then
        log_error "Kernel not built (Module.symvers missing)"
        log_error "Cannot use --skip-kernel without built kernel"
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# Step 04: Build Drivers
# ------------------------------------------------------------------------------
if [[ $ARG_SKIP_DRIVERS -eq 0 ]]; then
    log_step "Step 3/4: Building custom drivers..."

    CMD_ARGS=()
    [[ $ARG_CLEAN -eq 1 ]] && CMD_ARGS+=("--clean")
    CMD_ARGS+=("--kernel" "$KERNEL_SRC")
    [[ -n "$ARG_DRIVERS" ]] && CMD_ARGS+=("--drivers" "$ARG_DRIVERS")
    CMD_ARGS+=("--output" "$OUTPUT_DIR")

    export BUILD_BASE="$BUILD_DIR"

    if [[ $ARG_DRY_RUN -eq 1 ]]; then
        echo "  [DRY-RUN] $SCRIPT_DIR/04-build-drivers.sh ${CMD_ARGS[*]}"
    else
        run_as_user env BUILD_BASE="$BUILD_DIR" "$SCRIPT_DIR/04-build-drivers.sh" "${CMD_ARGS[@]}"
    fi

    if [[ $ARG_DRY_RUN -eq 0 ]]; then
        log_success "Drivers built successfully"
    fi
else
    log_step "Step 3/4: Skipping driver build (--skip-drivers)"
fi

# ------------------------------------------------------------------------------
# Step 05: Install to Image (requires root)
# ------------------------------------------------------------------------------
log_step "Step 4/4: Installing to image..."

CMD_ARGS=()
CMD_ARGS+=("--image" "$ARG_IMAGE")
[[ $ARG_BACKUP -eq 1 ]] && CMD_ARGS+=("--backup")
[[ $ARG_SKIP_KERNEL -eq 1 ]] && CMD_ARGS+=("--modules-only")

export BUILD_BASE="$BUILD_DIR"

if [[ $ARG_DRY_RUN -eq 1 ]]; then
    if [[ "$RUN_MODE" == "sudo" ]]; then
        echo "  [DRY-RUN] $SCRIPT_DIR/05-install-to-image.sh ${CMD_ARGS[*]}"
    else
        echo "  [DRY-RUN] sudo $SCRIPT_DIR/05-install-to-image.sh ${CMD_ARGS[*]}"
    fi
else
    if [[ "$RUN_MODE" == "sudo" ]]; then
        # Already running as root - execute directly
        "$SCRIPT_DIR/05-install-to-image.sh" "${CMD_ARGS[@]}"
    else
        # Running as normal user - need sudo
        sudo BUILD_BASE="$BUILD_DIR" "$SCRIPT_DIR/05-install-to-image.sh" "${CMD_ARGS[@]}"
    fi
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "=============================================================================="
if [[ $ARG_DRY_RUN -eq 1 ]]; then
    echo " DRY RUN COMPLETE"
    echo ""
    echo " No changes were made. Remove --dry-run to execute."
else
    echo " BUILD COMPLETE!"
    echo ""
    echo " The following have been installed to: $ARG_IMAGE"
    if [[ $ARG_SKIP_KERNEL -eq 0 ]]; then
        echo "   - Kernel Image"
        echo "   - Device tree blobs and overlays"
        echo "   - In-tree kernel modules"
    fi
    if [[ $ARG_SKIP_DRIVERS -eq 0 ]]; then
        echo "   - hh983-serializer.ko"
        echo "   - himax_mmi.ko"
        echo "   - Custom device tree overlays"
    fi
    echo ""
    echo " You can now write the image to an SD card:"
    echo "   sudo dd if=$ARG_IMAGE of=/dev/sdX bs=8M status=progress"
fi
echo "=============================================================================="
