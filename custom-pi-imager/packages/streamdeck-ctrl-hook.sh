#!/bin/bash
set -e

echo "======================================"
echo "  streamdeck-ctrl Setup Hook"
echo "======================================"
echo ""

# Environment variables available:
# - MOUNT_POINT, PI_PASSWORD, IMAGE_WORK_DIR (always)
# - HOOK_GIT_REPO: git URL (parameterized mode)
# - HOOK_GIT_TAG: screen name, e.g. "display-control" (parameterized mode)
# - HOOK_INSTALL_DEST: install path (parameterized mode)
# - HOOK_DEP_LIST: runtime deps (parameterized mode)
#
# Usage in micropanel-packages.txt:
#   packages/streamdeck-ctrl-hook.sh|https://github.com/hackboxguy/streamdeck-ctrl.git|display-control|/home/pi/streamdeck-ctrl|socat
#                                                                                      ^^^^^^^^^^^^^^^ screen name

INSTALL_DIR="${HOOK_INSTALL_DEST:-/home/pi/streamdeck-ctrl}"
SCREEN_NAME="${HOOK_GIT_TAG:-display-control}"
GIT_REPO="${HOOK_GIT_REPO:-https://github.com/hackboxguy/streamdeck-ctrl.git}"
CONFIG_FILE="${INSTALL_DIR}/screens/${SCREEN_NAME}/${SCREEN_NAME}.json"
INSTALL_USER="pi"

echo "Running inside chroot environment"
echo "  Repo:   ${GIT_REPO}"
echo "  Screen: ${SCREEN_NAME}"
echo "  Dest:   ${INSTALL_DIR}"
echo ""

# Install runtime dependencies
echo "[1/6] Installing runtime dependencies..."
apt-get update -qq
apt-get install -y -qq \
    libhidapi-hidraw0 libhidapi-libusb0 socat \
    python3 python3-pil python3-requests python3-jsonschema \
    python3-elgato-streamdeck

# Clone streamdeck-ctrl repository
echo "[2/6] Cloning streamdeck-ctrl..."
cd /tmp
git clone "${GIT_REPO}" streamdeck-ctrl
cp -r streamdeck-ctrl "${INSTALL_DIR}"

# Verify screen config exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Screen config not found: ${CONFIG_FILE}"
    echo "  Available screens:"
    ls -1 "${INSTALL_DIR}/screens/" 2>/dev/null || echo "  (none)"
    exit 1
fi

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
echo "Screen: ${SCREEN_NAME}"
echo "Config: ${CONFIG_FILE}"
echo "Service: udev-triggered (starts when Stream Deck is present)"
echo "======================================"
