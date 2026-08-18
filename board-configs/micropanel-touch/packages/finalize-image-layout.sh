#!/bin/bash
# Host-side post-image hook for MicroPanel Touch storage layouts.
#
# Default mode retains the established three-partition appliance image.  The
# opt-in A/B mode creates the Stage 1 MBR layout without altering the source
# image until the finished replacement has been fully assembled.
set -euo pipefail

export LC_ALL=C

image_path=${IMAGE_PATH:-}
data_partition_mb=${DATA_PARTITION_MB:-}
ab_layout=${AB_LAYOUT:-0}
ab_image_size_mb=${AB_IMAGE_SIZE_MB:-0}
ab_boot_partition_mb=${AB_BOOT_PARTITION_MB:-256}
ab_root_partition_mb=${AB_ROOT_PARTITION_MB:-5120}
ab_factory_partition_mb=${AB_FACTORY_PARTITION_MB:-2048}
slot_compatible_boards=${SLOT_COMPATIBLE_BOARDS:-pi4}
expected_micropanel_touch_revision=${MICROPANEL_TOUCH_REVISION:-}

script_dir=$(cd "$(dirname "$0")" && pwd)
data_skeleton_script=${DATA_SKELETON_SCRIPT:-$script_dir/micropanel-touch-data-skeleton.sh}
selector_script=${SLOT_SELECTOR_SCRIPT:-$script_dir/micropanel-touch-slot-selector}

data_label=MICROPANEL_DATA
alignment_sectors=2048

usage() {
    cat >&2 <<'EOF'
Usage: finalize-image-layout.sh
       finalize-image-layout.sh --print-ab-layout
EOF
    exit 2
}

positive_integer() { [[ ${1:-} =~ ^[1-9][0-9]*$ ]]; }

print_ab_layout() {
    positive_integer "$ab_image_size_mb" || {
        echo "ERROR: AB_IMAGE_SIZE_MB must be a positive integer" >&2
        exit 2
    }
    printf '%s\n' \
        'layout=ab' \
        "image_size_mib=$ab_image_size_mb" \
        "p1=MP_BOOT_A:${ab_boot_partition_mb}MiB:vfat" \
        "p2=MP_BOOT_B:${ab_boot_partition_mb}MiB:vfat-reserved" \
        'p3=extended' \
        "p5=MP_ROOT_A:${ab_root_partition_mb}MiB:ext4" \
        "p6=MP_ROOT_B:${ab_root_partition_mb}MiB:ext4-reserved" \
        "p7=MP_FACTORY:${ab_factory_partition_mb}MiB:ext4-reserved" \
        'p8=MICROPANEL_DATA:remainder:ext4' \
        'normal_selector=os_prefix=A/' \
        'tryboot_selector=os_prefix=B/'
}

if [ "${1:-}" = "--print-ab-layout" ]; then
    [ "$#" -eq 1 ] || usage
    print_ab_layout
    exit 0
fi
[ "$#" -eq 0 ] || usage

for tool in sfdisk fdisk losetup mkfs.ext4 mkfs.vfat e2fsck resize2fs \
            e2label blkid blockdev mount umount mountpoint cp install awk sed \
            truncate stat sync; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: required host tool is missing: $tool" >&2
        exit 1
    }
done

[ "$(id -u)" -eq 0 ] || { echo "ERROR: post-image layout must run as root" >&2; exit 1; }
[ -n "$image_path" ] || { echo "ERROR: IMAGE_PATH is required" >&2; exit 1; }
[ -f "$image_path" ] || { echo "ERROR: image does not exist: $image_path" >&2; exit 1; }
case "$ab_layout" in 0|1) ;; *) echo "ERROR: AB_LAYOUT must be 0 or 1" >&2; exit 1 ;; esac
if [ "$ab_layout" = 0 ]; then
    [ -n "$data_partition_mb" ] || { echo "ERROR: DATA_PARTITION_MB is required for the single-slot layout" >&2; exit 1; }
    [[ "$data_partition_mb" =~ ^[1-9][0-9]*$ ]] || {
        echo "ERROR: DATA_PARTITION_MB must be a positive integer" >&2
        exit 1
    }
fi

for value in "$ab_boot_partition_mb" "$ab_root_partition_mb" "$ab_factory_partition_mb"; do
    positive_integer "$value" || { echo "ERROR: A/B partition sizes must be positive integers" >&2; exit 1; }
done

source_loop=""
target_loop=""
source_boot_mount=""
root_mount=""
data_mount=""
boot_mount=""
ab_image_path=""

unmount_if_mounted() {
    local dir=$1
    [ -n "$dir" ] && mountpoint -q "$dir" && umount "$dir"
}

cleanup() {
    local status=$?
    unmount_if_mounted "$data_mount" || true
    unmount_if_mounted "$root_mount" || true
    unmount_if_mounted "$boot_mount" || true
    unmount_if_mounted "$source_boot_mount" || true
    if [ -n "$target_loop" ]; then losetup -d "$target_loop" 2>/dev/null || true; fi
    if [ -n "$source_loop" ]; then losetup -d "$source_loop" 2>/dev/null || true; fi
    if [ -n "$data_mount" ]; then rmdir "$data_mount" 2>/dev/null || true; fi
    if [ -n "$root_mount" ]; then rmdir "$root_mount" 2>/dev/null || true; fi
    if [ -n "$boot_mount" ]; then rmdir "$boot_mount" 2>/dev/null || true; fi
    if [ -n "$source_boot_mount" ]; then rmdir "$source_boot_mount" 2>/dev/null || true; fi
    [ -n "$ab_image_path" ] && [ -e "$ab_image_path" ] && rm -f "$ab_image_path"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

wait_for_partitions() { # $1=loop device, remaining args are partition numbers
    local loop=$1; shift
    local number ready=0 retries=0
    while [ "$retries" -lt 20 ]; do
        ready=1
        for number in "$@"; do
            [ -b "${loop}p${number}" ] || { ready=0; break; }
        done
        [ "$ready" = 1 ] && return 0
        sleep 1
        retries=$((retries + 1))
    done
    echo "ERROR: loop partitions did not appear for $loop" >&2
    return 1
}

image_partition_lines() {
    sfdisk --dump "$1" | awk '/:[[:space:]]*start=/{print}'
}

account_ids() { # $1=root mount; prints UID:GID
    awk -F: '$1 == "micropanel-touch" {print $3 ":" $4; exit}' "$1/etc/passwd"
}

install_data_skeleton_tool() { # $1=root mount
    install -Dm0755 "$data_skeleton_script" \
        "$1/usr/local/sbin/micropanel-touch-data-skeleton"
}

seed_data_skeleton() { # $1=root mount; $2=data mount
    local account
    account=$(account_ids "$1")
    [[ "$account" =~ ^[0-9]+:[0-9]+$ ]] || {
        echo "ERROR: micropanel-touch sysuser was not created in the image" >&2
        exit 1
    }
    "$data_skeleton_script" --root "$2" \
        --uid "${account%%:*}" --gid "${account##*:}"
}

seed_network_connections() { # $1=root mount; $2=data mount
    local network_connections="$1/etc/NetworkManager/system-connections"
    if [ -d "$network_connections" ]; then
        cp -a "$network_connections/." "$2/NetworkManager/system-connections/"
    fi
    # `cp -a DIR/. DEST/` can apply the authored root directory's mode to
    # DEST. Reassert NetworkManager's keyfile-directory requirement after the
    # copy, not merely when the data skeleton is first created.
    install -d -m0700 -o root -g root "$2/NetworkManager/system-connections"
}

replace_data_fstab_single() { # $1=root mount; $2=data PARTUUID
    local data_partuuid=$2 fstab="$1/etc/fstab" temporary
    temporary="$fstab.micropanel-touch"
    grep -vE '[[:space:]](/data|/etc/NetworkManager/system-connections)[[:space:]]' \
        "$fstab" > "$temporary" || true
    {
        printf '\n# MicroPanel Touch persistent state (must not block boot if damaged).\n'
        printf 'PARTUUID=%s /data ext4 defaults,nofail,x-systemd.device-timeout=5s 0 2\n' \
            "$data_partuuid"
        printf '%s\n' '/data/NetworkManager/system-connections /etc/NetworkManager/system-connections none bind,nofail,x-systemd.requires=data.mount,x-systemd.before=NetworkManager.service 0 0'
    } >> "$temporary"
    mv "$temporary" "$fstab"
}

replace_ab_fstab() { # $1=root mount
    local fstab="$1/etc/fstab" temporary
    temporary="$fstab.micropanel-touch"
    awk '$2 == "/" || $2 == "/boot/firmware" || $2 == "/data" || $2 == "/etc/NetworkManager/system-connections" {next} {print}' \
        "$fstab" > "$temporary"
    printf '\n# MicroPanel Touch A/B layout. Labels keep each slot independent of partition numbering.\n' >> "$temporary"
    printf '%s\n' \
        'LABEL=MP_BOOT_A /boot/firmware vfat defaults,ro,nofail,x-systemd.device-timeout=5s 0 2' \
        'LABEL=MICROPANEL_DATA /data ext4 defaults,nofail,x-systemd.device-timeout=5s 0 2' \
        '/data/NetworkManager/system-connections /etc/NetworkManager/system-connections none bind,nofail,x-systemd.requires=data.mount,x-systemd.before=NetworkManager.service 0 0' \
        >> "$temporary"
    mv "$temporary" "$fstab"
}

set_cmdline_root_label() { # $1=cmdline path; $2=filesystem label
    local cmdline=$1 label=$2 before after
    [ -f "$cmdline" ] || { echo "ERROR: missing cmdline: $cmdline" >&2; exit 1; }
    before=$(cat "$cmdline")
    after=$(printf '%s\n' "$before" | sed -E "s#(^|[[:space:]])root=[^[:space:]]+#\\1root=LABEL=${label}#")
    if [ "$after" = "$before" ] && ! grep -Eq '(^|[[:space:]])root=' "$cmdline"; then
        after="${before} root=LABEL=${label}"
    fi
    printf '%s\n' "$after" > "$cmdline"
}

write_watchdog_config() { # $1=root mount
    install -d "$1/etc/systemd/system.conf.d"
    cat > "$1/etc/systemd/system.conf.d/90-micropanel-touch-watchdog.conf" <<'EOF'
[Manager]
# Stage 0 verified that PID 1 owns the BCM2835 watchdog and resets a wedged
# tryboot candidate after this interval.  Do not add a test/fault service.
RuntimeWatchdogSec=20s
EOF
}

append_ab_manifest() { # $1=root mount
    local manifest="$1/opt/micropanel-touch/share/micropanel-touch/image-manifest.env"
    local temporary
    [ -f "$manifest" ] || {
        echo "ERROR: required MicroPanel Touch image manifest is missing: $manifest" >&2
        exit 1
    }
    temporary="$manifest.micropanel-touch"
    grep -vE '^(IMAGE_LAYOUT|SLOT_COMPATIBLE_BOARDS)=' "$manifest" > "$temporary" || true
    printf 'IMAGE_LAYOUT=ab\nSLOT_COMPATIBLE_BOARDS=%s\n' "$slot_compatible_boards" >> "$temporary"
    mv "$temporary" "$manifest"
}

verify_installed_app_revision() { # $1=root mount
    local manifest="$1/opt/micropanel-touch/share/micropanel-touch/image-manifest.env" actual_revision
    [ -n "$expected_micropanel_touch_revision" ] || return 0
    actual_revision=$(awk -F= '$1 == "MICROPANEL_TOUCH_REVISION" { print $2; exit }' "$manifest" 2>/dev/null || true)
    [ "$actual_revision" = "$expected_micropanel_touch_revision" ] || {
        echo "ERROR: installed MicroPanel Touch revision ${actual_revision:-missing} does not match requested $expected_micropanel_touch_revision" >&2
        exit 1
    }
}

safe_e2fsck() { # $1=device
    local status
    set +e
    e2fsck -pf "$1"
    status=$?
    set -e
    case "$status" in
        0|1) ;;
        *) echo "ERROR: e2fsck failed for $1 (status $status)" >&2; exit 1 ;;
    esac
}

clone_and_expand_ext4() { # $1=source; $2=target; $3=label
    local source=$1 target=$2 label=$3
    [ "$(blockdev --getsize64 "$source")" -le "$(blockdev --getsize64 "$target")" ] || {
        echo "ERROR: source filesystem is larger than target slot: $source" >&2
        exit 1
    }
    dd if="$source" of="$target" bs=4M status=none conv=fsync
    safe_e2fsck "$target"
    resize2fs "$target" >/dev/null
    e2label "$target" "$label"
}

finalize_single_layout() {
    local partition_lines partition_count root_partition root_start root_size
    local sector_size data_bytes total_sectors root_end data_start data_size
    local data_device root_device data_partuuid

    partition_lines=$(image_partition_lines "$image_path")
    partition_count=$(printf '%s\n' "$partition_lines" | sed '/^$/d' | wc -l)
    [ "$partition_count" -eq 2 ] || {
        echo "ERROR: expected exactly boot and root partitions before adding data; found $partition_count" >&2
        exit 1
    }
    root_partition=$(printf '%s\n' "$partition_lines" | tail -n 1)
    root_start=$(printf '%s\n' "$root_partition" | sed -n 's/.*start=[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    root_size=$(printf '%s\n' "$root_partition" | sed -n 's/.*size=[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    [[ "$root_start" =~ ^[0-9]+$ && "$root_size" =~ ^[1-9][0-9]*$ ]] || {
        echo "ERROR: unable to parse root partition geometry" >&2
        exit 1
    }
    sector_size=$(fdisk -l "$image_path" | sed -n 's/^Sector size (logical\/physical): \([0-9][0-9]*\).*/\1/p')
    [[ "$sector_size" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: unable to determine image sector size" >&2; exit 1; }

    data_bytes=$((data_partition_mb * 1024 * 1024))
    truncate -s "+$((data_bytes + alignment_sectors * sector_size))" "$image_path"
    total_sectors=$(( $(stat -c %s "$image_path") / sector_size ))
    root_end=$((root_start + root_size))
    data_start=$(( (root_end + alignment_sectors - 1) / alignment_sectors * alignment_sectors ))
    data_size=$((total_sectors - data_start))
    if ! { [ "$data_size" -gt 0 ] && [ $((data_size * sector_size)) -ge "$data_bytes" ]; }; then
        echo "ERROR: image tail is too small for ${data_partition_mb}MiB data partition" >&2
        exit 1
    fi

    printf 'start=%s, size=%s, type=83\n' "$data_start" "$data_size" | sfdisk --append "$image_path"
    target_loop=$(losetup --find --show --partscan "$image_path")
    wait_for_partitions "$target_loop" 2 3
    data_device="${target_loop}p3"
    root_device="${target_loop}p2"

    mkfs.ext4 -F -L "$data_label" "$data_device" >/dev/null
    root_mount=$(mktemp -d)
    data_mount=$(mktemp -d)
    mount "$root_device" "$root_mount"
    mount "$data_device" "$data_mount"
    seed_data_skeleton "$root_mount" "$data_mount"
    seed_network_connections "$root_mount" "$data_mount"
    install_data_skeleton_tool "$root_mount"
    install -d -m0755 "$root_mount/data"

    data_partuuid=$(blkid -s PARTUUID -o value "$data_device")
    [ -n "$data_partuuid" ] || { echo "ERROR: unable to resolve data PARTUUID" >&2; exit 1; }
    replace_data_fstab_single "$root_mount" "$data_partuuid"

    sync
    echo "Created ${data_partition_mb}MiB persistent data partition: $data_device ($data_partuuid)"
}

copy_slot_boot_tree() { # $1=source boot mount; $2=destination boot mount; $3=slot
    local source_boot=$1 slot=$3 slot_dir="$2/$3"
    [ ! -e "$slot_dir" ] || {
        echo "ERROR: source boot tree unexpectedly already has slot directory $slot" >&2
        exit 1
    }
    install -d "$slot_dir"
    # Keep a byte-for-byte boot-tree copy for now. os_prefix consumes only
    # the kernel, initramfs, DTB/overlays and cmdline, but pruning needs an
    # explicit inventory for every Pi OS kernel packaging change. The selector
    # renders only p1/config.txt and p1/tryboot.txt, so the copied per-slot
    # config.txt is deliberately never authoritative.
    cp -a "$source_boot/." "$slot_dir/"
    set_cmdline_root_label "$slot_dir/cmdline.txt" "MP_ROOT_$slot"
}

render_boot_selector() { # $1=root mount; $2=boot mount; $3=selector command; $4=slot; $5=destination
    local root=$1 boot=$2 selector_command=$3 slot=$4 destination=$5
    MICROPANEL_BOOT_CONFIG_TEMPLATE="$root/usr/lib/micropanel-touch/boot-selector-config.base" \
        "$root/usr/local/sbin/micropanel-touch-slot-selector" \
        "$selector_command" "$slot" > "$boot/$destination"
}

finalize_ab_layout() {
    local partition_count source_root source_boot
    local target_size_bytes total_sectors sectors_per_mib
    local boot_size root_size factory_size p1_start p2_start extended_start
    local p5_start p6_start p7_start p8_start data_size extended_size source_sector_size

    positive_integer "$ab_image_size_mb" || {
        echo "ERROR: AB_IMAGE_SIZE_MB must be a positive integer" >&2
        exit 1
    }
    partition_count=$(image_partition_lines "$image_path" | sed '/^$/d' | wc -l)
    [ "$partition_count" -eq 2 ] || {
        echo "ERROR: A/B layout expects the authored apps image (boot and root); found $partition_count partitions" >&2
        exit 1
    }
    [ -x "$data_skeleton_script" ] || { echo "ERROR: data skeleton script is not executable: $data_skeleton_script" >&2; exit 1; }
    [ -x "$selector_script" ] || { echo "ERROR: selector script is not executable: $selector_script" >&2; exit 1; }
    source_sector_size=$(fdisk -l "$image_path" | sed -n 's/^Sector size (logical\/physical): \([0-9][0-9]*\).*/\1/p')
    [ "$source_sector_size" = 512 ] || {
        echo "ERROR: A/B MBR layout requires 512-byte sectors; source reports ${source_sector_size:-unknown}" >&2
        exit 1
    }

    target_size_bytes=$((ab_image_size_mb * 1024 * 1024))
    sectors_per_mib=$((1024 * 1024 / 512))
    total_sectors=$((target_size_bytes / 512))
    boot_size=$((ab_boot_partition_mb * sectors_per_mib))
    root_size=$((ab_root_partition_mb * sectors_per_mib))
    factory_size=$((ab_factory_partition_mb * sectors_per_mib))
    p1_start=$alignment_sectors
    p2_start=$((p1_start + boot_size))
    extended_start=$((p2_start + boot_size))
    p5_start=$((extended_start + alignment_sectors))
    # Each logical partition after p5 needs room for its own EBR. Preserve a
    # full alignment window rather than placing an EBR against filesystem data.
    p6_start=$((p5_start + root_size + alignment_sectors))
    p7_start=$((p6_start + root_size + alignment_sectors))
    p8_start=$((p7_start + factory_size + alignment_sectors))
    data_size=$((total_sectors - p8_start))
    extended_size=$((total_sectors - extended_start))
    [ "$data_size" -gt "$alignment_sectors" ] || {
        echo "ERROR: AB_IMAGE_SIZE_MB leaves no usable MICROPANEL_DATA partition" >&2
        exit 1
    }

    source_loop=$(losetup --find --show --partscan --read-only "$image_path")
    wait_for_partitions "$source_loop" 1 2
    source_boot="${source_loop}p1"
    source_root="${source_loop}p2"
    [ "$(blockdev --getsize64 "$source_root")" -le $((ab_root_partition_mb * 1024 * 1024)) ] || {
        echo "ERROR: authored root does not fit the configured ${ab_root_partition_mb}MiB A/B slot" >&2
        exit 1
    }

    # sfdisk derives the partition-device spelling from the image filename.
    # Keep a nonnumeric suffix so its script uses image1/image5, not imagep1.
    ab_image_path="${image_path}.ab-layout.$$.img"
    [ ! -e "$ab_image_path" ] || { echo "ERROR: temporary A/B image path exists: $ab_image_path" >&2; exit 1; }
    truncate -s "$target_size_bytes" "$ab_image_path"
    sfdisk "$ab_image_path" <<EOF
label: dos
unit: sectors

${ab_image_path}1 : start=$p1_start, size=$boot_size, type=c, bootable
${ab_image_path}2 : start=$p2_start, size=$boot_size, type=c
${ab_image_path}3 : start=$extended_start, size=$extended_size, type=5
${ab_image_path}5 : start=$p5_start, size=$root_size, type=83
${ab_image_path}6 : start=$p6_start, size=$root_size, type=83
${ab_image_path}7 : start=$p7_start, size=$factory_size, type=83
${ab_image_path}8 : start=$p8_start, size=$data_size, type=83
EOF

    target_loop=$(losetup --find --show --partscan "$ab_image_path")
    wait_for_partitions "$target_loop" 1 2 5 6 7 8
    mkfs.vfat -F32 -n MP_BOOT_A "${target_loop}p1" >/dev/null
    mkfs.vfat -F32 -n MP_BOOT_B "${target_loop}p2" >/dev/null
    clone_and_expand_ext4 "$source_root" "${target_loop}p5" MP_ROOT_A
    mkfs.ext4 -F -L MP_ROOT_B "${target_loop}p6" >/dev/null
    mkfs.ext4 -F -L MP_FACTORY "${target_loop}p7" >/dev/null
    mkfs.ext4 -F -L "$data_label" "${target_loop}p8" >/dev/null

    source_boot_mount=$(mktemp -d)
    root_mount=$(mktemp -d)
    data_mount=$(mktemp -d)
    boot_mount=$(mktemp -d)
    mount -o ro "$source_boot" "$source_boot_mount"
    mount "${target_loop}p5" "$root_mount"
    mount "${target_loop}p8" "$data_mount"
    mount "${target_loop}p1" "$boot_mount"

    # A/ and B/ are the complete, independently updated boot trees used by
    # both normal and tryboot selectors. The flat p1 copies are retained only
    # as source material/recovery files; they are not a committed boot path.
    cp -a "$source_boot_mount/." "$boot_mount/"
    if ! { [ ! -e "$boot_mount/A" ] && [ ! -e "$boot_mount/B" ]; }; then
        echo "ERROR: source boot filesystem already contains A/ or B/" >&2
        exit 1
    fi
    set_cmdline_root_label "$boot_mount/cmdline.txt" MP_ROOT_A
    copy_slot_boot_tree "$source_boot_mount" "$boot_mount" A
    copy_slot_boot_tree "$source_boot_mount" "$boot_mount" B
    grep -Eq '^[[:space:]]*os_prefix=' "$boot_mount/config.txt" && {
        echo "ERROR: source config.txt already selects an os_prefix" >&2
        exit 1
    }
    grep -Eq '^[[:space:]]*\[tryboot\]' "$boot_mount/config.txt" && {
        echo "ERROR: source config.txt already contains a tryboot section" >&2
        exit 1
    }
    install -D -m0644 "$boot_mount/config.txt" \
        "$root_mount/usr/lib/micropanel-touch/boot-selector-config.base"
    install -Dm0755 "$selector_script" "$root_mount/usr/local/sbin/micropanel-touch-slot-selector"
    render_boot_selector "$root_mount" "$boot_mount" render-normal A config.txt
    render_boot_selector "$root_mount" "$boot_mount" render-candidate B tryboot.txt

    # The apps image has no /data partition yet. Seed the exact same durable
    # first-boot contract as the single-slot finalizer, including any shipped
    # NetworkManager keyfiles; a bare empty ext4 filesystem is not sufficient.
    seed_data_skeleton "$root_mount" "$data_mount"
    seed_network_connections "$root_mount" "$data_mount"
    install_data_skeleton_tool "$root_mount"
    install -d -m0755 "$root_mount/data"
    replace_ab_fstab "$root_mount"
    write_watchdog_config "$root_mount"
    append_ab_manifest "$root_mount"
    verify_installed_app_revision "$root_mount"

    sync
    unmount_if_mounted "$data_mount"
    unmount_if_mounted "$root_mount"
    unmount_if_mounted "$boot_mount"
    unmount_if_mounted "$source_boot_mount"
    losetup -d "$target_loop"; target_loop=""
    losetup -d "$source_loop"; source_loop=""
    rmdir "$data_mount" "$root_mount" "$boot_mount" "$source_boot_mount" 2>/dev/null || true
    data_mount=""; root_mount=""; boot_mount=""; source_boot_mount=""
    mv -f "$ab_image_path" "$image_path"
    ab_image_path=""
    echo "Created A/B image layout: ${ab_boot_partition_mb}MiB boot slots, ${ab_root_partition_mb}MiB roots, ${ab_factory_partition_mb}MiB factory reserve, data remainder"
}

if [ "$ab_layout" = 1 ]; then
    finalize_ab_layout
else
    [ -x "$data_skeleton_script" ] || { echo "ERROR: data skeleton script is not executable: $data_skeleton_script" >&2; exit 1; }
    finalize_single_layout
fi
