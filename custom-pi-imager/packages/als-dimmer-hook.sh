#!/bin/bash
set -e

echo "======================================"
echo "  Als-Dimmer Setup Hook"
echo "======================================"
echo ""

# Environment variables available:
# - MOUNT_POINT: Root filesystem mount point
# - PI_PASSWORD: User password (empty if unchanged)
# - IMAGE_WORK_DIR: Working directory path

echo "Running inside chroot environment"
echo "Building als-dimmer from source..."
echo ""

# Install build dependencies (no-op if already installed)
echo "[1/5] Installing build dependencies..."
apt-get update -qq
apt-get install -y cmake g++ make git libddcutil-dev

# Clone als-dimmer repository
echo "[2/5] Cloning als-dimmer from GitHub..."
cd /tmp
git clone https://github.com/hackboxguy/als-dimmer.git
cd als-dimmer

# Create build directory and configure als-dimmer
echo "[3/5] Configuring CMake..."
mkdir -p build && cd build
cmake -DCMAKE_INSTALL_PREFIX=/home/pi/als-dimmer \
      -DCMAKE_BUILD_TYPE=Release \
      -DCONFIG_FILE="config_fpga_opti4001_dimmer800.json" \
      -DUSE_DDCUTIL=ON \
      -DINSTALL_SYSTEMD_SERVICE=ON \
      .. > /dev/null

# Build als-dimmer
echo "[4/5] Building als-dimmer (this may take a few minutes)..."
make -j$(nproc) > /dev/null 2>&1

# Install als-dimmer
echo "[5/5] Installing als-dimmer to /home/pi/als-dimmer..."
make install > /dev/null

systemctl enable /home/pi/als-dimmer/lib/systemd/system/als-dimmer.service
################################################

# Cleanup build artifacts and source
echo "Cleaning up build artifacts..."
cd /
rm -rf /tmp/als-dimmer

# NOTE: Build dependencies will be purged by main script
# No apt-get purge here!

echo ""
echo "======================================"
echo "  Als-Dimmer Setup Complete"
echo "======================================"
echo "Installation path: /home/pi/als-dimmer"
echo "Binaries:"
echo "  - als-dimmer (main daemon)"
echo ""
echo "Note: Build deps purged by main script"
echo "======================================"
