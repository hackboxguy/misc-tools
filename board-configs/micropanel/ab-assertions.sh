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
board_dir=$(cd "$(dirname "$0")" && pwd)

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
# (The flat and per-slot config.txt copies are never authoritative and may
# differ; the selector renders p1/config.txt and tryboot.txt from the template.)
display_file="$boot_mount/micropanel-display.txt"
require test -f "$display_file"
require grep -Eq '^# micropanel-display-type: [A-Za-z0-9._-]+$' "$display_file"
template="$root_mount$engine_lib_dir/boot-selector-config.base"
require test "$(grep -c '^include ' "$template")" = 1
require grep -Eq '^[[:space:]]*include[[:space:]]+micropanel-display\.txt[[:space:]]*$' "$template"
for device_line in '^[[:space:]]*os_prefix=' '^hdmi_timings=' '^dtoverlay=himax-touch'; do
    if grep -Eq "$device_line" "$template"; then
        echo "ERROR: board assertion failed: the selector template carries a device line ($device_line)" >&2
        exit 1
    fi
done
# pi-config-txt.sh is told to use the display file.
require grep -Fqx 'MICROPANEL_BOOT_CONFIG=/boot/firmware/micropanel-display.txt' "$root_mount/etc/default/micropanel"
# The overlay contract. The firmware resolves overlays under os_prefix, i.e.
# from the slot being booted, while the display file naming them is the
# device's own and outlives every update: an overlay a release drops or renames
# stops exactly the devices whose display file names it from booting their
# display. Every overlay the template, this device's display file, or any
# display type can name (pi-config-txt.sh: vc4-kms/fkms-v3d, and the touch
# overlay and its per-type replacements) must be in the slot's overlays/.
# No exceptions: the last one (gpio-pullup, which existed in no overlay set)
# became the firmware's own gpio=22=ip,pu in micropanel's template.
known_missing_overlays=" "
overlay_names=$( { grep -h '^[[:space:]]*dtoverlay=' "$template" "$display_file";
                   printf 'dtoverlay=%s\n' vc4-kms-v3d vc4-fkms-v3d himax-touch himax-touch-oled hh983-serializer; } |
                 sed 's/^[[:space:]]*dtoverlay=//; s/[,[:space:]].*//' | sed '/^$/d' | sort -u)
for slot in A B; do
    for overlay in $overlay_names; do
        case "$known_missing_overlays" in *" $overlay "*) continue ;; esac
        require test -f "$boot_mount/$slot/overlays/$overlay.dtbo"
    done
done
# The module contract: every driver a display type can configure is in the
# custom kernel's out-of-tree module set.
release=$(grep -a -o -m1 'Linux version [^ ]*' "$boot_mount/A/Image" | awk '{print $3}')
require test -n "$release"
for module in hh983-serializer himax_mmi himax_oled; do
    require sh -c "ls '$root_mount/lib/modules/$release/extra/$module'.ko* >/dev/null 2>&1"
done
# The derived module configuration is regenerated every boot; nothing loads the
# drivers from a static list before it has run.
require test -L "$root_mount/etc/systemd/system/multi-user.target.wants/micropanel-display-derive.service"
require test ! -e "$root_mount/etc/modules-load.d/custom-drivers.conf"
# ...nor by alias: a driver loaded before the derive unit would need a reload.
for module in hh983_serializer himax_mmi himax_oled; do
    require grep -Fqx "blacklist $module" "$root_mount/etc/modprobe.d/micropanel-no-autoload.conf"
done
# Pi OS's one-shot root resize would fail on every boot of an overlay root.
require test ! -e "$root_mount/etc/init.d/resize2fs_once"
require test -z "$(find "$root_mount"/etc/rc?.d -name '*resize2fs_once*' 2>/dev/null)"
# The custom kernel boots through an initramfs (overlayroot needs one), under a
# version-free name that every slot carries: os_prefix makes the firmware load
# A/ or B/'s copy, which must be the kernel's own.
require test -s "$boot_mount/initramfs-custom"
for slot in A B; do
    require cmp -s "$boot_mount/initramfs-custom" "$boot_mount/$slot/initramfs-custom"
    require cmp -s "$boot_mount/Image" "$boot_mount/$slot/Image"
done
# Release-owned (it belongs to this image layout), so it is in the template.
require test "$(grep -Ec '^[[:space:]]*initramfs[[:space:]]' "$template")" = 1
require grep -Fqx 'initramfs initramfs-custom followkernel' "$template"
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
require test "$(stat -c '%u:%g:%a' "$data_mount/disp-settings")" = "${app_account}:755"
require test "$(stat -c '%u:%g:%a' "$data_mount/kodi")" = "${app_account}:755"
require test "$(stat -c '%u:%g:%a' "$data_mount/disptool-results")" = "${app_account}:755"
require test "$(stat -c '%u:%g:%a' "$data_mount/NetworkManager/system-connections")" = '0:0:700'
# The kodi profile the image authored is seeded into /data on first flash.
if [ -n "$(ls -A "$root_mount/home/pi/.kodi" 2>/dev/null)" ]; then
    require test -n "$(ls -A "$data_mount/kodi")"
    require test -z "$(find "$data_mount/kodi" ! -user "${app_account%%:*}" -print -quit)"
fi

# --- The appliance conversion (micropanel-appliance-hook.sh) --------------------
# Every persistence bind the hook appends survived the finalizer's fstab rewrite.
while IFS= read -r bind_line; do
    require grep -Fqx -- "$bind_line" "$root_mount/etc/fstab"
done <<BINDS
$(grep -Ev '^[[:space:]]*(#|$)' "$board_dir/packages/micropanel-appliance-hook.d/fstab.binds")
BINDS
require test "$(grep -c 'x-systemd.after=ab-factory-reset.service' "$root_mount/etc/fstab")" -ge 5
# Durable identity is restored from /data; the image carries none of its own.
require test -L "$root_mount/etc/systemd/system/sysinit.target.wants/micropanel-machine-id.service"
require test -L "$root_mount/etc/systemd/system/ssh.service.wants/micropanel-ssh-host-keys.service"
require test -x "$root_mount/usr/local/sbin/micropanel-restore-machine-id"
require test -x "$root_mount/usr/local/sbin/micropanel-restore-ssh-host-keys"
require test -f "$root_mount/etc/machine-id"
require test ! -s "$root_mount/etc/machine-id"
require test "$(readlink "$root_mount/etc/systemd/system/regenerate_ssh_host_keys.service")" = /dev/null
# Nothing that writes below an overlay root.
require test ! -e "$root_mount/var/swap"
require test ! -e "$root_mount/etc/systemd/system/multi-user.target.wants/dphys-swapfile.service"
require test ! -e "$root_mount/etc/systemd/system/multi-user.target.wants/rpi-eeprom-update.service"
require test ! -e "$root_mount/etc/systemd/system/multi-user.target.wants/sdm-firstboot.service"
# overlayroot is installed (the build-dep purge cascade must not have taken it).
require awk '/^Package: overlayroot$/ { found = 1 } found && /^Status:/ { exit ($0 ~ /install ok installed/) ? 0 : 1 } END { if (!found) exit 1 }' \
    "$root_mount/var/lib/dpkg/status"
require test -f "$root_mount/usr/share/initramfs-tools/scripts/init-bottom/overlayroot"
# micropanel's settings are written on /data (it saves by rename, so the
# configured path itself must be there); the old path is a reader's symlink.
require grep -Fq '"file_path": "/data/micropanel/settings.json"' \
    "$root_mount/home/pi/micropanel/etc/micropanel/config.json"
require test "$(readlink "$root_mount/home/pi/micropanel/settings.json")" = /data/micropanel/settings.json

# --- What the engine needs from this image --------------------------------------
# Every health unit must be enabled: a unit that never starts fails every
# candidate's health window, and every update falls back. The list is read
# from the installed ab-update.conf, so this cannot disagree with it.
health_units=$(awk -F= '$1 == "AB_HEALTH_UNITS" { print $2; exit }' "$root_mount$engine_lib_dir/ab-update.conf")
require test -n "$health_units"
for unit in $health_units; do
    require test -L "$root_mount/etc/systemd/system/multi-user.target.wants/$unit"
    require grep -Fq "$unit" "$root_mount/etc/systemd/system/ab-update-commit.service.d/10-health-units.conf"
done
# Pulled in, never ordered after (After= made a cycle; systemd deleted the job).
if grep -Eq '^After=' "$root_mount/etc/systemd/system/ab-update-commit.service.d/10-health-units.conf"; then
    echo "ERROR: board assertion failed: the commit service is ordered after its health units" >&2
    exit 1
fi
require grep -Fq 'micropanel-machine-id.service' \
    "$root_mount/etc/systemd/system/ab-factory-reset.service.d/10-before-consumers.conf"
require grep -Eq '^BUNDLE_URL=https?://[^[:space:]]+/micropanel-base\.mpupdate$' \
    "$root_mount$engine_lib_dir/update-source.conf"
# The update path's own tools (runtime-deps-ab.txt): decompress, fetch, verify.
for tool in xz curl openssl; do
    require test -x "$root_mount/usr/bin/$tool"
done
