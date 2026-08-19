#!/bin/sh
set -eu

handler=$1

# The real acceptance writes a payload to the inactive partition on the Pi.
# Pin the non-negotiable streaming, bundle-order and selector ordering here for
# every build.
grep -Fq 'mount -o ro,nosuid,nodev,noexec -- "$1" "$source_mount"' "$handler"
grep -Fq 'case "$fstype" in vfat|exfat) ;; *) continue ;; esac' "$handler"
grep -Fq '"$lsblk_command" -P -o PATH,TYPE,TRAN,FSTYPE,PKNAME' "$handler"
grep -Fq 'lsblk_command=${AB_LSBLK:-lsblk}' "$handler"
# The engine reads its product-specific values from a board-authored config and
# never sources it as shell.
grep -Fq 'ab_config=${AB_UPDATE_CONFIG:-/usr/lib/pi-ab-update/ab-update.conf}' "$handler"
grep -Fq 'ab_config_value()' "$handler"
grep -Fq 'ab_setting()' "$handler"
! grep -Eq '(^|[[:space:]])(\.|source)[[:space:]]+"?\$ab_config' "$handler"
! grep -Eq 'micropanel|MicroPanel' "$handler"
grep -Fq 'bundle_extension=.mpupdate' "$handler"
grep -Fq "die payload 'USB media must contain exactly one update bundle'" "$handler"
grep -Fq "die payload 'no update bundle was found on the USB media'" "$handler"
grep -Fq 'target_root=$(resolve_target_root "$running_slot")' "$handler"
grep -Fq 'dd if=/dev/zero of="$target_root" bs=1M count=1 conv=fsync status=none' "$handler"
grep -Fq '            ./) continue ;;' "$handler"
grep -Fq '            ..|../*|*/..|*/../*|*//*|cmdline.txt|cmdline.txt/)' "$handler"
grep -Fq 'xz --memlimit-decompress=80MiB --decompress --stdout' "$handler"
grep -Fq 'tee "$hash_fifo" "$count_fifo"' "$handler"
grep -Fq '[ "$rootfs_sha256" = "${payload[rootfs_sha256]}" ] || die' "$handler"
grep -Fq 'e2label "$target_root" "MP_ROOT_${target_slot}"' "$handler"
grep -Fq 'boot cmdline template must contain exactly one line' "$handler"
grep -Fq 'write_update_progress "failed-${class}" 0' "$handler"
grep -Fq 'write_update_progress failed-internal 0' "$handler"
grep -Fq 'source|integrity|compatibility|payload|version|stall|boot|target|selector|image|internal' "$handler"
! grep -Fq 'failure_class()' "$handler"
grep -Fq "die target 'refusing to overwrite a mounted root partition'" "$handler"
grep -Fq "die image 'running image manifest is unavailable'" "$handler"
grep -Fq 'ab_setting "${AB_LOWER_ROOT_MOUNT:-}" AB_LOWER_ROOT_MOUNT /media/root-ro' "$handler"
grep -Fq "ab_setting \"\${AB_ROOT_PARENT_PATTERN:-}\" AB_ROOT_PARENT_PATTERN '^mmcblk[0-9]+\$'" "$handler"
grep -Fq 'reboot_command=${AB_REBOOT_COMMAND:-/usr/sbin/reboot}' "$handler"
grep -Fq 'acquire_update_lock()' "$handler"
grep -Fq 'flock -n "$lock_fd"' "$handler"
grep -Fq 'cmdline.txt.template' "$handler"
grep -Fq '"$selector" arm-candidate "$target_slot"' "$handler"
grep -Fq '"$reboot_command" "0 tryboot"' "$handler"

# Stage 2b format contract: exactly these members, in exactly this order, with
# the manifest first so a wrong or already-installed release aborts after a few
# kilobytes and the multi-gigabyte rootfs is always last.
grep -Fq 'bundle_manifest_member=manifest' "$handler"
grep -Fq 'bundle_signature_member=manifest.sig' "$handler"
grep -Fq 'bundle_boot_member=boot.tar' "$handler"
grep -Fq 'bundle_rootfs_member=rootfs.img.xz' "$handler"
grep -Fq '[ "${payload[format]}" = 2 ] || die payload' "$handler"
grep -Fq "die payload 'update bundle must start with its manifest'" "$handler"
grep -Fq "die payload 'update bundle members are out of order'" "$handler"
grep -Fq "die payload 'update bundle has a member after its root filesystem'" "$handler"
grep -Fq "die version 'the running system already has this release version'" "$handler"
grep -Fq 'ab_setting "${AB_STALL_SECONDS:-}" AB_STALL_SECONDS 300' "$handler"
grep -Fq "die stall 'root filesystem stream stopped making progress'" "$handler"
# The reader is single-pass and pipe-capable so Stage 4 is `curl | reader`.
grep -Fq 'iflag=fullblock' "$handler" || {
    echo 'ERROR: bundle reader must read exact byte counts with iflag=fullblock' >&2
    exit 1
}
grep -Fq 'stream_exact_bytes() {' "$handler"
grep -Fq 'skip_member_padding() {' "$handler"
grep -Fq 'header_checksum_matches()' "$handler"
grep -Fq "die payload 'update bundle is not a ustar archive'" "$handler"
grep -Fq "die payload 'update bundle member uses a prefixed path'" "$handler"
grep -Fq "die payload 'update bundle contains a non-regular member'" "$handler"
! grep -Fq 'tar -xOf' "$handler"
! grep -Fq 'update_usb_source=/dev/disk/by-label/MP_UPDATE' "$handler"
! grep -Fq 'MICROPANEL_LOCAL_UPDATE_ROOT' "$handler"

manifest_line=$(grep -nF '[ "$member_name" = "$bundle_manifest_member" ] || die' "$handler" | cut -d: -f1)
signature_line=$(grep -nF 'if [ "$member_name" = "$bundle_signature_member" ]; then' "$handler" | cut -d: -f1)
boot_line=$(grep -nF '[ "$member_name" = "$bundle_boot_member" ] || die' "$handler" | cut -d: -f1)
rootfs_line=$(grep -nF '[ "$member_name" = "$bundle_rootfs_member" ] || die' "$handler" | cut -d: -f1)
version_line=$(grep -nF 'die version ' "$handler" | cut -d: -f1)
hash_line=$(grep -nF '[ "$rootfs_sha256" = "${payload[rootfs_sha256]}" ] || die' "$handler" | cut -d: -f1)
label_line=$(grep -nF 'e2label "$target_root" "MP_ROOT_${target_slot}"' "$handler" | cut -d: -f1)
arm_line=$(grep -nF '"$selector" arm-candidate "$target_slot"' "$handler" | cut -d: -f1)
[ "$manifest_line" -lt "$signature_line" ]
[ "$signature_line" -lt "$boot_line" ]
[ "$boot_line" -lt "$rootfs_line" ]
# Manifest-first early abort: the same-version refusal precedes the boot and
# rootfs members, so nothing large is ever transferred for a known release.
[ "$version_line" -lt "$boot_line" ]
[ "$hash_line" -lt "$label_line" ]
[ "$label_line" -lt "$arm_line" ]

# V5-01: cleanup must disarm its own traps before doing any work.
cleanup_line=$(grep -nF 'cleanup() {' "$handler" | cut -d: -f1)
disarm_line=$(grep -nF 'trap - EXIT HUP INT TERM' "$handler" | cut -d: -f1)
umount_line=$(grep -nF '[ "$source_was_mounted" != 1 ] || umount "$source_mount" || true' "$handler" | cut -d: -f1)
[ "$cleanup_line" -lt "$disarm_line" ]
[ "$disarm_line" -lt "$umount_line" ]

# Every mount and unmount on the discovery path carries an explicit failure
# class. Unguarded, set -e reaches cleanup and publishes the generic internal
# class for what is plainly a source problem.
grep -Fq "die source 'unable to mount the USB filesystem holding the update bundle'" "$handler"
grep -Fq "die source 'unable to release a scanned USB filesystem'" "$handler"
! grep -Eq '^ *mount_source_device "\$\{found_devices\[0\]\}"$' "$handler"

# A failed-internal must at least be diagnosable from the root-only journal.
grep -Fq 'set -Eeuo pipefail' "$handler"
grep -Fq "internal_failure_context=\"line \${LINENO}: \${BASH_COMMAND}\"" "$handler"
grep -Fq 'log_diagnostic()' "$handler"
grep -Fq 'logger -t "ab-system-update[$product]"' "$handler"
grep -Fq 'unexpected failure${internal_failure_context:+ at $internal_failure_context}' "$handler"

# O-01: the bundle descriptors are released before cleanup unmounts, otherwise
# the open file keeps the filesystem busy and the mount strands inside the
# broker's PrivateTmp namespace, holding the USB device.
close_line=$(grep -nF 'exec 3<&- 2>/dev/null || true' "$handler" | head -1 | cut -d: -f1)
cleanup_umount_line=$(grep -nF '[ "$source_was_mounted" != 1 ] || umount "$source_mount" || true' "$handler" | cut -d: -f1)
[ "$close_line" -lt "$cleanup_umount_line" ]
grep -Fq 'kill -TERM "$stream_pid"' "$handler"

# O-03: a selector that runs and fails is a selector failure, not an internal one.
grep -Fq "die selector 'slot selector failed to report the running slot'" "$handler"

# V5-02: a stranded mountpoint is reclaimed only by the update-lock owner.
grep -Fq 'reclaim_stale_source_mount()' "$handler"
grep -Fq "die internal 'refusing to reclaim a source mount without the update lock'" "$handler"

# V5-03: the lock is acquired before anything can publish progress, and the
# publisher itself refuses to write without it.
lock_call_line=$(grep -nFx 'acquire_update_lock' "$handler" | cut -d: -f1)
first_publish_line=$(grep -nF 'write_update_progress validating 0' "$handler" | cut -d: -f1)
image_die_line=$(grep -nF "die image 'running image manifest is unavailable'" "$handler" | cut -d: -f1)
[ "$lock_call_line" -lt "$first_publish_line" ]
[ "$first_publish_line" -lt "$image_die_line" ]
grep -Fq '[ "$lock_held" -eq 1 ] || return 0' "$handler"

# The rootfs transfer cannot regress to a RAM-backed staging path.
! grep -Eq '(^|[[:space:]])(/tmp|\$TMPDIR|\${TMPDIR)' "$handler"

# Failure phases are explicit protocol values, not a by-product of matching an
# error sentence. Exercise the running-image edge that previously blamed USB.
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
selector="$temporary_directory/selector"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" A' > "$selector"
chmod 0755 "$selector"
if AB_SLOT_SELECTOR="$selector" \
    AB_IMAGE_MANIFEST="$temporary_directory/missing-image-manifest" \
    AB_RUNTIME_DIR="$temporary_directory/runtime" \
    /bin/bash "$handler" usb >/dev/null 2>&1; then
    echo 'ERROR: handler accepted a missing running image manifest' >&2
    exit 1
fi
grep -Fqx 'phase=failed-image' "$temporary_directory/runtime/progress"

printf '%s\n' 'system-update-handler-policy: PASS'
