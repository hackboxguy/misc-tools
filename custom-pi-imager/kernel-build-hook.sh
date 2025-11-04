#!/bin/bash
set -e

echo "======================================"
echo "  Raspberry Pi Kernel Build Hook"
echo "======================================"
echo ""

KERNEL_BRANCH="rpi-6.6.y"
KERNEL_SRC="/usr/src/rpi-linux"
KERNEL_VERSION=""

echo "Running inside ARM64 chroot via QEMU"
echo "Host: x86_64 with QEMU user-mode emulation"
echo "Target: Raspberry Pi 4 (BCM2711)"
echo "Branch: ${KERNEL_BRANCH}"
echo ""
echo "⚠️  This will take 30-90 minutes depending on host CPU..."
echo ""

# [1/11] Clone kernel source
echo "[1/11] Cloning Raspberry Pi kernel source..."
cd /usr/src
if [ -d "${KERNEL_SRC}/.git" ]; then
    echo "✓ Kernel source already exists at ${KERNEL_SRC}"
    echo "Skipping clone (idempotent mode)"
    cd ${KERNEL_SRC}
else
    echo "Cloning from https://github.com/raspberrypi/linux.git"
    echo "Using shallow clone (--depth=1) to save time and space..."
    git clone --depth=1 --branch=${KERNEL_BRANCH} \
        https://github.com/raspberrypi/linux.git rpi-linux
    cd ${KERNEL_SRC}
fi

echo "Kernel source ready: ${KERNEL_SRC}"
echo ""

# [2/11] Configure kernel
echo "[2/11] Configuring kernel (bcm2711_defconfig for Pi 4)..."
make bcm2711_defconfig

# [3/11] Customize configuration
echo "[3/11] Applying custom kernel configuration..."
echo "  - Enabling I2C support (CONFIG_I2C, CONFIG_I2C_CHARDEV)"
scripts/config --enable CONFIG_I2C
scripts/config --enable CONFIG_I2C_CHARDEV

echo "  - Enabling SPI support (CONFIG_SPI)"
scripts/config --enable CONFIG_SPI

echo "  - Disabling debug info (saves space and compilation time)"
scripts/config --disable CONFIG_DEBUG_INFO

# Optional: Enable additional features
# Uncomment as needed for your use case
# echo "  - Enabling CAN bus support"
# scripts/config --enable CONFIG_CAN
# scripts/config --enable CONFIG_CAN_RAW
# scripts/config --module CONFIG_CAN_BCM

# Apply configuration changes
make olddefconfig

echo "Configuration applied successfully"
echo ""

# [4/11] Extract kernel version
KERNEL_VERSION=$(make kernelrelease)
echo "[4/11] Kernel version: ${KERNEL_VERSION}"
echo ""

# [5/11] Build kernel image
echo "[5/11] Building kernel image (Image.gz)..."

if [ -f arch/arm64/boot/Image.gz ]; then
    echo "✓ Kernel image already exists: arch/arm64/boot/Image.gz"
    echo "Skipping compilation (idempotent mode)"
    echo ""
else
    echo "This is the longest step - expect 20-60 minutes..."
    echo "Compiling with $(nproc) parallel jobs..."
    echo ""

    # Build with progress indication (no log file to save space)
    make -j$(nproc) Image.gz 2>&1 | grep -E "(CC|LD|AS)" | tail -20 || true

    if [ ! -f arch/arm64/boot/Image.gz ]; then
        echo "ERROR: Kernel image build failed!"
        exit 1
    fi

    echo ""
    echo "✓ Kernel image built successfully: arch/arm64/boot/Image.gz"
    echo ""
fi

# [6/11] Build device tree blobs
echo "[6/11] Building device tree blobs (DTBs)..."

if [ -f arch/arm64/boot/dts/broadcom/bcm2711-rpi-4-b.dtb ]; then
    echo "✓ Device tree blobs already exist"
    echo "Skipping DTB compilation (idempotent mode)"
    echo ""
else
    make -j$(nproc) dtbs

    if [ ! -f arch/arm64/boot/dts/broadcom/bcm2711-rpi-4-b.dtb ]; then
        echo "ERROR: Device tree build failed!"
        exit 1
    fi

    echo "✓ Device tree blobs built successfully"
    echo ""
fi

# [7/11] Build kernel modules
echo "[7/11] Building kernel modules..."

# Check if modules are already built AND modules.order exists
if [ -f modules.order ] && ([ -f .modules_built_marker ] || find . -name "*.ko" -print -quit | grep -q .); then
    echo "✓ Kernel modules already built (modules.order exists)"
    echo "Skipping module compilation (idempotent mode)"
    echo ""
else
    echo "This may take 10-30 minutes..."
    echo ""

    # Build modules and capture output (don't suppress errors)
    if ! make -j$(nproc) modules; then
        echo "ERROR: Module compilation failed!"
        echo "Check the build output above for details"
        exit 1
    fi

    # Verify critical files exist
    if [ ! -f modules.order ]; then
        echo "ERROR: modules.order not created after build!"
        exit 1
    fi

    # Create marker file
    touch .modules_built_marker

    echo ""
    echo "✓ Kernel modules built successfully"
    echo ""
fi

# [8/11] Install kernel image
echo "[8/11] Installing kernel image to /boot/firmware/kernel8.img..."

# Backup existing kernel (if exists)
if [ -f /boot/firmware/kernel8.img ]; then
    echo "Backing up existing kernel to kernel8.img.backup"
    cp -v /boot/firmware/kernel8.img /boot/firmware/kernel8.img.backup
fi

# Install new kernel
cp -v arch/arm64/boot/Image.gz /boot/firmware/kernel8.img

echo "✓ Kernel installed: /boot/firmware/kernel8.img"
echo ""

# [9/11] Install device tree blobs
echo "[9/11] Installing device tree blobs..."

# Install main DTB
cp -v arch/arm64/boot/dts/broadcom/bcm2711-rpi-4-b.dtb /boot/firmware/

# Install overlays (ignore errors if some don't exist)
echo "Installing device tree overlays..."
cp -v arch/arm64/boot/dts/overlays/*.dtbo /boot/firmware/overlays/ 2>/dev/null || echo "Note: Some overlays may not exist, continuing..."

echo "✓ Device tree blobs installed"
echo ""

# [10/11] Install kernel modules
echo "[10/11] Installing kernel modules to /lib/modules/${KERNEL_VERSION}..."
make modules_install

if [ ! -d /lib/modules/${KERNEL_VERSION} ]; then
    echo "ERROR: Module installation failed!"
    exit 1
fi

# Note: make modules_install automatically runs depmod
echo "✓ Kernel modules installed: /lib/modules/${KERNEL_VERSION}"
echo "✓ Module dependencies updated (via make modules_install)"
echo ""

# [11/11] Cleanup
echo "[11/11] Cleaning up build artifacts..."

# Clean build artifacts first
make clean

# Remove kernel source entirely to save ~1.5GB (unless in debug mode)
if [ "$DEBUG_MODE" = "1" ] || [ "$DEBUG_MODE" = "true" ]; then
    echo "⚠️  Debug mode active: Keeping kernel source for inspection"
    echo "Source location: ${KERNEL_SRC}"
    echo "To manually remove later: sudo rm -rf ${KERNEL_SRC}"
else
    echo "Removing kernel source to save space..."
    cd /usr/src && rm -rf rpi-linux
    echo "✓ Build artifacts and source cleaned (saved ~1.5GB)"
fi
echo ""

# Summary
echo "======================================"
echo "  Kernel Build Complete!"
echo "======================================"
echo ""
echo "Summary:"
echo "  Kernel Version:    ${KERNEL_VERSION}"
echo "  Kernel Image:      /boot/firmware/kernel8.img"
echo "  DTB:               /boot/firmware/bcm2711-rpi-4-b.dtb"
echo "  Modules:           /lib/modules/${KERNEL_VERSION}"
echo ""
echo "Configuration:"
echo "  - I2C enabled (CONFIG_I2C, CONFIG_I2C_CHARDEV)"
echo "  - SPI enabled (CONFIG_SPI)"
echo "  - Debug info disabled (smaller size, faster build)"
echo ""
echo "⚠️  Note: Kernel build dependencies (gcc, make, etc.)"
echo "   will be automatically purged by custom-pi-imager.sh"
echo ""
echo "Next Steps:"
echo "  1. Boot Raspberry Pi 4 with this image"
echo "  2. Verify kernel: uname -r"
echo "  3. Check modules: lsmod"
echo "======================================"
