#!/bin/bash
set -e
UTIL_NAME=openFPGALoader
echo "======================================"
echo "  $UTIL_NAME Setup Hook"
echo "======================================"
echo ""

# Environment variables available:
# - MOUNT_POINT: Root filesystem mount point
# - PI_PASSWORD: User password (empty if unchanged)
# - IMAGE_WORK_DIR: Working directory path

echo "Running inside chroot environment"
echo "Building openFPGALoader from source..."
echo ""

# Install build dependencies (no-op if already installed)
echo "[1/5] Installing build dependencies..."
apt-get update -qq
apt-get install -y cmake g++ make git libusb-dev libftdi-dev libgpiod-dev

# Clone micropanel repository
echo "[2/5] Cloning micropanel from GitHub..."
cd /tmp
git clone --depth 1 --branch v1.0.0 https://github.com/trabucayre/openFPGALoader.git
cd $UTIL_NAME

# Create build directory and configure micropanel
echo "[3/5] Configuring CMake..."
mkdir -p build && cd build
cmake -DCMAKE_INSTALL_PREFIX=/home/pi/micropanel/fpga \
      -DCMAKE_BUILD_TYPE=Release \
      .. > /dev/null

# Build $UTIL_NAME
echo "[4/5] Building $UTIL_NAME (this may take a few minutes)..."
make -j$(nproc) > /dev/null 2>&1

# Install micropanel
echo "[5/5] Installing $UTIL_NAME to /home/pi/micropanel/fpga..."
make install > /dev/null

# Set correct ownership (pi user is uid:gid 1000:1000)
chown -R 1000:1000 /home/pi/micropanel/fpga

######finalize the $UTIL_NAME installation######
echo ""
echo "Finalizing $UTIL_NAME installation..."


# Cleanup build artifacts and source
echo "Cleaning up build artifacts..."
cd /
rm -rf /tmp/$UTIL_NAME

# NOTE: Build dependencies will be purged by main script
# No apt-get purge here!

echo ""
echo "======================================"
echo "  $UTIL_NAME Setup Complete"
echo "======================================"
echo "Installation path: /home/pi/micropanel/fpga"
echo "Binaries:"
echo "  - $UTIL_NAME (main binary)"
echo ""
echo "Note: Build deps purged by main script"
echo "======================================"
