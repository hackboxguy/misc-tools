#!/bin/bash
# ==============================================================================
# Script 5: Install Kernel and Drivers to Raspberry Pi Image
# ==============================================================================
# This script mounts a Raspberry Pi OS image and installs:
#   - Cross-compiled kernel Image
#   - Device tree blobs and overlays
#   - Kernel modules (in-tree and custom)
#   - Driver configuration files
#
# NO QEMU or sdm required - uses direct loop mount.
#
# Usage: sudo ./05-install-to-image.sh [--image <path>] [--backup] [--modules-only]
#   --image <path>  : Path to Raspberry Pi image (default from config.env)
#   --backup        : Create backup of original kernel before overwriting
#   --modules-only  : Only install modules, skip kernel Image and DTBs
#   --skip-intree   : Skip in-tree modules, only install custom drivers
# ==============================================================================

set -e

# Source configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# When running as root via sudo, fix HOME to be the original user's home
if [[ -n "$SUDO_USER" ]]; then
    export HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
fi

source "$SCRIPT_DIR/config.env"

# Must run as root
check_root

# ------------------------------------------------------------------------------
# Parse Arguments
# ------------------------------------------------------------------------------
CREATE_BACKUP=0
MODULES_ONLY=0
SKIP_INTREE=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --image)
            RPI_IMAGE="$2"
            shift 2
            ;;
        --backup)
            CREATE_BACKUP=1
            shift
            ;;
        --modules-only)
            MODULES_ONLY=1
            shift
            ;;
        --skip-intree)
            SKIP_INTREE=1
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Usage: sudo $0 [--image <path>] [--backup] [--modules-only] [--skip-intree]"
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Verify Prerequisites
# ------------------------------------------------------------------------------
log_info "Verifying prerequisites..."

if [[ ! -f "$RPI_IMAGE" ]]; then
    log_error "Raspberry Pi image not found: $RPI_IMAGE"
    log_error "Set RPI_IMAGE environment variable or use --image flag"
    exit 1
fi

if [[ ! -d "$KERNEL_SRC" ]]; then
    log_error "Kernel source not found: $KERNEL_SRC"
    exit 1
fi

if [[ ! -d "$BUILD_OUTPUT/modules" ]]; then
    log_error "Built modules not found. Run ./04-build-drivers.sh first"
    exit 1
fi

# Get kernel release
KRELEASE=$(cat "$BUILD_OUTPUT/kernel-release.txt" 2>/dev/null || make -C "$KERNEL_SRC" -s kernelrelease)

# Check if version might have '+' suffix issue
# If CONFIG_LOCALVERSION_AUTO was enabled during build, the running kernel will have '+' suffix
# Detect this by checking the installed kernel Image
KRELEASE_PLUS="${KRELEASE}+"

echo "=============================================================================="
echo " Install to Raspberry Pi Image"
echo "=============================================================================="
echo ""
echo " Image: $RPI_IMAGE"
echo " Kernel release: $KRELEASE"
echo " Mount points: $MNT_BOOT, $MNT_ROOT"
echo ""

# ------------------------------------------------------------------------------
# Setup Cleanup Trap
# ------------------------------------------------------------------------------
cleanup() {
    log_info "Cleaning up..."

    # Sync before unmounting
    sync 2>/dev/null || true

    # Unmount partitions
    umount "$MNT_BOOT" 2>/dev/null || true
    umount "$MNT_ROOT" 2>/dev/null || true

    # Detach loop device
    if [[ -n "$LOOP_DEV" ]]; then
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi

    log_info "Cleanup complete"
}

trap cleanup EXIT

# ------------------------------------------------------------------------------
# Mount Image
# ------------------------------------------------------------------------------
log_info "Setting up loop device for image..."

# Create a loop device with partition scanning
LOOP_DEV=$(losetup -fP --show "$RPI_IMAGE")
log_info "Loop device: $LOOP_DEV"

# Wait for partition devices to appear
sleep 1

# Identify partitions
# Standard Raspberry Pi OS layout:
#   - p1: boot partition (FAT32) - /boot/firmware
#   - p2: root partition (ext4) - /
BOOT_PART="${LOOP_DEV}p1"
ROOT_PART="${LOOP_DEV}p2"

if [[ ! -b "$BOOT_PART" ]] || [[ ! -b "$ROOT_PART" ]]; then
    log_error "Expected partitions not found: $BOOT_PART, $ROOT_PART"
    log_info "Available partitions:"
    ls -la "${LOOP_DEV}"* 2>/dev/null || true
    exit 1
fi

# Create mount points
mkdir -p "$MNT_BOOT" "$MNT_ROOT"

# Mount partitions
log_info "Mounting boot partition ($BOOT_PART) to $MNT_BOOT..."
mount "$BOOT_PART" "$MNT_BOOT"

log_info "Mounting root partition ($ROOT_PART) to $MNT_ROOT..."
mount "$ROOT_PART" "$MNT_ROOT"

log_success "Image mounted successfully!"

# Verify mount
log_info "Boot partition contents:"
ls "$MNT_BOOT" | head -10

# ------------------------------------------------------------------------------
# Backup Original Kernel (Optional)
# ------------------------------------------------------------------------------
if [[ $CREATE_BACKUP -eq 1 ]] && [[ $MODULES_ONLY -eq 0 ]]; then
    log_info "Creating backup of original kernel..."

    BACKUP_DIR="$MNT_BOOT/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"

    # Backup kernel image
    # Check for Image or kernel8.img
    if [[ -f "$MNT_BOOT/Image" ]]; then
        cp "$MNT_BOOT/Image" "$BACKUP_DIR/"
    fi
    if [[ -f "$MNT_BOOT/kernel8.img" ]]; then
        cp "$MNT_BOOT/kernel8.img" "$BACKUP_DIR/"
    fi

    log_success "Backup created: $BACKUP_DIR"
fi

# ------------------------------------------------------------------------------
# Install Kernel Image and DTBs
# ------------------------------------------------------------------------------
if [[ $MODULES_ONLY -eq 0 ]]; then
    echo ""
    log_info "Installing kernel Image..."

    # The config.txt shows: kernel=Image
    # So we install as "Image" not "kernel8.img"
    cp "$KERNEL_SRC/arch/arm64/boot/Image" "$MNT_BOOT/Image"
    log_success "Kernel Image installed"

    echo ""
    log_info "Installing device tree blobs..."

    # Copy Broadcom DTBs (for Pi 4: bcm2711-rpi-4-b.dtb, etc.)
    cp "$KERNEL_SRC/arch/arm64/boot/dts/broadcom/"*.dtb "$MNT_BOOT/"
    DTB_COUNT=$(ls "$KERNEL_SRC/arch/arm64/boot/dts/broadcom/"*.dtb 2>/dev/null | wc -l)
    log_success "Installed $DTB_COUNT device tree blobs"

    echo ""
    log_info "Installing device tree overlays..."

    # Create overlays directory if it doesn't exist
    mkdir -p "$MNT_BOOT/overlays"

    # Copy all overlays
    cp "$KERNEL_SRC/arch/arm64/boot/dts/overlays/"*.dtb* "$MNT_BOOT/overlays/" 2>/dev/null || true

    # Copy README
    if [[ -f "$KERNEL_SRC/arch/arm64/boot/dts/overlays/README" ]]; then
        cp "$KERNEL_SRC/arch/arm64/boot/dts/overlays/README" "$MNT_BOOT/overlays/"
    fi

    OVERLAY_COUNT=$(ls "$MNT_BOOT/overlays/"*.dtbo 2>/dev/null | wc -l)
    log_success "Installed $OVERLAY_COUNT device tree overlays"
fi

# ------------------------------------------------------------------------------
# Install Kernel Modules (In-Tree)
# ------------------------------------------------------------------------------
if [[ $SKIP_INTREE -eq 0 ]]; then
    echo ""
    log_info "Installing in-tree kernel modules..."

    # Use make modules_install with INSTALL_MOD_PATH pointing to rootfs
    export ARCH=arm64
    export CROSS_COMPILE=aarch64-linux-gnu-

    make -C "$KERNEL_SRC" INSTALL_MOD_PATH="$MNT_ROOT" modules_install

    log_success "In-tree modules installed to $MNT_ROOT/lib/modules/$KRELEASE"
fi

# ------------------------------------------------------------------------------
# Install Custom Driver Modules
# ------------------------------------------------------------------------------
echo ""
log_info "Installing custom driver modules..."

# Create extra modules directory
EXTRA_MOD_DIR="$MNT_ROOT/lib/modules/$KRELEASE/extra"
mkdir -p "$EXTRA_MOD_DIR"

# Install hh983-serializer
if [[ -f "$BUILD_OUTPUT/modules/hh983-serializer.ko" ]]; then
    cp "$BUILD_OUTPUT/modules/hh983-serializer.ko" "$EXTRA_MOD_DIR/"
    log_success "Installed hh983-serializer.ko"
else
    log_warn "hh983-serializer.ko not found in $BUILD_OUTPUT/modules/"
fi

# Install himax_mmi
if [[ -f "$BUILD_OUTPUT/modules/himax_mmi.ko" ]]; then
    cp "$BUILD_OUTPUT/modules/himax_mmi.ko" "$EXTRA_MOD_DIR/"
    log_success "Installed himax_mmi.ko"
else
    log_warn "himax_mmi.ko not found in $BUILD_OUTPUT/modules/"
fi

# ------------------------------------------------------------------------------
# Install Custom Overlays
# ------------------------------------------------------------------------------
echo ""
log_info "Installing custom device tree overlays..."

mkdir -p "$MNT_BOOT/overlays"

if [[ -f "$BUILD_OUTPUT/overlays/hh983-serializer.dtbo" ]]; then
    cp "$BUILD_OUTPUT/overlays/hh983-serializer.dtbo" "$MNT_BOOT/overlays/"
    log_success "Installed hh983-serializer.dtbo"
fi

if [[ -f "$BUILD_OUTPUT/overlays/himax-touch.dtbo" ]]; then
    cp "$BUILD_OUTPUT/overlays/himax-touch.dtbo" "$MNT_BOOT/overlays/"
    log_success "Installed himax-touch.dtbo"
fi

# ------------------------------------------------------------------------------
# Run depmod (Cross-Platform)
# ------------------------------------------------------------------------------
echo ""
log_info "Running depmod for module dependencies..."

# depmod can run on x86_64 for arm64 modules using -b flag
depmod -a -b "$MNT_ROOT" "$KRELEASE"

log_success "Module dependencies generated"

# ------------------------------------------------------------------------------
# Handle Version Mismatch (LOCALVERSION_AUTO fallback)
# ------------------------------------------------------------------------------
# If CONFIG_LOCALVERSION_AUTO was enabled during build but not disabled,
# the running kernel will report version with '+' suffix (e.g., 6.12.59-v8+)
# but modules are installed to version without '+' (e.g., 6.12.59-v8).
# Create a symlink to ensure modules are found regardless.
echo ""
log_info "Creating version fallback symlink (in case of LOCALVERSION_AUTO)..."

if [[ ! -d "$MNT_ROOT/lib/modules/$KRELEASE_PLUS" ]]; then
    # Create symlink from version+ -> version
    ln -sf "$KRELEASE" "$MNT_ROOT/lib/modules/$KRELEASE_PLUS"
    log_success "Created symlink: $KRELEASE_PLUS -> $KRELEASE"
else
    log_info "Directory $KRELEASE_PLUS already exists, skipping symlink"
fi

# ------------------------------------------------------------------------------
# Install Driver Configuration Files
# ------------------------------------------------------------------------------
echo ""
log_info "Installing driver configuration files..."

# Create modprobe.d directory
mkdir -p "$MNT_ROOT/etc/modprobe.d"

# hh983-serializer config
cat > "$MNT_ROOT/etc/modprobe.d/hh983.conf" << 'EOF'
# HH983 FPDLink Serializer configuration
# config_mode=1 for 983+988 pair (default for himax touch)
options hh983-serializer config_mode=1

# Ensure hh983-serializer loads and initializes before himax_mmi
# This is critical - himax needs FPDLink passthrough to be active first
softdep himax_mmi pre: hh983-serializer
EOF
log_success "Created /etc/modprobe.d/hh983.conf"

# Module load order configuration
mkdir -p "$MNT_ROOT/etc/modules-load.d"
cat > "$MNT_ROOT/etc/modules-load.d/custom-drivers.conf" << 'EOF'
# Custom driver load order
# hh983-serializer must load before himax touch
hh983-serializer
himax_mmi
EOF
log_success "Created /etc/modules-load.d/custom-drivers.conf"

# ------------------------------------------------------------------------------
# Sync and Verify
# ------------------------------------------------------------------------------
echo ""
log_info "Syncing filesystem..."
sync

# Verify installation
echo ""
log_info "Verifying installation..."

echo "Boot partition:"
ls -lh "$MNT_BOOT/Image" 2>/dev/null || ls -lh "$MNT_BOOT/kernel8.img" 2>/dev/null || true
ls -lh "$MNT_BOOT/overlays/hh983-serializer.dtbo" 2>/dev/null || true
ls -lh "$MNT_BOOT/overlays/himax-touch.dtbo" 2>/dev/null || true

echo ""
echo "Root partition - modules:"
ls -lh "$MNT_ROOT/lib/modules/$KRELEASE/extra/"*.ko 2>/dev/null || true

echo ""
echo "Root partition - config:"
ls -lh "$MNT_ROOT/etc/modprobe.d/hh983.conf" 2>/dev/null || true
ls -lh "$MNT_ROOT/etc/modules-load.d/custom-drivers.conf" 2>/dev/null || true

# ------------------------------------------------------------------------------
# Unmount (handled by cleanup trap)
# ------------------------------------------------------------------------------
echo ""
log_info "Unmounting image..."

# The cleanup trap will handle unmounting

echo ""
echo "=============================================================================="
echo " Installation Complete!"
echo "=============================================================================="
echo ""
echo " Installed to: $RPI_IMAGE"
echo ""
echo " Installed components:"
if [[ $MODULES_ONLY -eq 0 ]]; then
echo "   - Kernel Image"
echo "   - Device tree blobs"
echo "   - Device tree overlays (in-tree)"
fi
if [[ $SKIP_INTREE -eq 0 ]]; then
echo "   - Kernel modules (in-tree)"
fi
echo "   - Custom modules: hh983-serializer.ko, himax_mmi.ko"
echo "   - Custom overlays: hh983-serializer.dtbo, himax-touch.dtbo"
echo "   - Config: /etc/modprobe.d/hh983.conf"
echo "   - Config: /etc/modules-load.d/custom-drivers.conf"
echo ""
echo " Kernel release: $KRELEASE"
echo ""
echo " The image is ready to be written to an SD card:"
echo "   sudo dd if=$RPI_IMAGE of=/dev/sdX bs=8M status=progress"
echo ""
echo "=============================================================================="
