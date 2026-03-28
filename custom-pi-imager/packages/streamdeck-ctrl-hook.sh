#!/bin/bash
set -e

echo "======================================"
echo "  streamdeck-ctrl Setup Hook"
echo "======================================"
echo ""

# Environment variables available:
# - MOUNT_POINT: Root filesystem mount point
# - PI_PASSWORD: User password (empty if unchanged)
# - IMAGE_WORK_DIR: Working directory path

INSTALL_DIR="/home/pi/streamdeck-ctrl"
CONFIG_FILE="${INSTALL_DIR}/screens/display-control/display-control.json"
INSTALL_USER="pi"

echo "Running inside chroot environment"
echo ""

# Install runtime dependencies
echo "[1/6] Installing runtime dependencies..."
apt-get update -qq
apt-get install -y -qq \
    libhidapi-hidraw0 libhidapi-libusb0 socat \
    python3 python3-pil python3-requests python3-jsonschema \
    python3-elgato-streamdeck

# Clone streamdeck-ctrl repository
echo "[2/6] Cloning streamdeck-ctrl from GitHub..."
cd /tmp
git clone https://github.com/hackboxguy/streamdeck-ctrl.git
cp -r streamdeck-ctrl "${INSTALL_DIR}"

# Resolve {INSTALL_DIR} in the config file
echo "[3/6] Resolving {INSTALL_DIR} in config..."
if grep -q '{INSTALL_DIR}' "$CONFIG_FILE"; then
    sed -i "s|{INSTALL_DIR}|${INSTALL_DIR}|g" "$CONFIG_FILE"
    echo "  Replaced {INSTALL_DIR} → ${INSTALL_DIR}"
fi

# Make scripts executable
echo "[4/6] Setting script permissions..."
CONFIG_DIR="$(dirname "$CONFIG_FILE")"
if [ -d "${CONFIG_DIR}/scripts" ]; then
    chmod +x "${CONFIG_DIR}/scripts/"*.sh 2>/dev/null || true
fi

# Install udev rule
echo "[5/6] Installing udev rule..."
cp "${INSTALL_DIR}/99-streamdeck.rules" /etc/udev/rules.d/
usermod -aG plugdev "$INSTALL_USER"

# Install tmpfiles.d and systemd service
echo "[6/6] Installing systemd service..."
echo "d /run/streamdeck-ctrl 0755 ${INSTALL_USER} plugdev -" \
    > /etc/tmpfiles.d/streamdeck-ctrl.conf

sed -e "s|{INSTALL_DIR}|${INSTALL_DIR}|g" \
    -e "s|{USER}|${INSTALL_USER}|g" \
    -e "s|{CONFIG_PATH}|${CONFIG_FILE}|g" \
    "${INSTALL_DIR}/streamdeck-ctrl.service.in" \
    > /etc/systemd/system/streamdeck-ctrl.service

# Set ownership
chown -R 1000:1000 "${INSTALL_DIR}"

# Cleanup
echo "Cleaning up..."
rm -rf /tmp/streamdeck-ctrl

echo ""
echo "======================================"
echo "  streamdeck-ctrl Setup Complete"
echo "======================================"
echo "Installation path: ${INSTALL_DIR}"
echo "Config: ${CONFIG_FILE}"
echo "Service: udev-triggered (starts when Stream Deck is present)"
echo "======================================"
