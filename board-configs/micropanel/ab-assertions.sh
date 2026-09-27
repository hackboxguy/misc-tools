#!/bin/bash
# micropanel assertions for the pi-ab-update image verifier.
#
# The engine checks the cross-board layout and its own footprint; this checks
# what is true of *this* product's image: its manifest keys, its boot
# configuration split, its durable /data skeleton, and what the engine needs
# from it that the generic verifier cannot know about.
set -euo pipefail

root_mount=${AB_ROOT_MOUNT:?AB_ROOT_MOUNT is required}
boot_mount=${AB_BOOT_MOUNT:?AB_BOOT_MOUNT is required}
data_mount=${AB_DATA_MOUNT:?AB_DATA_MOUNT is required}
image_manifest=${AB_IMAGE_MANIFEST:?AB_IMAGE_MANIFEST is required}
engine_lib_dir=/usr/lib/pi-ab-update

require() { "$@" || { echo "ERROR: board assertion failed: $*" >&2; exit 1; }; }

# --- Manifest -----------------------------------------------------------------
require grep -Fqx 'SLOT_COMPATIBLE_BOARDS=pi4' "$image_manifest"
# The asset names the device fetches are derived from this value, and the
# builder names the published assets from DEFAULT_PANEL_VARIANT=base: the two
# must agree or OTA looks for files that were never published.
require grep -Fqx 'IMAGE_VARIANT=base' "$image_manifest"
require grep -Eq '^MICROPANEL_REVISION=[0-9a-f]{40}$' "$image_manifest"
revision=$(awk -F= '$1 == "MICROPANEL_REVISION" { print $2; exit }' "$image_manifest")
# ab-update --active-revision reads AB_APP_REVISION.
require grep -Fqx "AB_APP_REVISION=$revision" "$image_manifest"

# --- Boot configuration ---------------------------------------------------------
# The display configuration is device-owned and shared by both slots: it lives
# at the root of p1 and the release-owned selector template only includes it,
# so neither an update nor a slot commit can overwrite a device's display type.
require test -f "$boot_mount/micropanel-display.txt"
template="$root_mount$engine_lib_dir/boot-selector-config.base"
require grep -Eq '^[[:space:]]*include[[:space:]]+micropanel-display\.txt[[:space:]]*$' "$template"
if grep -Eq '^[[:space:]]*os_prefix=' "$template"; then
    echo "ERROR: board assertion failed: the selector template selects an os_prefix" >&2
    exit 1
fi
# No slot boots with any init= at all: the engine verifier refuses Pi OS's
# first-boot resize, and this board has no other init to run.
for cmdline in cmdline.txt A/cmdline.txt B/cmdline.txt; do
    if grep -Eq '(^|[[:space:]])init=' "$boot_mount/$cmdline"; then
        echo "ERROR: board assertion failed: init= in $cmdline" >&2
        exit 1
    fi
done

# --- Durable /data skeleton ------------------------------------------------------
app_account=$(awk -F: '$1 == "pi" { print $3 ":" $4; exit }' "$root_mount/etc/passwd")
case "$app_account" in
    [0-9]*:[0-9]*) ;;
    *) echo "ERROR: missing pi account in root A" >&2; exit 1 ;;
esac
require test "$(stat -c '%u:%g:%a' "$data_mount/micropanel")" = "${app_account}:755"
require test "$(stat -c '%u:%g:%a' "$data_mount/micropanel-system")" = '0:0:700'
require test "$(stat -c '%u:%g:%a' "$data_mount/micropanel-system/ssh-host-keys")" = '0:0:700'
require test "$(stat -c '%u:%g:%a' "$data_mount/micropanel-system/var-lib-micropanel")" = '0:0:755'
require test "$(stat -c '%u:%g:%a' "$data_mount/disp-settings")" = '0:0:755'
require test "$(stat -c '%u:%g:%a' "$data_mount/kodi")" = "${app_account}:755"
require test "$(stat -c '%u:%g:%a' "$data_mount/disptool-results")" = "${app_account}:755"
require test "$(stat -c '%u:%g:%a' "$data_mount/NetworkManager/system-connections")" = '0:0:700'
# The kodi profile the image authored is seeded into /data on first flash.
if [ -n "$(ls -A "$root_mount/home/pi/.kodi" 2>/dev/null)" ]; then
    require test -n "$(ls -A "$data_mount/kodi")"
    require test -z "$(find "$data_mount/kodi" ! -user "${app_account%%:*}" -print -quit)"
fi

# --- What the engine needs from this image --------------------------------------
# Every health unit must be enabled: a unit that never starts fails every
# candidate's health window, and every update falls back.
for unit in micropanel.service qt-demo-launcher.service; do
    require test -L "$root_mount/etc/systemd/system/multi-user.target.wants/$unit"
    require grep -Fq "$unit" "$root_mount/etc/systemd/system/ab-update-commit.service.d/10-health-units.conf"
done
require grep -Fq 'micropanel-machine-id.service' \
    "$root_mount/etc/systemd/system/ab-factory-reset.service.d/10-before-consumers.conf"
require grep -Eq '^BUNDLE_URL=https?://[^[:space:]]+/micropanel-base\.mpupdate$' \
    "$root_mount$engine_lib_dir/update-source.conf"
# The update path's own tools (runtime-deps-ab.txt): decompress, fetch, verify.
for tool in xz curl openssl; do
    require test -x "$root_mount/usr/bin/$tool"
done
