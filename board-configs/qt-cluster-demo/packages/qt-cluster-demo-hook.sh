#!/bin/bash
set -e

# qt-cluster-demo setup hook - runs inside the ARM64 chroot.
#
# Builds the cluster app with the repo's own build script (build-only mode)
# and then performs the chroot-safe half of its deploy step: the env file for
# the fixed image variant (--mode=demo --dms=enable, Harman theme) plus systemctl
# enable.
# daemon-reload/restart are skipped - systemd is not running in a chroot.
#
# Environment (from the hook list): HOOK_LOCAL_SOURCE (preferred: host-side
# clone of the private repo, copied into the chroot) or HOOK_GIT_REPO/
# HOOK_GIT_TAG as a fallback for public forks. vsomeip is expected in the
# base image already (qt profile hook) at the prefix below.

REPO="${HOOK_GIT_REPO:-https://github.com/hackboxguy/qt-cluster-demo.git}"
REF="${HOOK_GIT_TAG:-main}"
DEST="${HOOK_INSTALL_DEST:-/home/pi/qt-cluster-demo}"
export VSOMEIP_PREFIX="/home/pi/.codex-deps/prefix/vsomeip-3.5.11"
# Board switches (board.conf; build-image.sh forwards them; empty = default):
#   CLUSTER_SERVICE  1 (default): enable qt-cluster-demo.service and link
#                    cluster-video.service - the cluster owns the display.
#                    0: enable nothing; the app is started by the launcher
#                    (micropanel's Cluster Demo V2 tiles, cluster-v2.sh).
#   CLUSTER_PRUNE    0 (default): keep the whole repo and build tree.
#                    1: keep only the installed app (cmake --install into
#                    $DEST: bin/qt-cluster-demo, share/qt-cluster-demo/ with
#                    the DMS files) plus systemd/ - for a size-capped root.
#                    The repo's unit runs the build tree, so this needs
#                    CLUSTER_SERVICE=0 (a launcher runs bin/qt-cluster-demo).
#   CLUSTER_DATA_ENV 0 (default): the units read the image's env files only.
#                    1: each enabled unit also reads /data/cluster/<env file>
#                    after the image's (the later file wins), an operator's
#                    override that survives reboots and A/B updates
#                    (micropanel; /data/cluster comes from its data skeleton).
CLUSTER_SERVICE="${CLUSTER_SERVICE:-1}"
CLUSTER_PRUNE="${CLUSTER_PRUNE:-0}"
CLUSTER_DATA_ENV="${CLUSTER_DATA_ENV:-0}"

if [ "$CLUSTER_PRUNE" = 1 ] && [ "$CLUSTER_SERVICE" != 0 ]; then
    echo "ERROR: CLUSTER_PRUNE=1 removes the build tree qt-cluster-demo.service runs; set CLUSTER_SERVICE=0"
    exit 1
fi

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

echo "======================================"
echo "  qt-cluster-demo Setup Hook"
echo "======================================"
echo "Source: ${HOOK_LOCAL_SOURCE:-$REPO ($REF)} -> $DEST"

# The systemd unit hardcodes /home/pi/qt-cluster-demo paths
[ "$DEST" = "/home/pi/qt-cluster-demo" ] || echo "WARNING: unit expects /home/pi/qt-cluster-demo, got $DEST"

if [ -n "${HOOK_LOCAL_SOURCE:-}" ]; then
    # Private repo path: sources stage cloned it on the host (with the
    # invoking user's credentials); the imager copied it into the chroot.
    echo "[1/4] Installing from local source copy..."
    cp -a "$HOOK_LOCAL_SOURCE" "$DEST"
    rm -rf "$HOOK_LOCAL_SOURCE"
    cd "$DEST"
else
    # Public-repo fallback: in-chroot clone (would hang on a private repo)
    echo "[1/4] Cloning..."
    git clone "$REPO" "$DEST"
    cd "$DEST"
    git checkout "$REF"
fi

# HOOK_DEP_LIST (the hook line's deps field, comma-separated): build packages
# an earlier hook may have purged - on micropanel the br-wrapper line purges
# qtdeclarative5-dev and pkg-config after its own build. Installed only when
# missing, and purged again after the build: only what this hook installed.
installed_deps=()
for pkg in ${HOOK_DEP_LIST//,/ }; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" || installed_deps+=("$pkg")
done
if [ ${#installed_deps[@]} -gt 0 ]; then
    echo "Installing build packages an earlier hook purged: ${installed_deps[*]}"
    apt-get install -y --no-install-recommends "${installed_deps[@]}"
fi

echo "[2/4] Building (build-and-deploy.sh, build-only)..."
./scripts/build-and-deploy.sh --mode=demo --dms=enable --skip-tests --skip-deploy

if [ ${#installed_deps[@]} -gt 0 ]; then
    apt-get purge -y "${installed_deps[@]}"
fi

# demo: the cluster's own drive cycle. proxy: the car-can-proxy contract on
# vcan0, i.e. the bench vehicle the other two hooks install. Set per board in
# board.conf (CLUSTER_SOURCE) or per build in the environment; build-image.sh
# forwards it and the apps-stage stamp tracks it, so flipping it rebuilds.
CLUSTER_SOURCE="${CLUSTER_SOURCE:-demo}"
case "$CLUSTER_SOURCE" in
    demo)  SOURCE_ARGS="--demo --theme=harman"; SOURCE_NOTE="demo   theme: harman" ;;
    proxy) SOURCE_ARGS="--source=proxy --contract-if=vcan0 --theme=auto"
           SOURCE_NOTE="proxy on vcan0   theme: auto (from the drivetrain)" ;;
    *)     echo "WARNING: unknown CLUSTER_SOURCE '$CLUSTER_SOURCE', using demo"
           SOURCE_ARGS="--demo --theme=harman"; SOURCE_NOTE="demo   theme: harman" ;;
esac

echo "[3/4] Writing service environment ($SOURCE_NOTE, DMS enabled)..."
# Static equivalent of what build-and-deploy.sh --mode=<source> --dms=enable
# writes in its deploy step (kept in sync with that script).
# Installed (CLUSTER_PRUNE=1): the DMS files sit together in share/; the IDs
# file names its vsomeip configuration relative to itself
if [ "$CLUSTER_PRUNE" = 1 ]; then
    IDS_PATH="$DEST/share/qt-cluster-demo/focusdrive-agx-ids.pi4.json"
else
    IDS_PATH="$DEST/docs/focusdrive-agx-ids.pi4.json"
fi
cat > systemd/qt-cluster-demo.env <<EOF
# Generated at image-build time by qt-cluster-demo-hook.sh
#   source: $SOURCE_NOTE   dms: enable
CLUSTER_ARGS=$SOURCE_ARGS --dms=focusdrive-v2 --dms-vehicle-speed-floor=30 --dms-someip=on --dms-landmarks --dms-protocol=v2 --dms-host=0.0.0.0 --dms-port=5500 --dms-someip-ids=$IDS_PATH
DMS_ENABLED=1
SOMEIP_IFACE=eth0
# Free-form additions, e.g. --dms-ncap-icons=both
EXTRA_ARGS=
EOF

if [ "$CLUSTER_SERVICE" = 0 ]; then
    echo "[4/4] Not enabling qt-cluster-demo.service (CLUSTER_SERVICE=0: the launcher starts the app)"
else
echo "[4/4] Enabling service..."
systemctl enable "$DEST/systemd/qt-cluster-demo.service"

# The video unit is linked so "systemctl start cluster-video" resolves it, but
# deliberately NOT enabled: it must never come up at boot, so the panel always
# shows the cluster after a power cycle regardless of what was playing before.
# A plain symlink rather than "systemctl link" because systemd is not running
# in the chroot.
if [ -f "$DEST/systemd/cluster-video.service" ]; then
    ln -sf "$DEST/systemd/cluster-video.service" \
        /etc/systemd/system/cluster-video.service
    echo "  cluster-video.service linked (not enabled)"
fi
if [ "$CLUSTER_DATA_ENV" = 1 ]; then
    data_env_dropin qt-cluster-demo.service qt-cluster-demo.env
fi
fi

if [ "$CLUSTER_PRUNE" = 1 ]; then
    echo "Installing the app and dropping the source and build trees (CLUSTER_PRUNE=1)..."
    before=$(du -sm "$DEST" | cut -f1)
    stage="$(mktemp -d)"
    cmake --install build-pi-agx --prefix "$stage"
    for f in bin/qt-cluster-demo share/qt-cluster-demo/focusdrive-agx-ids.pi4.json \
             share/qt-cluster-demo/vsomeip-focusdrive-agx-sd.example.json \
             share/qt-cluster-demo/pi-dms-production-baseline.sh; do
        [ -e "$stage/$f" ] || { echo "ERROR: cmake --install did not install $f"; exit 1; }
    done
    # The repo's own launcher script for the old-style menu: not used here
    rm -rf "$stage/share/qt-apps"
    cp -a systemd README.md "$stage/"
    cd /
    find "$DEST" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    cp -a "$stage/." "$DEST/"
    rm -rf "$stage"
    echo "  $DEST: ${before} MB -> $(du -sm "$DEST" | cut -f1) MB"
fi

# pi user is uid:gid 1000:1000
chown -R 1000:1000 "$DEST" /home/pi/.codex-deps 2>/dev/null || chown -R 1000:1000 "$DEST"

echo ""
echo "qt-cluster-demo installed; service starts on first boot."
