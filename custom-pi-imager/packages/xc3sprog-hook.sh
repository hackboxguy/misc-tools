#!/bin/bash
set -e

echo "======================================"
echo "  xc3sprog Setup Hook"
echo "======================================"
echo ""

# Environment variables available:
# - MOUNT_POINT: Root filesystem mount point
# - PI_PASSWORD: User password (empty if unchanged)
# - IMAGE_WORK_DIR: Working directory path

echo "Running inside chroot environment"
echo "Building xc3sprog from source..."
echo ""

# Install build dependencies (no-op if already installed)
echo "[1/5] Installing build dependencies..."
apt-get update -qq
apt-get install -y cmake g++ make git libusb-dev libftdi-dev libgpiod-dev

# Clone micropanel repository
echo "[2/5] Cloning micropanel from GitHub..."
cd /tmp
git clone https://github.com/hackboxguy/xc3sprog.git
cd xc3sprog

# Create build directory and configure micropanel
echo "[3/5] Configuring CMake..."
mkdir -p build && cd build
cmake -DCMAKE_INSTALL_PREFIX=/home/pi/micropanel/fpga \
      -DCMAKE_BUILD_TYPE=Release \
      .. > /dev/null

# Build xc3sprog
echo "[4/5] Building xc3sprog (this may take a few minutes)..."
make -j$(nproc) > /dev/null 2>&1

# Install micropanel
echo "[5/5] Installing xc3sprog to /home/pi/micropanel/fpga..."
make install > /dev/null

# Set correct ownership (pi user is uid:gid 1000:1000)
chown -R 1000:1000 /home/pi/micropanel/fpga

######finalize the xc3sprog installation######
echo ""
echo "Finalizing xc3sprog installation..."


# Cleanup build artifacts and source
echo "Cleaning up build artifacts..."
cd /
rm -rf /tmp/xc3sprog

# NOTE: Build dependencies will be purged by main script
# No apt-get purge here!

echo ""
echo "======================================"
echo "  xc3sprog Setup Complete"
echo "======================================"
echo "Installation path: /home/pi/micropanel/fpga"
echo "Binaries:"
echo "  - xc3sprog (main binary)"
echo ""
echo "Note: Build deps purged by main script"
echo "======================================"
