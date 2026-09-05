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

echo "[2/4] Building (build-and-deploy.sh, build-only)..."
./scripts/build-and-deploy.sh --mode=demo --dms=enable --skip-tests --skip-deploy

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
cat > systemd/qt-cluster-demo.env <<EOF
# Generated at image-build time by qt-cluster-demo-hook.sh
#   source: $SOURCE_NOTE   dms: enable
CLUSTER_ARGS=$SOURCE_ARGS --dms=focusdrive-v2 --dms-vehicle-speed-floor=30 --dms-someip=on --dms-landmarks --dms-protocol=v2 --dms-host=0.0.0.0 --dms-port=5500 --dms-someip-ids=$DEST/docs/focusdrive-agx-ids.pi4.json
DMS_ENABLED=1
SOMEIP_IFACE=eth0
# Free-form additions, e.g. --dms-ncap-icons=both
EXTRA_ARGS=
EOF

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

# pi user is uid:gid 1000:1000
chown -R 1000:1000 "$DEST" /home/pi/.codex-deps 2>/dev/null || chown -R 1000:1000 "$DEST"

echo ""
echo "qt-cluster-demo installed; service starts on first boot."
