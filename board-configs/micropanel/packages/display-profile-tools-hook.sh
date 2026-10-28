#!/bin/bash
set -e
# display-profile-tools hook - runs inside the ARM64 chroot.
#
# Installs make-display-profile.py from sdr-hdr-shootout-demo (tools/) where the
# launcher's HDR Display Profile worker looks first (br-wrapper
# hdr-profile-worker.sh): /home/pi/micropanel/share/display-profile/. Standard
# library only, nothing to build. The repo is private: board.conf's SOURCES
# clones it on the host (sdr-hdr), the hook list passes it as a local source.

DEST="${HOOK_INSTALL_DEST:-/home/pi/micropanel}"
SRC="${HOOK_LOCAL_SOURCE:-}"

echo "======================================"
echo "  display-profile-tools Setup Hook"
echo "======================================"
[ -n "$SRC" ] && [ -f "$SRC/tools/make-display-profile.py" ] \
    || { echo "ERROR: tools/make-display-profile.py not found in '${SRC}' (sdr-hdr in board.conf SOURCES?)"; exit 1; }

install -D -m 0755 -o 1000 -g 1000 "$SRC/tools/make-display-profile.py" \
    "$DEST/share/display-profile/make-display-profile.py"
chown 1000:1000 "$DEST/share/display-profile"
echo "Installed $DEST/share/display-profile/make-display-profile.py"

if [ -n "${AB_MANIFEST_PATH:-}" ] && [ -d "$SRC/.git" ]; then
    printf 'SDR_HDR_SHOOTOUT_DEMO_REVISION=%s\n' "$(git -C "$SRC" rev-parse HEAD)" >> "$AB_MANIFEST_PATH"
fi

rm -rf "$SRC"
echo "  display-profile-tools Setup Complete"
