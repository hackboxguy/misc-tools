#!/bin/bash
# pi-ab-update: read-only host-side acceptance check for a completed A/B image.
#
# Everything here is the cross-board layout/engine contract. A board's own
# assertions - its app account, its /data skeleton, its manifest keys - live in
# the script named by AB_ASSERTIONS, which this runs with AB_ROOT_MOUNT,
# AB_BOOT_MOUNT and AB_DATA_MOUNT exported.
set -euo pipefail

image_path=${1:-}
ab_manifest_path=${AB_MANIFEST_PATH:-}
ab_assertions=${AB_ASSERTIONS:-}
engine_lib_dir=/usr/lib/pi-ab-update
[ -n "$image_path" ] || {
    echo "Usage: sudo $0 /path/to/ab-image.img" >&2
    exit 2
}
[ -n "$ab_manifest_path" ] || { echo "ERROR: AB_MANIFEST_PATH is required" >&2; exit 1; }
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
if ! tail -n +2 "$boot_a_mount/config.txt" | cmp - "$root_a_mount$engine_lib_dir/boot-selector-config.base"; then
    echo "ERROR: normal selector configuration differs from its template" >&2
    exit 1
fi
if ! tail -n +2 "$boot_a_mount/tryboot.txt" | cmp - "$root_a_mount$engine_lib_dir/boot-selector-config.base"; then
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
image_manifest="$root_a_mount$ab_manifest_path"
# The engine's own footprint in the image.
require test -x "$root_a_mount/usr/local/sbin/ab-data-skeleton"
require test -x "$root_a_mount/usr/local/sbin/ab-slot-selector"
require test -x "$root_a_mount/usr/local/sbin/ab-system-update"
require test -x "$root_a_mount/usr/local/bin/ab-update"
# In bin, and specifically not in sbin: sbin is absent from a non-root PATH, so
# the unprivileged queries would be unreachable by name.
require test ! -e "$root_a_mount/usr/local/sbin/ab-update"
require test -x "$root_a_mount/usr/local/sbin/ab-update-check"
require test -x "$root_a_mount/usr/local/sbin/ab-update-commit"
require test -x "$root_a_mount/usr/local/sbin/ab-factory-reset"
require test -x "$root_a_mount/usr/local/sbin/ab-factory-reset-boot"
require test -f "$root_a_mount/lib/systemd/system/ab-factory-reset.service"
require test -L "$root_a_mount/etc/systemd/system/sysinit.target.wants/ab-factory-reset.service"
require test -f "$root_a_mount/lib/systemd/system/ab-update-commit.service"
require test -L "$root_a_mount/etc/systemd/system/multi-user.target.wants/ab-update-commit.service"
require test -f "$root_a_mount$engine_lib_dir/ab-update.conf"
require grep -Eq '^AB_HEALTH_UNITS=[^[:space:]].*$' "$root_a_mount$engine_lib_dir/ab-update.conf"
require grep -Fq 'RuntimeWatchdogSec=20s' \
    "$root_a_mount/etc/systemd/system.conf.d/90-pi-ab-update-watchdog.conf"
# The layout/update contract inside the board's image manifest.
require grep -Fq 'IMAGE_LAYOUT=ab' "$image_manifest"
require grep -Eq '^SLOT_COMPATIBLE_BOARDS=[a-z0-9]+(,[a-z0-9]+)*$' "$image_manifest"
# Stage 2b: the running release version is part of the on-device contract; the
# updater refuses to run without it and uses it for its already-up-to-date
# abort before any large member is read.
require grep -Eq '^IMAGE_VERSION=[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' "$image_manifest"
# The pinned release public key and the root-owned release source. Updates are
# authenticated by this key, not by the transport, so the URL scheme is not a
# security control here - but a production image should still be pointed at an
# https source, and an http one is worth saying out loud.
require grep -Fq 'BEGIN PUBLIC KEY' "$root_a_mount$engine_lib_dir/update-signing-key.pub"
require test "$(stat -c '%u:%g:%a' "$root_a_mount$engine_lib_dir/update-signing-key.pub")" = '0:0:644'
require grep -Eq '^BUNDLE_URL=https?://[^[:space:]]+\.mpupdate$' \
    "$root_a_mount$engine_lib_dir/update-source.conf"
require grep -Eq '^MANIFEST_URL=https?://[^[:space:]]+\.manifest$' \
    "$root_a_mount$engine_lib_dir/update-source.conf"
require grep -Eq '^MANIFEST_SIG_URL=https?://[^[:space:]]+\.manifest\.sig$' \
    "$root_a_mount$engine_lib_dir/update-source.conf"
require test "$(stat -c '%u:%g:%a' "$root_a_mount$engine_lib_dir/update-source.conf")" = '0:0:644'
if grep -Eq '^(BUNDLE|MANIFEST|MANIFEST_SIG)_URL=http://' \
       "$root_a_mount$engine_lib_dir/update-source.conf"; then
    echo "NOTICE: this image fetches releases over plain http - expected for a" >&2
    echo "        bench rehearsal, not for a shipping image." >&2
fi

# Whatever else this particular product requires of its own image.
if [ -n "$ab_assertions" ]; then
    [ -x "$ab_assertions" ] || { echo "ERROR: AB_ASSERTIONS is not executable: $ab_assertions" >&2; exit 1; }
    AB_ROOT_MOUNT="$root_a_mount" AB_BOOT_MOUNT="$boot_a_mount" AB_DATA_MOUNT="$data_mount" \
        AB_IMAGE_MANIFEST="$image_manifest" "$ab_assertions" || {
        echo "ERROR: board assertions failed: $ab_assertions" >&2
        exit 1
    }
fi

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
