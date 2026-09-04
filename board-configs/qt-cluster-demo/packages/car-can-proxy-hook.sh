#!/bin/bash
set -e

# car-can-proxy setup hook - runs inside the ARM64 chroot.
#
# Builds can-proxyd, its plugins and tools with cmake, runs the unit tests
# (the vcan integration tests SKIP in a chroot: no network namespace) and
# enables the two services:
#   can-proxy-links  creates the contract vcan0 and configures the vehicle
#                    interface (vcan1 for the bench, or a real canN's bitrate)
#   can-proxyd       the proxy itself, plugin from systemd/can-proxyd.env
#
# The image default is the bench: emu-ev on vcan1, fed by
# car-can-emulator.service (car-can-emulator-hook.sh) running --car=ev.
# This does NOT change what the cluster shows: qt-cluster-demo-hook.sh still
# writes --demo. To put the image on the proxy path set
#   CLUSTER_ARGS=--source=proxy --contract-if=vcan0 --theme=auto ...
# in /home/pi/qt-cluster-demo/systemd/qt-cluster-demo.env (or run
# scripts/build-and-deploy.sh --mode=proxy there). For a real car edit
# /home/pi/car-can-proxy/systemd/can-proxyd.env: VEHICLE_IF=can0,
# PLUGIN=obd2-ice, PLUGIN_ARGS=--plugin-arg source=live.
#
# Environment (from the hook list): HOOK_GIT_REPO / HOOK_GIT_TAG (public
# repo, in-chroot clone) or HOOK_LOCAL_SOURCE; HOOK_INSTALL_DEST.

REPO="${HOOK_GIT_REPO:-https://github.com/hackboxguy/car-can-proxy.git}"
REF="${HOOK_GIT_TAG:-main}"
DEST="${HOOK_INSTALL_DEST:-/home/pi/car-can-proxy}"

echo "======================================"
echo "  car-can-proxy Setup Hook"
echo "======================================"
echo "Source: ${HOOK_LOCAL_SOURCE:-$REPO ($REF)} -> $DEST"
[ "$DEST" = "/home/pi/car-can-proxy" ] || echo "WARNING: units expect /home/pi/car-can-proxy, got $DEST"

if [ -n "${HOOK_LOCAL_SOURCE:-}" ]; then
    echo "[1/4] Installing from local source copy..."
    cp -a "$HOOK_LOCAL_SOURCE" "$DEST"
    rm -rf "$HOOK_LOCAL_SOURCE"
else
    echo "[1/4] Cloning..."
    git clone "$REPO" "$DEST"
    git -C "$DEST" checkout "$REF"
fi
cd "$DEST"

echo "[2/4] Building and unit-testing..."
# Integration tests need vcan interfaces and report SKIP without them.
./scripts/deploy.sh --plugin=emu-ev --skip-deploy

echo "[3/4] Writing service environment (bench: emulator --car=ev on vcan1)..."
cat > systemd/can-proxyd.env <<ENVEOF
# Generated at image-build time by car-can-proxy-hook.sh. Edit and
# 'sudo systemctl restart can-proxy-links can-proxyd' to change.
CONTRACT_IF=vcan0
VEHICLE_IF=vcan1
VEHICLE_BITRATE=500000
PLUGIN=emu-ev
PLUGIN_ARGS=--plugin-arg source=emulator
# e.g. --record=/home/pi/session.log --log-level=debug
EXTRA_ARGS=
ENVEOF

echo "[4/4] Enabling services and the ISO-TP module..."
systemctl enable "$DEST/systemd/can-proxy-links.service" "$DEST/systemd/can-proxyd.service"
# The battery-ECU plugins and the emulator's ev/hybrid modes use the kernel
# ISO-TP socket; load it at boot (can-proxy-links also modprobes it).
echo can_isotp > /etc/modules-load.d/can-isotp.conf

chown -R 1000:1000 "$DEST"
echo ""
echo "car-can-proxy installed; can-proxy-links and can-proxyd start on first boot."
