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
# The image default is the bench: emu-hybrid on vcan1, fed by
# car-can-emulator.service (car-can-emulator-hook.sh) running --car=hybrid.
# This does NOT change what the cluster shows: qt-cluster-demo-hook.sh still
# writes --demo. To put the image on the proxy path set
#   CLUSTER_ARGS=--source=proxy --contract-if=vcan0 --theme=auto ...
# in /home/pi/qt-cluster-demo/systemd/qt-cluster-demo.env, or run
#   scripts/build-and-deploy.sh --mode=proxy --deploy-only
# there (--deploy-only skips the build, which a shipped image cannot do:
# its toolchain is purged). For a real car edit
# /home/pi/car-can-proxy/systemd/can-proxyd.env: VEHICLE_IF=can0,
# PLUGIN=obd2-ice, PLUGIN_ARGS=--plugin-arg source=live.
#
# Environment (from the hook list): HOOK_GIT_REPO / HOOK_GIT_TAG (public
# repo, in-chroot clone) or HOOK_LOCAL_SOURCE; HOOK_INSTALL_DEST.

# CLUSTER_PRUNE=1 (board.conf, see qt-cluster-demo-hook.sh): keep only what
# the units run - can-proxyd, its plugin .so files, systemd/, docs, README.
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
./scripts/deploy.sh --plugin=emu-hybrid --skip-deploy

echo "[3/4] Writing service environment (bench: emulator --car=hybrid on vcan1)..."
cat > systemd/can-proxyd.env <<ENVEOF
# Generated at image-build time by car-can-proxy-hook.sh. Edit and
# 'sudo systemctl restart can-proxy-links can-proxyd' to change.
CONTRACT_IF=vcan0
VEHICLE_IF=vcan1
VEHICLE_BITRATE=500000
PLUGIN=emu-hybrid
PLUGIN_ARGS=--plugin-arg source=emulator
# e.g. --record=/home/pi/session.log --log-level=debug
EXTRA_ARGS=
ENVEOF

echo "[4/4] Enabling services and the ISO-TP module..."
systemctl enable "$DEST/systemd/can-proxy-links.service" "$DEST/systemd/can-proxyd.service"
# The battery-ECU plugins and the emulator's ev/hybrid modes use the kernel
# ISO-TP socket; load it at boot (can-proxy-links also modprobes it).
echo can_isotp > /etc/modules-load.d/can-isotp.conf

if [ "$CLUSTER_DATA_ENV" = 1 ]; then
    data_env_dropin can-proxy-links.service can-proxyd.env
    data_env_dropin can-proxyd.service can-proxyd.env
fi

if [ "$CLUSTER_PRUNE" = 1 ]; then
    echo "Pruning to the runtime files (CLUSTER_PRUNE=1)..."
    # The plugins are loaded as $CANPROXY_PLUGIN_DIR/<name>.so (build/plugins)
    plugins=$(cd "$DEST" && ls build/plugins/*.so)
    # shellcheck disable=SC2086 # one path per word
    prune_to "$DEST" build/core/can-proxyd $plugins systemd docs README.md
fi

chown -R 1000:1000 "$DEST"
echo ""
echo "car-can-proxy installed; can-proxy-links and can-proxyd start on first boot."
