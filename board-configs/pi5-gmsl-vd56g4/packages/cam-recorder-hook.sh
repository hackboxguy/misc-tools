#!/bin/bash
# cam-recorder setup hook — live camera view + on-demand USB recording.
#
# Userspace only: the camera itself (driver, firmware, overlays, config.txt) is
# brought up by pi5-gmsl-vd56g4-hook.sh, which runs first. This hook just builds
# and installs the apps that sit on top of /dev/video0.
#
# The same sources build the Jetson Orin image; the binary picks its pipeline at
# run time (--platform, autodetected by probing for nvdrmvideosink), so nothing
# here is Pi-specific beyond enabling cam-media-setup.
set -e
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SRC="${HOOK_LOCAL_SOURCE:-}"
echo "======================================"
echo "  cam-recorder Setup Hook"
echo "======================================"
[ -z "$SRC" ] && { echo "ERROR: HOOK_LOCAL_SOURCE unset (cam-recorder must be a file:// local source)"; exit 1; }
[ -d "$SRC" ] || { echo "ERROR: source not found at $SRC"; exit 1; }
for f in Makefile src/cam-recorder.c src/cam-keyd.c src/cam-recctl.c \
         scripts/camview scripts/cam-media-setup share/rec-dot.png; do
	[ -e "$SRC/$f" ] || { echo "ERROR: $SRC/$f missing"; exit 1; }
done
echo "Source: $SRC"

echo "[1/3] Building ..."
# The toolchain comes from build-deps.txt, which the imager installs before the
# hooks and purges afterwards - do NOT apt-get it here, that bypasses the
# stamping and the cleanup.
BUILD=/tmp/cam-recorder-build
rm -rf "$BUILD"; cp -a "$SRC" "$BUILD"; rm -rf "$BUILD/.git"
make -C "$BUILD" clean >/dev/null 2>&1 || true
make -C "$BUILD"
file "$BUILD/cam-recorder" | grep -q aarch64 || { echo "ERROR: not an aarch64 binary"; exit 1; }

echo "[2/3] Installing ..."
make -C "$BUILD" install
rm -rf "$BUILD"
echo "  $(ls /usr/bin/cam-* | tr '\n' ' ')"

echo "[3/3] Selecting the boot display app ..."
# cam-recorder and camview both want exclusive /dev/video0, so exactly one is
# enabled. Two enabled units with Conflicts= race at boot and systemd picks
# arbitrarily. camview is started on demand by the "+" key.
systemctl enable cam-media-setup.service >/dev/null 2>&1 || true
systemctl enable cam-recorder.service    >/dev/null 2>&1 || true
systemctl enable cam-keyd.service        >/dev/null 2>&1 || true
systemctl disable camview.service        >/dev/null 2>&1 || true
# Supersedes the camera hook's own live-view unit, which camview replaces.
systemctl disable vd56g4-camview.service >/dev/null 2>&1 || true

echo "cam-recorder hook: done"
echo "  boot app : cam-recorder (live view + recording)"
echo "  keys     : Enter = record, '-' = recorder, '+' = camview"
echo "  CLI      : cam-recctl status|start|stop|toggle"
echo "  clips    : /media/usb/recording/cam-YYYYmmdd-HHMMSS.mp4"
