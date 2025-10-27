#!/bin/bash
set -e

update_sysctl() {
    local key=$1
    local value=$2
    echo "${key} = ${value}" >> /etc/sysctl.conf
}

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

# Install build dependencies (no-op if already installed)
echo "[1/5] Installing build dependencies..."
apt-get update -qq
apt-get install -y cmake g++ make git

# Clone micropanel repository
echo "[2/5] Cloning micropanel from GitHub..."
cd /tmp
git clone https://github.com/hackboxguy/micropanel.git
cd micropanel

# Create build directory and configure micropanel
echo "[3/5] Configuring CMake..."
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
echo "[4/5] Building micropanel (this may take a few minutes)..."
make -j$(nproc) > /dev/null 2>&1

# Install micropanel
echo "[5/5] Installing micropanel to /home/pi/micropanel..."
make install > /dev/null

# Set correct ownership (pi user is uid:gid 1000:1000)
chown -R 1000:1000 /home/pi/micropanel

######finalize the micropanel installation######
echo ""
echo "Finalizing micropanel installation..."
# Update sysctl settings
update_sysctl "net.core.rmem_max" "26214400"
update_sysctl "net.core.wmem_max" "26214400"
update_sysctl "net.core.rmem_default" "1310720"
update_sysctl "net.core.wmem_default" "1310720"
#update-config-path.sh cannot do inplace editing of config.json
sync
cp /home/pi/micropanel/etc/micropanel/config.json /home/pi/micropanel/etc/micropanel/config-temp.json
#resolve $MICROPANEL_HOME
/home/pi/micropanel/usr/bin/update-config-path.sh --path=/home/pi/micropanel --output=/home/pi/micropanel/etc/micropanel/config.json --input=/home/pi/micropanel/etc/micropanel/config-temp.json
systemctl enable /home/pi/micropanel/lib/systemd/system/micropanel.service
cp /home/pi/micropanel/usr/share/micropanel/configs/config.txt /boot/firmware/
# Enable high-speed UART
sed -i 's/^console=serial0,115200 //' /boot/firmware/cmdline.txt
# Enable i2c module
echo 'i2c-dev' > /etc/modules-load.d/i2c.conf
################################################


# Cleanup build artifacts and source
echo "Cleaning up build artifacts..."
cd /
rm -rf /tmp/micropanel

# NOTE: Build dependencies will be purged by main script
# No apt-get purge here!

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
echo "Note: Build deps purged by main script"
echo "======================================"
