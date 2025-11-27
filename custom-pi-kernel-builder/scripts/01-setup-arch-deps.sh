#!/bin/bash
# ==============================================================================
# Script 1: Setup Arch Linux Dependencies for RPi Kernel Cross-Compilation
# ==============================================================================
# This script installs all required packages on an Arch Linux host machine
# for cross-compiling the Raspberry Pi 4 Linux kernel and out-of-tree modules.
#
# Based on: https://www.raspberrypi.com/documentation/computers/linux_kernel.html
#
# Usage: sudo ./01-setup-arch-deps.sh
# ==============================================================================

set -e

# Source configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"

# Must run as root for pacman
check_root

echo "=============================================================================="
echo " Raspberry Pi Kernel Cross-Compilation - Arch Linux Setup"
echo "=============================================================================="
echo ""

# ------------------------------------------------------------------------------
# Install Cross-Compiler Toolchain
# ------------------------------------------------------------------------------
log_info "Installing AArch64 cross-compiler toolchain..."

# The official RPi guide uses gcc-aarch64-linux-gnu on Debian
# On Arch Linux, the equivalent packages are in the AUR or community repo
CROSS_COMPILE_PKGS=(
    aarch64-linux-gnu-gcc
    aarch64-linux-gnu-binutils
)

# Check if cross-compiler is available in repos
if pacman -Ss aarch64-linux-gnu-gcc &>/dev/null; then
    pacman -S --needed --noconfirm "${CROSS_COMPILE_PKGS[@]}" || true
else
    log_warn "aarch64-linux-gnu-gcc not found in repos."
    log_warn "You may need to install from AUR: aarch64-linux-gnu-gcc"
    log_info "Alternative: Install the 'arm-none-eabi-gcc' and use a different approach"
fi

# ------------------------------------------------------------------------------
# Install Kernel Build Dependencies
# ------------------------------------------------------------------------------
log_info "Installing kernel build dependencies..."

# These match the official Raspberry Pi documentation requirements
# Converted from Debian package names to Arch equivalents
KERNEL_BUILD_PKGS=(
    # Core build tools
    base-devel      # includes make, gcc, etc. (equiv to build-essential)
    bc              # arbitrary precision calculator (used in kernel build)
    bison           # parser generator
    flex            # lexical analyzer
    libelf          # ELF library (equiv to libelf-dev)
    openssl         # SSL library (equiv to libssl-dev)
    pahole          # BTF generation (equiv to dwarves)
    perl            # Perl interpreter

    # Version control
    git             # for cloning kernel source

    # Device tree compiler
    dtc             # device tree compiler

    # Additional useful tools
    ncurses         # for menuconfig (equiv to libncurses5-dev)
    cpio            # for initramfs
    kmod            # for depmod

    # Image manipulation
    parted          # for partition operations
    dosfstools      # for FAT filesystem (boot partition)

    # Optional but useful
    wget
    rsync
)

pacman -S --needed --noconfirm "${KERNEL_BUILD_PKGS[@]}"

# ------------------------------------------------------------------------------
# Verify Cross-Compiler Installation
# ------------------------------------------------------------------------------
log_info "Verifying cross-compiler installation..."

if command -v aarch64-linux-gnu-gcc &>/dev/null; then
    CROSS_GCC_VERSION=$(aarch64-linux-gnu-gcc --version | head -1)
    log_success "Cross-compiler found: $CROSS_GCC_VERSION"
else
    log_error "Cross-compiler not found!"
    log_info ""
    log_info "On Arch Linux, you can install the cross-compiler via AUR:"
    log_info "  yay -S aarch64-linux-gnu-gcc aarch64-linux-gnu-binutils"
    log_info ""
    log_info "Or use the arm-gnu-toolchain from ARM directly:"
    log_info "  https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads"
    log_info ""
    exit 1
fi

# ------------------------------------------------------------------------------
# Verify DTC Installation
# ------------------------------------------------------------------------------
log_info "Verifying device tree compiler..."

if command -v dtc &>/dev/null; then
    DTC_VERSION=$(dtc --version)
    log_success "Device tree compiler found: $DTC_VERSION"
else
    log_error "dtc not found! Install with: pacman -S dtc"
    exit 1
fi

# ------------------------------------------------------------------------------
# Create Build Directories
# ------------------------------------------------------------------------------
log_info "Creating build directories..."

# These will be owned by the regular user, not root
BUILD_USER="${SUDO_USER:-$USER}"
BUILD_USER_HOME=$(getent passwd "$BUILD_USER" | cut -d: -f6)

# Use user's home if BUILD_BASE references $HOME
ACTUAL_BUILD_BASE="${BUILD_BASE/$HOME/$BUILD_USER_HOME}"

mkdir -p "$ACTUAL_BUILD_BASE"
mkdir -p "$ACTUAL_BUILD_BASE/output"
chown -R "$BUILD_USER" "$ACTUAL_BUILD_BASE"

log_success "Build directory created: $ACTUAL_BUILD_BASE"

# ------------------------------------------------------------------------------
# Create Mount Points
# ------------------------------------------------------------------------------
log_info "Creating mount points..."

mkdir -p "$MNT_BOOT" "$MNT_ROOT"

log_success "Mount points created: $MNT_BOOT, $MNT_ROOT"

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "=============================================================================="
echo " Setup Complete!"
echo "=============================================================================="
echo ""
echo " Installed components:"
echo "   - AArch64 cross-compiler toolchain"
echo "   - Kernel build dependencies (bc, bison, flex, etc.)"
echo "   - Device tree compiler (dtc)"
echo "   - Image manipulation tools (parted, kmod)"
echo ""
echo " Build directories:"
echo "   - Build base: $ACTUAL_BUILD_BASE"
echo "   - Output: $ACTUAL_BUILD_BASE/output"
echo ""
echo " Next step: Run ./02-download-kernel.sh (as regular user, NOT root)"
echo ""
echo "=============================================================================="
