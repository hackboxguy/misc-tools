#!/bin/bash
# Exercise the real Stage 2b handler against disposable loop partitions. This
# verifies bundle-read -> stream -> hash -> e2fsck -> relabel -> boot render ->
# selector arm without a Pi or a real reboot, through both source paths:
#
#   * `stdin`, a pipe — the Stage 4 OTA path in miniature; and
#   * `usb`, real read-only mounts of FAT32 (and exFAT where the host kernel
#     supports it) filesystems presented through the handler's block-device
#     inventory seam.
#
# Run as root; ordinary ctest users skip it.
set -euo pipefail

handler=${1:?handler path is required}

if [ "$(id -u)" -ne 0 ]; then
    echo 'SKIP: system update handler integration requires root loop/mount access'
    exit 77
fi

for tool in truncate sfdisk losetup mkfs.vfat mkfs.ext4 mount umount mountpoint \
            install dd xz sha256sum stat tar awk grep sync e2label findmnt lsblk \
            blockdev flock sleep seq; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: missing test tool: $tool" >&2
        exit 1
    }
done
real_lsblk=$(command -v lsblk)

work=$(mktemp -d)
image="$work/handler-fixture.img"
loop=""
usb_loops=()
boot_mount="$work/boot"
lower_root_mount="$work/lower-root"
target_root_mount="$work/target-root"
usb_stage="$work/usb-stage"

unmount_if_mounted() {
    local directory=$1
    [ -n "$directory" ] && mountpoint -q "$directory" && umount "$directory"
}

cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    unmount_if_mounted "$work/runtime/source" || true
    unmount_if_mounted "$usb_stage" || true
    unmount_if_mounted "$target_root_mount" || true
    unmount_if_mounted "$lower_root_mount" || true
    unmount_if_mounted "$boot_mount" || true
    local usb_loop
    for usb_loop in ${usb_loops[@]+"${usb_loops[@]}"}; do
        losetup -d "$usb_loop" 2>/dev/null || true
    done
    [ -z "$loop" ] || losetup -d "$loop" 2>/dev/null || true
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

# p5/p6 are logical partitions inside p4, matching the production A/B
# contract closely enough for lsblk PKNAME/PARTN resolution to be real.
truncate -s 320M "$image"
sfdisk "$image" >/dev/null <<EOF
label: dos
unit: sectors

${image}1 : start=2048, size=65536, type=c, bootable
${image}4 : start=67584, size=587776, type=5
${image}5 : start=69632, size=196608, type=83
# Each logical partition needs an EBR sector immediately before it.  Leave a
# 1 MiB gap after p5 so sfdisk can place the p6 EBR without overlapping p5.
${image}6 : start=268288, size=196608, type=83
EOF

loop=$(losetup --find --show --partscan "$image")
for _ in $(seq 1 20); do
    [ -b "${loop}p1" ] && [ -b "${loop}p5" ] && [ -b "${loop}p6" ] && break
    sleep 1
done
[ -b "${loop}p1" ] && [ -b "${loop}p5" ] && [ -b "${loop}p6" ] || {
    echo 'ERROR: handler fixture loop partitions did not appear' >&2
    exit 1
}

mkfs.vfat -F32 -n MP_BOOT_A "${loop}p1" >/dev/null
mkfs.ext4 -F -L MP_ROOT_A "${loop}p5" >/dev/null
mkfs.ext4 -F -L MP_ROOT_B "${loop}p6" >/dev/null
install -d "$boot_mount" "$lower_root_mount" "$target_root_mount" "$usb_stage"
mount "${loop}p1" "$boot_mount"
mount "${loop}p5" "$lower_root_mount"
printf '%s\n' 'handler integration root marker' > "$lower_root_mount/payload-marker"
sync
umount "$lower_root_mount"
mount -o ro "${loop}p5" "$lower_root_mount"

install -d "$boot_mount/A" "$boot_mount/B"

# ---------------------------------------------------------------------------
# Build one format=2 bundle exactly as the release generator publishes it.
# ---------------------------------------------------------------------------
install -d "$work/bundle" "$work/payload-boot"
printf '%s\n' \
    'console=tty1 root=LABEL=@MICROPANEL_SLOT@ rootfstype=ext4 rootwait overlayroot=tmpfs:recurse=0' \
    > "$work/payload-boot/cmdline.txt.template"
printf '%s\n' 'fixture kernel' > "$work/payload-boot/kernel8.img"
tar --format=posix --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
    -C "$work/payload-boot" -cf "$work/bundle/boot.tar" .

# The source rootfs must be label-neutral exactly as a published payload is.
rootfs_raw="$work/rootfs.img"
dd if="${loop}p5" of="$rootfs_raw" bs=1M status=none
e2label "$rootfs_raw" ""
rootfs_bytes=$(stat -c %s "$rootfs_raw")
rootfs_sha256=$(sha256sum "$rootfs_raw" | awk '{print $1}')
xz --threads=0 --check=crc64 --lzma2=dict=16MiB --stdout "$rootfs_raw" > "$work/bundle/rootfs.img.xz"
rm -f "$rootfs_raw"
boot_sha256=$(sha256sum "$work/bundle/boot.tar" | awk '{print $1}')
printf '%s\n' \
    'version=fixture' \
    'variant=luckfox-ctp' \
    'boards=pi4' \
    "rootfs_sha256=$rootfs_sha256" \
    "rootfs_bytes=$rootfs_bytes" \
    "boot_sha256=$boot_sha256" \
    'format=2' > "$work/bundle/manifest"
# The reserved signature member is present in every published bundle. Stage 2b
# accepts and ignores it; Stage 4 verifies it against the pinned public key.
printf 'reserved format=2 signature member\n' > "$work/bundle/manifest.sig"
chmod 0644 "$work/bundle"/*
tar --format=ustar --owner=0 --group=0 --numeric-owner --mtime=@0 \
    -C "$work/bundle" -cf "$work/micropanel-touch-luckfox-ctp.mpupdate" \
    manifest manifest.sig boot.tar rootfs.img.xz
bundle="$work/micropanel-touch-luckfox-ctp.mpupdate"

# A bundle whose decompressed rootfs differs from its manifest digest by one
# byte, with every other member left untouched.
install -d "$work/corrupt"
cp "$work/bundle/manifest" "$work/bundle/manifest.sig" "$work/bundle/boot.tar" "$work/corrupt/"
xz --decompress --stdout "$work/bundle/rootfs.img.xz" > "$work/corrupt/rootfs.img"
printf 'X' | dd of="$work/corrupt/rootfs.img" bs=1 seek=$((rootfs_bytes / 2)) conv=notrunc status=none
xz --threads=0 --check=crc64 --lzma2=dict=16MiB --stdout "$work/corrupt/rootfs.img" \
    > "$work/corrupt/rootfs.img.xz"
rm -f "$work/corrupt/rootfs.img"
chmod 0644 "$work/corrupt"/*
tar --format=ustar --owner=0 --group=0 --numeric-owner --mtime=@0 \
    -C "$work/corrupt" -cf "$work/corrupt.mpupdate" \
    manifest manifest.sig boot.tar rootfs.img.xz

# ---------------------------------------------------------------------------
# Fixtures the handler talks to instead of the real appliance.
# ---------------------------------------------------------------------------
image_manifest="$work/image-manifest.env"
printf '%s\n' \
    'IMAGE_LAYOUT=ab' \
    'PANEL_VARIANT=luckfox-ctp' \
    'SLOT_COMPATIBLE_BOARDS=pi4' \
    'IMAGE_VERSION=fixture-running' > "$image_manifest"

selector="$work/selector"
selector_log="$work/selector.log"
printf '%s\n' \
    '#!/bin/sh' \
    'case "$1" in' \
    '  current-slot) printf "%s\\n" A ;;' \
    '  arm-candidate) [ "$2" = B ] && printf "%s %s\\n" "$1" "$2" > "$SELECTOR_LOG" ;;' \
    '  *) exit 64 ;;' \
    'esac' > "$selector"
chmod 0755 "$selector"

reboot_command="$work/reboot"
reboot_log="$work/reboot.log"
printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s\\n" "$*" > "$REBOOT_LOG"' > "$reboot_command"
chmod 0755 "$reboot_command"

# The handler resolves its own block-device inventory. Present a synthetic one
# for the USB scan and delegate every other query to the real tool.
fake_lsblk="$work/fake-lsblk"
lsblk_records="$work/lsblk-records"
cat > "$fake_lsblk" <<FAKE
#!/bin/sh
if [ "\$1" = -P ] && [ "\$2" = -o ] && [ "\$3" = PATH,TYPE,TRAN,FSTYPE,PKNAME ]; then
    cat "$lsblk_records"
    exit 0
fi
exec "$real_lsblk" "\$@"
FAKE
chmod 0755 "$fake_lsblk"
: > "$lsblk_records"

state_dir="$work/state"
runtime_dir="$work/runtime"

run_handler() { # $1=source enum; stdin is the bundle for the `stdin` source
    SELECTOR_LOG="$selector_log" \
    REBOOT_LOG="$reboot_log" \
    AB_IMAGE_MANIFEST="$image_manifest" \
    AB_SLOT_SELECTOR="$selector" \
    AB_BOOT_DIR="$boot_mount" \
    AB_STATE_DIR="$state_dir" \
    AB_RUNTIME_DIR="$runtime_dir" \
    AB_LOWER_ROOT_MOUNT="$lower_root_mount" \
    AB_ROOT_PARENT_PATTERN='^loop[0-9]+$' \
    AB_REBOOT_COMMAND="$reboot_command" \
    AB_LSBLK="$fake_lsblk" \
    AB_BOARD=pi4 \
        /bin/bash "$handler" "$1"
}

reset_target() {
    rm -f "$selector_log" "$reboot_log"
    rm -rf "$state_dir"
    e2label "${loop}p6" MP_ROOT_STALE
    rm -rf "$boot_mount/B"
    install -d "$boot_mount/B"
    printf '%s\n' 'old inactive boot tree' > "$boot_mount/B/obsolete"
    sync
}

assert_candidate_armed() { # $1=case label
    [ "$(e2label "${loop}p6")" = MP_ROOT_B ] || {
        echo "ERROR: $1 left the inactive slot label as $(e2label "${loop}p6")" >&2
        exit 1
    }
    mount -o ro "${loop}p6" "$target_root_mount"
    grep -Fqx 'handler integration root marker' "$target_root_mount/payload-marker"
    unmount_if_mounted "$target_root_mount"
    grep -Fqx 'root=LABEL=MP_ROOT_B' <(tr ' ' '\n' < "$boot_mount/B/cmdline.txt")
    test ! -e "$boot_mount/B/cmdline.txt.template"
    test ! -e "$boot_mount/B/obsolete"
    grep -Fqx 'state=candidate-armed' "$state_dir/update-state"
    grep -Fqx 'candidate_slot=B' "$state_dir/update-state"
    grep -Fqx 'version=fixture' "$state_dir/update-state"
    grep -Fqx 'arm-candidate B' "$selector_log"
    grep -Fqx '0 tryboot' "$reboot_log"
    grep -Fqx 'phase=arming' "$runtime_dir/progress"
    grep -Fqx 'progress=100' "$runtime_dir/progress"
    printf '  ok  %s\n' "$1"
}

expect_failure() { # $1=case label $2=expected phase $3=source enum [stdin file]
    local label=$1 phase=$2 source=$3 input=${4:-/dev/null}
    if run_handler "$source" < "$input" >/dev/null 2>&1; then
        echo "ERROR: $label was accepted" >&2
        exit 1
    fi
    grep -Fqx "phase=$phase" "$runtime_dir/progress" || {
        echo "ERROR: $label reported $(sed -n 's/^phase=//p' "$runtime_dir/progress") not $phase" >&2
        exit 1
    }
    [ ! -e "$selector_log" ] || { echo "ERROR: $label armed a candidate" >&2; exit 1; }
    [ ! -e "$reboot_log" ] || { echo "ERROR: $label rebooted" >&2; exit 1; }
    printf '  ok  %-46s -> %s\n' "$label" "$phase"
}

# Sets usb_loop_device. Deliberately not a command substitution: the loop
# device has to reach the parent shell's cleanup list, and a subshell's array
# append would not.
make_usb_filesystem() { # $1=image path $2=mkfs command
    local usb_image=$1
    truncate -s 96M "$usb_image"
    usb_loop_device=$(losetup --find --show "$usb_image")
    usb_loops+=("$usb_loop_device")
    "$2" "$usb_loop_device" >/dev/null 2>&1
}

publish_bundle_to_usb() { # $1=loop device $2=bundle file (or empty for none)
    mount "$1" "$usb_stage"
    rm -f "$usb_stage"/*.mpupdate
    if [ -n "$2" ]; then
        install -m0644 "$2" "$usb_stage/micropanel-touch-luckfox-ctp.mpupdate"
    fi
    sync
    umount "$usb_stage"
}

record_usb() { # remaining args are loop devices with a vfat/exfat filesystem
    local device
    : > "$lsblk_records"
    for device in "$@"; do
        printf 'PATH="%s" TYPE="disk" TRAN="usb" FSTYPE="%s" PKNAME=""\n' \
            "$device" "$(blkid -s TYPE -o value "$device")" >> "$lsblk_records"
    done
}

mkfs_vfat32() { mkfs.vfat -F32 "$1"; }

# --- 1. the pipe path (OTA in miniature) -----------------------------------
reset_target
run_handler stdin < "$bundle"
assert_candidate_armed 'bundle streamed through a pipe armed candidate B'

# --- 2. integrity refusal on the pipe path --------------------------------
reset_target
expect_failure 'one changed rootfs byte' failed-integrity stdin "$work/corrupt.mpupdate"
# The pre-stream superblock clear is deliberate: a refused or interrupted
# transfer must leave a dirty *unlabelled* target, never a second MP_ROOT_B.
[ "$(e2label "${loop}p6" 2>/dev/null || true)" != MP_ROOT_B ] || {
    echo 'ERROR: a refused payload relabelled the inactive slot' >&2
    exit 1
}

# --- 3. USB discovery refusal classes -------------------------------------
make_usb_filesystem "$work/usb-one.img" mkfs_vfat32
usb_one=$usb_loop_device
make_usb_filesystem "$work/usb-two.img" mkfs_vfat32
usb_two=$usb_loop_device

reset_target
record_usb
expect_failure 'no USB filesystem present' failed-source usb

reset_target
publish_bundle_to_usb "$usb_one" ''
record_usb "$usb_one"
expect_failure 'USB stick without a bundle' failed-payload usb

reset_target
publish_bundle_to_usb "$usb_one" "$bundle"
publish_bundle_to_usb "$usb_two" "$bundle"
record_usb "$usb_one" "$usb_two"
expect_failure 'two bundles across USB media' failed-payload usb

# --- 3b. O-01: a USB-source failure must not strand its mount -------------
# The bundle stays open on fd 0/3 for the whole run, and an open file keeps its
# filesystem busy. Before the fix, cleanup's unmount failed EBUSY, was swallowed
# by `|| true`, and left a mount holding an exclusive claim on the device.
reset_target
publish_bundle_to_usb "$usb_one" "$work/corrupt.mpupdate"
record_usb "$usb_one"
expect_failure 'corrupt bundle from USB media' failed-integrity usb
mountpoint -q "$runtime_dir/source" && {
    echo 'ERROR: a failed USB update stranded its source mount' >&2
    exit 1
}
grep -Fq "$usb_one" /proc/mounts && {
    echo 'ERROR: the USB device is still mounted somewhere after a failed update' >&2
    exit 1
}
# ...and the device must be free for an exclusive open again, which is what
# mkfs/wipefs need and what a stranded mount blocks.
python3 -c "
import os,sys
fd=os.open(sys.argv[1], os.O_RDONLY|os.O_EXCL); os.close(fd)
" "$usb_one" || {
    echo 'ERROR: the USB device is still exclusively claimed after a failed update' >&2
    exit 1
}
printf '  ok  %-46s -> %s\n' 'failed USB update leaves the device free' 'no stranded mount'
publish_bundle_to_usb "$usb_one" "$bundle"

# --- 4. FAT32 happy path, zero preparation --------------------------------
reset_target
record_usb "$usb_one"
run_handler usb
assert_candidate_armed 'unlabelled FAT32 stick armed candidate B'
mountpoint -q "$runtime_dir/source" && {
    echo 'ERROR: the handler left its USB source mounted' >&2
    exit 1
}

# --- 5. a stale source mountpoint is reclaimed under the lock (V5-02) ------
reset_target
install -d -m0700 "$runtime_dir/source"
mount -o ro "$usb_two" "$runtime_dir/source"
record_usb "$usb_one"
run_handler usb
assert_candidate_armed 'stale source mountpoint reclaimed'

# --- 6. exFAT happy path where the host kernel supports it ----------------
if command -v mkfs.exfat >/dev/null 2>&1; then
    make_usb_filesystem "$work/usb-exfat.img" mkfs.exfat
    usb_exfat=$usb_loop_device
    if mount -o ro "$usb_exfat" "$usb_stage" 2>/dev/null; then
        umount "$usb_stage"
        reset_target
        publish_bundle_to_usb "$usb_exfat" "$bundle"
        record_usb "$usb_exfat"
        run_handler usb
        assert_candidate_armed 'unlabelled exFAT stick armed candidate B'
    else
        echo '  skip  exFAT case: this host kernel cannot mount exfat'
    fi
else
    echo '  skip  exFAT case: mkfs.exfat is unavailable'
fi

echo 'system-update-handler-integration: PASS'
