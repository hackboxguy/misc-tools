#!/bin/bash
set -e

# car-can-emulator setup hook - runs inside the ARM64 chroot.
#
# The bench vehicle for car-can-proxy: an OBD-II ECU plus (ev/hybrid) a
# UDS/ISO-TP battery ECU on vcan1, so the proxy and the cluster can be shown
# on a Pi with no car attached. The image default is --car=hybrid: it
# exercises the OBD-II ECU, the UDS battery ECU over ISO-TP, the driver
# assist DID and, through --theme=auto, the third theme's badge and risk
# glow, all in the boot state (an ev bench reaches everything but the last
# two). The control port on 8080 changes values at runtime (README).
# Switch the car type in /home/pi/car-can-emulator/systemd/car-can-emulator.env.
#
# Environment (from the hook list): HOOK_GIT_REPO / HOOK_GIT_TAG or
# HOOK_LOCAL_SOURCE; HOOK_INSTALL_DEST.

REPO="${HOOK_GIT_REPO:-https://github.com/hackboxguy/car-can-emulator.git}"
REF="${HOOK_GIT_TAG:-main}"
DEST="${HOOK_INSTALL_DEST:-/home/pi/car-can-emulator}"

echo "======================================"
echo "  car-can-emulator Setup Hook"
echo "======================================"
echo "Source: ${HOOK_LOCAL_SOURCE:-$REPO ($REF)} -> $DEST"
[ "$DEST" = "/home/pi/car-can-emulator" ] || echo "WARNING: unit expects /home/pi/car-can-emulator, got $DEST"

if [ -n "${HOOK_LOCAL_SOURCE:-}" ]; then
    echo "[1/3] Installing from local source copy..."
    cp -a "$HOOK_LOCAL_SOURCE" "$DEST"
    rm -rf "$HOOK_LOCAL_SOURCE"
else
    echo "[1/3] Cloning..."
    git clone "$REPO" "$DEST"
    git -C "$DEST" checkout "$REF"
fi
cd "$DEST"

echo "[2/3] Building..."
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build build -j"$(nproc)"

echo "[3/3] Enabling service (vcan1, --car=hybrid)..."
cat > systemd/car-can-emulator.env <<ENVEOF
# Generated at image-build time by car-can-emulator-hook.sh; edit and
# 'sudo systemctl restart car-can-emulator' to change.
EMULATOR_ARGS=--node=vcan1 --car=hybrid
#EMULATOR_ARGS=--node=vcan1 --car=ev
#EMULATOR_ARGS=--node=can0 --car=ice --debugprint=true
ENVEOF
systemctl enable "$DEST/systemd/car-can-emulator.service"

chown -R 1000:1000 "$DEST"
echo ""
echo "car-can-emulator installed; service starts on first boot."
