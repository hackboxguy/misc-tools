#!/bin/bash
set -e

echo "======================================"
echo "  Micropanel Setup Hook"
echo "======================================"
echo ""

# Environment variables available:
# - MOUNT_POINT: Root filesystem mount point
# - PI_PASSWORD: User password (empty if unchanged)
# - IMAGE_WORK_DIR: Working directory path

echo "Running inside chroot environment"
echo "Building micropanel from source..."
echo ""

# Install build dependencies
echo "[1/6] Installing build dependencies..."
apt-get update -qq
apt-get install -y cmake g++ make git

# Clone micropanel repository
echo "[2/6] Cloning micropanel from GitHub..."
cd /tmp
git clone https://github.com/hackboxguy/micropanel.git
cd micropanel

# Create build directory and configure micropanel
echo "[3/6] Configuring CMake..."
mkdir -p build && cd build
cmake -DCMAKE_INSTALL_PREFIX=/home/pi/micropanel \
      -DCMAKE_BUILD_TYPE=Release \
      -DINSTALL_MEDIA_FILES=ON \
      -DINSTALL_SCREEN="config-pios-new.json" \
      -DINSTALL_HELPER_SCRIPTS=ON \
      -DINSTALL_ADDITIONAL_CONFIGS=ON \
      -DINSTALL_SYSTEMD_SERVICE=ON \
      -DSYSTEMD_UNITFILE_ARGS="-a -i gpio -s /dev/i2c-3" \
      .. > /dev/null


# Build micropanel
echo "[4/6] Building micropanel (this may take a few minutes)..."
make -j$(nproc) > /dev/null 2>&1

# Install micropanel
echo "[5/6] Installing micropanel to /home/pi/micropanel..."
make install > /dev/null

# Set correct ownership (pi user is uid:gid 1000:1000)
chown -R 1000:1000 /home/pi/micropanel

# Cleanup build artifacts and source
echo "[6/6] Cleaning up..."
cd /
rm -rf /tmp/micropanel

# Remove build dependencies
echo "Removing build dependencies..."
apt-get purge -y cmake g++ make git > /dev/null 2>&1
apt-get autoremove -y > /dev/null 2>&1
apt-get clean

echo ""
echo "======================================"
echo "  Micropanel Setup Complete"
echo "======================================"
echo "Installation path: /home/pi/micropanel"
echo "Binaries:"
echo "  - micropanel (main daemon)"
echo "  - patch-generator"
echo "  - launcher-client"
echo ""
echo "Note: Service enablement handled by post-install.sh"
echo "======================================"
