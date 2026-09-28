#!/bin/bash
# The A/B finalizer's two ways into a root slot. A source partition that fits
# is block-cloned (test_ab_layout_integration.sh covers that path end to end).
# One larger than the slot - the build stages extend images for headroom, so
# the partition can be far larger than what it holds - is file-copied into a
# fresh filesystem when its used space fits, and refused when it does not.
#
# Root only: sudo tests/test_ab_root_copy.sh
set -Eeuo pipefail
trap 'status=$?; echo "FIXTURE FAILED: line ${LINENO}: ${BASH_COMMAND} (exit ${status})" >&2' ERR

engine=$(cd "$(dirname "$0")/.." && pwd)
finalizer="$engine/ab-finalize-layout.sh"
release_key_tool="$engine/ab-release-key.sh"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (loop devices, mounts, file capabilities)" >&2; exit 1; }
for tool in truncate sfdisk losetup mkfs.vfat mkfs.ext4 dumpe2fs e2fsck mount umount setcap getcap \
            setfattr getfattr setfacl getfacl fallocate stat; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing host tool: $tool" >&2; exit 1; }
done

work=$(mktemp -d)
loop=""
mnt="$work/mnt"
cleanup() {
    local status=$?
    mountpoint -q "$mnt" && umount "$mnt"
    [ -z "$loop" ] || losetup -d "$loop" 2>/dev/null || true
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM
install -d "$mnt"

attach() { # $1=image; sets $loop once its partitions are settled
    loop=$(losetup --find --show --partscan "$1")
    local retries=0
    while [ "$retries" -lt 20 ] && [ ! -b "${loop}p1" ]; do sleep 1; retries=$((retries + 1)); done
    # udev may still be re-reading the partition table of this (or the last)
    # loop device: a format racing it failed once in a full run-tests.sh pass.
    command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=10 >/dev/null 2>&1 || true
    [ -b "${loop}p1" ]
}
# One retry after a settle, for the same race.
settled() { "$@" || { udevadm settle --timeout=10 >/dev/null 2>&1 || true; sleep 1; "$@"; }; }
detach() { losetup -d "$loop"; loop=""; }

# A two-partition authored image: 32 MiB boot, $2 MiB root. The root is made
# the way an older e2fsprogs would make it (no orphan_file, no
# metadata_csum_seed), so the copy must not pick up the host's newer defaults.
make_source() { # $1=image $2=root MiB $3=bytes of incompressible filler to allocate
    local image=$1 root_mib=$2 filler=$3
    truncate -s $((34 + root_mib))M "$image"
    sfdisk -q "$image" <<EOF
label: dos
unit: sectors

${image}1 : start=2048, size=65536, type=c, bootable
${image}2 : start=67584, size=$((root_mib * 2048)), type=83
EOF
    attach "$image"
    settled mkfs.vfat -F32 -n SOURCE_BOOT "${loop}p1" >/dev/null
    settled mkfs.ext4 -F -q -L SOURCE_ROOT -O ^orphan_file,^metadata_csum_seed "${loop}p2"
    mount "${loop}p1" "$mnt"
    printf '%s\n' 'dtoverlay=vc4-kms-v3d' > "$mnt/config.txt"
    printf '%s\n' 'console=tty1 root=PARTUUID=fixture-02 rootwait overlayroot=tmpfs:recurse=0' > "$mnt/cmdline.txt"
    umount "$mnt"
    mount "${loop}p2" "$mnt"
    install -d "$mnt/etc/NetworkManager/system-connections" "$mnt/opt/fixture" "$mnt/usr/bin"
    printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' 'app:x:1234:1234::/nonexistent:/usr/sbin/nologin' > "$mnt/etc/passwd"
    printf '%s\n' 'PARTUUID=fixture-02 / ext4 defaults 0 1' > "$mnt/etc/fstab"
    printf '%s\n' 'IMAGE_VARIANT=base' > "$mnt/opt/fixture/image-manifest.env"
    # What a block clone kept and a careless file copy loses.
    printf '%s\n' 'ping stand-in' > "$mnt/usr/bin/fixture-ping"
    setcap cap_net_raw+ep "$mnt/usr/bin/fixture-ping"
    printf '%s\n' linked > "$mnt/opt/fixture/link-a"
    ln "$mnt/opt/fixture/link-a" "$mnt/opt/fixture/link-b"
    ln -s /opt/fixture/link-a "$mnt/opt/fixture/symlink"
    truncate -s 64M "$mnt/opt/fixture/sparse"
    printf '%s\n' acl > "$mnt/opt/fixture/acl"
    setfacl -m u:1234:rw "$mnt/opt/fixture/acl"
    setfattr -n user.fixture -v kept "$mnt/opt/fixture/acl"
    chown 1234:1234 "$mnt/opt/fixture/link-a"
    chmod 4750 "$mnt/opt/fixture/link-a"
    touch -d '2001-02-03 04:05:06' "$mnt/opt/fixture/acl"
    if [ "$filler" -gt 0 ]; then fallocate -l "$filler" "$mnt/opt/fixture/filler"; fi
    umount "$mnt"
    detach
}

skeleton="$work/skeleton.sh"
printf '%s\n' '#!/bin/sh' 'set -eu' 'install -d -m0700 "$2/NetworkManager/system-connections"' > "$skeleton"
chmod 0755 "$skeleton"
conf="$work/ab-update.conf"
printf '%s\n' 'AB_PRODUCT=fixture' 'AB_VARIANT_KEY=IMAGE_VARIANT' 'AB_HEALTH_UNITS=fixture.service' > "$conf"
release_key="$work/key/ed25519-release.key"
MICROPANEL_RELEASE_KEY="$release_key" "$release_key_tool" ensure >/dev/null 2>&1

finalize() { # $1=image; slots: 32 MiB boot, 512 MiB root, 32 MiB factory
    env -u DATA_PARTITION_MB IMAGE_PATH="$1" AB_LAYOUT=1 AB_IMAGE_SIZE_MB=1400 \
        AB_BOOT_PARTITION_MB=32 AB_ROOT_PARTITION_MB=512 AB_FACTORY_PARTITION_MB=32 \
        SLOT_COMPATIBLE_BOARDS=pi4 IMAGE_VERSION=fixture \
        UPDATE_SIGNING_PUBLIC_KEY="$release_key.pub" \
        UPDATE_RELEASE_URL_TEMPLATE='https://example.invalid/@ASSET@' \
        AB_PRODUCT=fixture AB_MANIFEST_PATH=/opt/fixture/image-manifest.env \
        AB_APP_ACCOUNT=app AB_UPDATE_CONF="$conf" DATA_SKELETON_SCRIPT="$skeleton" \
        "$finalizer"
}

# --- 1. oversized partition, contents fit: file copy ------------------------
image="$work/fits.img"
make_source "$image" 640 0
attach "$image"
source_features=$(dumpe2fs -h "${loop}p2" 2>/dev/null | sed -n 's/^Filesystem features:[[:space:]]*//p' | tr ' ' '\n' | sort)
detach
finalize "$image" > "$work/fits.log" 2>&1 || { cat "$work/fits.log" >&2; exit 1; }
grep -Fq 'root copy: file copy (source partition 640 MiB exceeds the 512 MiB slot;' "$work/fits.log"
echo '  ok  an oversized source partition whose contents fit is file-copied'
attach "$image"
[ -b "${loop}p5" ] || sleep 2
e2fsck -fn "${loop}p5" >/dev/null
target_features=$(dumpe2fs -h "${loop}p5" 2>/dev/null | sed -n 's/^Filesystem features:[[:space:]]*//p' | tr ' ' '\n' | sort)
[ "$target_features" = "$source_features" ] || {
    echo 'ERROR: the copied slot has a different ext4 feature set' >&2
    diff <(printf '%s\n' "$source_features") <(printf '%s\n' "$target_features") >&2; exit 1; }
! printf '%s\n' "$target_features" | grep -Eqx 'orphan_file|metadata_csum_seed' || {
    echo 'ERROR: the copy picked up the build host default features' >&2; exit 1; }
echo '  ok  the fresh filesystem has exactly the source feature set, no host defaults'
[ "$(dumpe2fs -h "${loop}p5" 2>/dev/null | sed -n 's/^Filesystem volume name:[[:space:]]*//p')" = MP_ROOT_A ]
mount -o ro "${loop}p5" "$mnt"
getcap "$mnt/usr/bin/fixture-ping" | grep -Fq 'cap_net_raw=ep'
[ "$(stat -c %i "$mnt/opt/fixture/link-a")" = "$(stat -c %i "$mnt/opt/fixture/link-b")" ]
[ "$(stat -c %h "$mnt/opt/fixture/link-a")" = 2 ]
[ "$(stat -c '%u:%g:%a' "$mnt/opt/fixture/link-a")" = '1234:1234:4750' ]
[ "$(readlink "$mnt/opt/fixture/symlink")" = /opt/fixture/link-a ]
[ "$(stat -c %b "$mnt/opt/fixture/sparse")" -lt 64 ]
getfacl -p "$mnt/opt/fixture/acl" 2>/dev/null | grep -Fqx 'user:1234:rw-'
[ "$(getfattr --only-values -n user.fixture "$mnt/opt/fixture/acl")" = kept ]
[ "$(stat -c %Y "$mnt/opt/fixture/acl")" = "$(date -d '2001-02-03 04:05:06' +%s)" ]
umount "$mnt"
detach
echo '  ok  capabilities, ACLs, xattrs, hard links, symlinks, sparseness, owners, modes and times survive'

# --- 2. oversized partition, contents do not fit: refused, source untouched --
image="$work/too-full.img"
make_source "$image" 640 $((300 * 1024 * 1024))
before=$(sha256sum "$image" | cut -d' ' -f1)
if finalize "$image" > "$work/too-full.log" 2>&1; then
    echo 'ERROR: a root whose contents cannot fit the slot was accepted' >&2; exit 1
fi
grep -Eq 'ERROR: authored root uses 3[0-9]{2} MiB; with a 256 MiB margin it does not fit the 512 MiB A/B slot' "$work/too-full.log" || {
    cat "$work/too-full.log" >&2; exit 1; }
[ "$(sha256sum "$image" | cut -d' ' -f1)" = "$before" ] || { echo 'ERROR: a refused finalize changed the source image' >&2; exit 1; }
[ -z "$(losetup -j "$image")" ] || { echo 'ERROR: a refused finalize left a loop device behind' >&2; exit 1; }
echo '  ok  contents that do not fit are refused with the reason, and the source is untouched'
echo "A/B root copy test passed"
