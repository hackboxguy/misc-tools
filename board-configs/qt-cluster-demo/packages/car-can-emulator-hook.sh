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

# CLUSTER_PRUNE=1 (board.conf, see qt-cluster-demo-hook.sh): keep only what
# the unit runs - the binary, the drive cycles, systemd/ and the README.
CLUSTER_PRUNE="${CLUSTER_PRUNE:-0}"
# CLUSTER_DATA_ENV=1 (see qt-cluster-demo-hook.sh): the unit(s) also read
# /data/cluster/<env file> after the image's.
CLUSTER_DATA_ENV="${CLUSTER_DATA_ENV:-0}"

# data_env_dropin <unit> <env file name>: CLUSTER_DATA_ENV=1's drop-in. Wants=,
# not Requires=: without /data the unit still starts, on the image's defaults.
data_env_dropin() {
    install -d "/etc/systemd/system/$1.d"
    cat > "/etc/systemd/system/$1.d/50-data-env.conf" <<EOF
# CLUSTER_DATA_ENV=1 (board.conf): an operator's override on /data, read after
# the image's env file - the later file wins. Survives reboots and updates; a
# factory reset empties /data/cluster.
[Unit]
Wants=data.mount
After=data.mount
[Service]
EnvironmentFile=-/data/cluster/$2
EOF
    echo "  $1: reads /data/cluster/$2 after the image's env file"
}


# prune_to <dir> <path>...: keep only the listed paths (relative to <dir>)
# and delete the rest of the tree - sources, object files, tests, .git. For
# images where the app is started from its build tree but nothing is rebuilt
# on the device (micropanel: CLUSTER_PRUNE=1). The kept paths are exactly
# what the units, the env files and the launcher script reference.
prune_to() {
    local dir="$1"; shift
    local keep; keep="$(mktemp -d)"
    for p in "$@"; do
        [ -e "$dir/$p" ] || { echo "ERROR: prune: $dir/$p missing"; exit 1; }
        mkdir -p "$keep/$(dirname "$p")"
        mv "$dir/$p" "$keep/$p"
    done
    local before; before=$(du -sm "$dir" | cut -f1)
    find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    cp -a "$keep/." "$dir/"
    rm -rf "$keep"
    echo "  pruned $dir: ${before} MB -> $(du -sm "$dir" | cut -f1) MB"
}

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

echo "[3/3] Enabling service (vcan1, --car=hybrid, demo drive cycle)..."
cat > systemd/car-can-emulator.env <<ENVEOF
# Generated at image-build time by car-can-emulator-hook.sh; edit and
# 'sudo systemctl restart car-can-emulator' to change.
# The drive cycle replicates the cluster's built-in demo (44 s lap) so the
# proxy path moves; drop --drive-cycle for a car that sits at fixed values.
EMULATOR_ARGS=--node=vcan1 --car=hybrid --drive-cycle=$DEST/cycles/demo.cycle
#EMULATOR_ARGS=--node=vcan1 --car=ev --drive-cycle=$DEST/cycles/demo.cycle
#EMULATOR_ARGS=--node=can0 --car=ice --debugprint=true
ENVEOF
systemctl enable "$DEST/systemd/car-can-emulator.service"

if [ "$CLUSTER_DATA_ENV" = 1 ]; then
    data_env_dropin car-can-emulator.service car-can-emulator.env
fi

if [ "$CLUSTER_PRUNE" = 1 ]; then
    echo "Pruning to the runtime files (CLUSTER_PRUNE=1)..."
    prune_to "$DEST" build/car-can-emulator cycles systemd README.md
fi

chown -R 1000:1000 "$DEST"
echo ""
echo "car-can-emulator installed; service starts on first boot."
