#!/bin/bash
# Read-only host-side acceptance check for a completed MicroPanel Touch A/B image.
set -euo pipefail

image_path=${1:-}
[ -n "$image_path" ] || {
    echo "Usage: sudo $0 /path/to/micropanel-touch-ab.img" >&2
    exit 2
}
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root so loop partitions can be mounted" >&2; exit 1; }
[ -f "$image_path" ] || { echo "ERROR: image does not exist: $image_path" >&2; exit 1; }

for tool in sfdisk losetup blkid mount umount mountpoint grep find mktemp stat cmp sort awk tail; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing host tool: $tool" >&2; exit 1; }
done

loop_device=""
boot_a_mount=""
boot_b_mount=""
root_a_mount=""
root_b_mount=""
factory_mount=""
data_mount=""

unmount_if_mounted() {
    local dir=$1
    [ -n "$dir" ] && mountpoint -q "$dir" && umount "$dir"
}

cleanup() {
    local status=$?
    unmount_if_mounted "$data_mount" || true
    unmount_if_mounted "$factory_mount" || true
    unmount_if_mounted "$root_b_mount" || true
    unmount_if_mounted "$root_a_mount" || true
    unmount_if_mounted "$boot_b_mount" || true
    unmount_if_mounted "$boot_a_mount" || true
    if [ -n "$loop_device" ]; then losetup -d "$loop_device" 2>/dev/null || true; fi
    for dir in "$data_mount" "$factory_mount" "$root_b_mount" "$root_a_mount" "$boot_b_mount" "$boot_a_mount"; do
        if [ -n "$dir" ]; then rmdir "$dir" 2>/dev/null || true; fi
    done
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

require() {
    "$@" || { echo "ERROR: verification failed: $*" >&2; exit 1; }
}

table=$(sfdisk --dump "$image_path")
for number in 1 2 3 5 6 7 8; do
    printf '%s\n' "$table" | grep -Fq "${image_path}${number} :" || {
        echo "ERROR: missing partition p${number}" >&2
        exit 1
    }
done
! printf '%s\n' "$table" | grep -Fq "${image_path}4 :" || {
    echo "ERROR: p4 must remain unused" >&2
    exit 1
}

loop_device=$(losetup --find --show --partscan --read-only "$image_path")
retries=0
while [ "$retries" -lt 20 ]; do
    [ -b "${loop_device}p8" ] && break
    sleep 1
    retries=$((retries + 1))
done
[ -b "${loop_device}p8" ] || { echo "ERROR: loop partitions did not appear" >&2; exit 1; }

assert_filesystem() { # $1=device $2=label $3=type
    local device=$1 label=$2 fs_type=$3
    [ "$(blkid -s LABEL -o value "$device")" = "$label" ] || {
        echo "ERROR: expected label $label on $device" >&2
        exit 1
    }
    [ "$(blkid -s TYPE -o value "$device")" = "$fs_type" ] || {
        echo "ERROR: expected $fs_type filesystem on $device" >&2
        exit 1
    }
}

assert_filesystem "${loop_device}p1" MP_BOOT_A vfat
assert_filesystem "${loop_device}p2" MP_BOOT_B vfat
assert_filesystem "${loop_device}p5" MP_ROOT_A ext4
assert_filesystem "${loop_device}p6" MP_ROOT_B ext4
assert_filesystem "${loop_device}p7" MP_FACTORY ext4
assert_filesystem "${loop_device}p8" MICROPANEL_DATA ext4

for expected_label in MP_BOOT_A MP_BOOT_B MP_ROOT_A MP_ROOT_B MP_FACTORY MICROPANEL_DATA; do
    label_count=0
    for number in 1 2 5 6 7 8; do
        [ "$(blkid -s LABEL -o value "${loop_device}p${number}")" = "$expected_label" ] && \
            label_count=$((label_count + 1))
    done
    [ "$label_count" -eq 1 ] || {
        echo "ERROR: expected exactly one $expected_label label, found $label_count" >&2
        exit 1
    }
done

boot_a_mount=$(mktemp -d)
boot_b_mount=$(mktemp -d)
root_a_mount=$(mktemp -d)
root_b_mount=$(mktemp -d)
factory_mount=$(mktemp -d)
data_mount=$(mktemp -d)
mount -o ro "${loop_device}p1" "$boot_a_mount"
mount -o ro "${loop_device}p2" "$boot_b_mount"
mount -o ro "${loop_device}p5" "$root_a_mount"
mount -o ro "${loop_device}p6" "$root_b_mount"
mount -o ro "${loop_device}p7" "$factory_mount"
mount -o ro "${loop_device}p8" "$data_mount"

require test -f "$boot_a_mount/config.txt"
require test -f "$boot_a_mount/tryboot.txt"
require test -f "$boot_a_mount/A/cmdline.txt"
require test -f "$boot_a_mount/B/cmdline.txt"
require grep -Eq '^os_prefix=A/$' "$boot_a_mount/config.txt"
require grep -Eq '^os_prefix=B/$' "$boot_a_mount/tryboot.txt"
require grep -Eq '(^|[[:space:]])root=LABEL=MP_ROOT_A([[:space:]]|$)' "$boot_a_mount/cmdline.txt"
require grep -Eq '(^|[[:space:]])root=LABEL=MP_ROOT_A([[:space:]]|$)' "$boot_a_mount/A/cmdline.txt"
require grep -Eq '(^|[[:space:]])root=LABEL=MP_ROOT_B([[:space:]]|$)' "$boot_a_mount/B/cmdline.txt"
for cmdline in "$boot_a_mount/cmdline.txt" "$boot_a_mount/A/cmdline.txt" "$boot_a_mount/B/cmdline.txt"; do
    require grep -Eq '(^|[[:space:]])overlayroot=tmpfs:recurse=0([[:space:]]|$)' "$cmdline"
done
if ! tail -n +2 "$boot_a_mount/config.txt" | cmp - "$root_a_mount/usr/lib/micropanel-touch/boot-selector-config.base"; then
    echo "ERROR: normal selector configuration differs from its template" >&2
    exit 1
fi
if ! tail -n +2 "$boot_a_mount/tryboot.txt" | cmp - "$root_a_mount/usr/lib/micropanel-touch/boot-selector-config.base"; then
    echo "ERROR: tryboot selector configuration differs from its template" >&2
    exit 1
fi

require grep -Fq 'LABEL=MP_BOOT_A /boot/firmware vfat ' "$root_a_mount/etc/fstab"
require grep -Fq 'LABEL=MICROPANEL_DATA /data ext4 ' "$root_a_mount/etc/fstab"
require grep -Fq '/data/NetworkManager/system-connections /etc/NetworkManager/system-connections none bind,' \
    "$root_a_mount/etc/fstab"
! grep -Eq '^[^#[:space:]][^[:space:]]*[[:space:]]+/[[:space:]]+' "$root_a_mount/etc/fstab" || {
    echo "ERROR: A/B root fstab must not identify a slot-specific / filesystem" >&2
    exit 1
}
require test -x "$root_a_mount/usr/local/sbin/micropanel-touch-data-skeleton"
require test -x "$root_a_mount/usr/local/sbin/micropanel-touch-slot-selector"
require grep -Fq 'RuntimeWatchdogSec=20s' \
    "$root_a_mount/etc/systemd/system.conf.d/90-micropanel-touch-watchdog.conf"
require grep -Fq 'IMAGE_LAYOUT=ab' \
    "$root_a_mount/opt/micropanel-touch/share/micropanel-touch/image-manifest.env"
require grep -Fq 'SLOT_COMPATIBLE_BOARDS=pi4' \
    "$root_a_mount/opt/micropanel-touch/share/micropanel-touch/image-manifest.env"

for directory in micropanel-touch micropanel-touch/logs micropanel-touch/ssh-host-keys \
                 micropanel-touch-system micropanel-touch-network/dhcp-server \
                 NetworkManager/system-connections; do
    require test -d "$data_mount/$directory"
done
app_account=$(awk -F: '$1 == "micropanel-touch" { print $3 ":" $4; exit }' "$root_a_mount/etc/passwd")
case "$app_account" in [0-9]*:[0-9]*) ;; *) echo "ERROR: missing micropanel-touch account in root A" >&2; exit 1 ;; esac
app_group=${app_account#*:}
require test "$(stat -c '%u:%g:%a' "$data_mount/micropanel-touch")" = "${app_account}:750"
require test "$(stat -c '%u:%g:%a' "$data_mount/micropanel-touch/logs")" = "${app_account}:750"
require test "$(stat -c '%u:%g:%a' "$data_mount/micropanel-touch/ssh-host-keys")" = '0:0:700'
require test "$(stat -c '%u:%g:%a' "$data_mount/micropanel-touch-system")" = '0:0:700'
require test "$(stat -c '%u:%g:%a' "$data_mount/micropanel-touch-network")" = "0:${app_group}:750"
require test "$(stat -c '%u:%g:%a' "$data_mount/micropanel-touch-network/dhcp-server")" = "0:${app_group}:750"
require test "$(stat -c '%u:%g:%a' "$data_mount/NetworkManager/system-connections")" = '0:0:700'

# A newly flashed image deliberately leaves B and the factory reserve empty.
! find "$boot_b_mount" -mindepth 1 -print -quit | grep -q . || {
    echo "ERROR: MP_BOOT_B is not empty" >&2
    exit 1
}
[ "$(find "$root_b_mount" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)" = "lost+found" ] || {
    echo "ERROR: MP_ROOT_B is not the expected empty first-flash slot" >&2
    exit 1
}
[ "$(find "$factory_mount" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)" = "lost+found" ] || {
    echo "ERROR: MP_FACTORY is not the expected empty first-flash reserve" >&2
    exit 1
}

echo "A/B image layout verified: $image_path"
