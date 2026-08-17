#!/bin/bash
# Build the unsigned, slot-neutral Stage 2 update payload from a completed
# MicroPanel Touch A/B image.  This is host-side only: the device-side updater
# streams rootfs.img.xz directly to its inactive slot and renders cmdline.txt
# from the template carried in boot.tar.
set -euo pipefail

export LC_ALL=C

image=""
output_dir=""
version=""
variant=""
boards=""

usage() {
    cat >&2 <<'EOF'
Usage: make-ab-update-payload.sh --image FILE --output-dir DIR --version VER \
       --variant NAME --boards LIST
EOF
    exit 2
}

for argument in "$@"; do
    case "$argument" in
        --image=*) image=${argument#*=} ;;
        --output-dir=*) output_dir=${argument#*=} ;;
        --version=*) version=${argument#*=} ;;
        --variant=*) variant=${argument#*=} ;;
        --boards=*) boards=${argument#*=} ;;
        --help|-h) usage ;;
        *) echo "ERROR: unknown option: $argument" >&2; usage ;;
    esac
done

safe_token() {
    [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}
safe_boards() {
    [[ ${1:-} =~ ^[a-z0-9]+(,[a-z0-9]+)*$ ]]
}

[ "$(id -u)" -eq 0 ] || { echo 'ERROR: run as root to inspect A/B image partitions' >&2; exit 1; }
[ -f "$image" ] || { echo 'ERROR: --image must name a completed A/B image' >&2; exit 1; }
[ -n "$output_dir" ] || usage
safe_token "$version" || { echo 'ERROR: --version must be a safe release token' >&2; exit 1; }
safe_token "$variant" || { echo 'ERROR: --variant must be a safe release token' >&2; exit 1; }
safe_boards "$boards" || { echo 'ERROR: --boards must be a comma-separated board allow-list' >&2; exit 1; }

for tool in losetup mount umount mountpoint mktemp dd tee sha256sum xz tar sed awk stat install mv rm sync \
            blkid blockdev wc tr cp mkdir sleep; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: required host tool is missing: $tool" >&2
        exit 1
    }
done

loop=""
boot_mount=""
work=""

cleanup() {
    local status=$?
    if [ -n "$boot_mount" ] && mountpoint -q "$boot_mount"; then
        umount "$boot_mount" || true
    fi
    [ -z "$loop" ] || losetup -d "$loop" 2>/dev/null || true
    [ -z "$work" ] || rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

wait_for_partitions() {
    local attempts=0
    while [ "$attempts" -lt 20 ]; do
        [ -b "${loop}p1" ] && [ -b "${loop}p5" ] && return 0
        sleep 1
        attempts=$((attempts + 1))
    done
    echo "ERROR: A/B image partitions did not appear for $loop" >&2
    return 1
}

loop=$(losetup --find --show --partscan --read-only "$image")
wait_for_partitions
[ "$(blkid -s LABEL -o value "${loop}p1")" = MP_BOOT_A ] || {
    echo 'ERROR: image p1 is not MP_BOOT_A' >&2
    exit 1
}
[ "$(blkid -s LABEL -o value "${loop}p5")" = MP_ROOT_A ] || {
    echo 'ERROR: image p5 is not MP_ROOT_A' >&2
    exit 1
}

work=$(mktemp -d)
boot_mount="$work/boot-mounted"
install -d "$boot_mount" "$work/boot-tree"
mount -o ro "${loop}p1" "$boot_mount"
[ -d "$boot_mount/A" ] || { echo 'ERROR: A/B image has no A boot tree' >&2; exit 1; }
[ -f "$boot_mount/A/cmdline.txt" ] || { echo 'ERROR: A boot tree has no cmdline.txt' >&2; exit 1; }

# The release payload must not inherit its source slot's root label.  Keep
# every other cmdline token byte-for-byte, but require exactly one root token
# so the device-side renderer cannot accidentally create a second root=.
root_count=$(tr ' ' '\n' < "$boot_mount/A/cmdline.txt" | awk '/^root=/{count++} END {print count+0}')
[ "$root_count" -eq 1 ] || { echo 'ERROR: A cmdline must contain exactly one root= token' >&2; exit 1; }
cp -a "$boot_mount/A/." "$work/boot-tree/"
sed -E 's#(^|[[:space:]])root=[^[:space:]]+#\1root=LABEL=@MICROPANEL_SLOT@#' \
    "$boot_mount/A/cmdline.txt" > "$work/boot-tree/cmdline.txt.template"
rm -f "$work/boot-tree/cmdline.txt"
grep -Fqx "root=LABEL=@MICROPANEL_SLOT@" <(tr ' ' '\n' < "$work/boot-tree/cmdline.txt.template") || {
    echo 'ERROR: unable to create slot-neutral cmdline template' >&2
    exit 1
}

prefix="micropanel-touch-${version}-${variant}"
mkdir -p "$output_dir"
rootfs="$output_dir/${prefix}.rootfs.img.xz"
boot_tar="$output_dir/${prefix}.boot.tar"
manifest="$output_dir/${prefix}.manifest"
for destination in "$rootfs" "$boot_tar" "$manifest"; do
    [ ! -e "$destination" ] || { echo "ERROR: payload destination already exists: $destination" >&2; exit 1; }
done

rootfs_tmp="$work/rootfs.img.xz"
rootfs_digest="$work/rootfs.sha256"
rootfs_count="$work/rootfs.bytes"
rootfs_bytes=$(blockdev --getsize64 "${loop}p5")

# The only multi-gigabyte data path is this pipeline.  tee feeds the hasher
# and byte counter while xz writes the release artifact; it never stages an
# uncompressed rootfs in RAM or on the host filesystem.
set +e
set -o pipefail
dd if="${loop}p5" bs=8M status=progress | \
    tee >(sha256sum | awk '{print $1}' > "$rootfs_digest") \
        >(wc -c > "$rootfs_count") | \
    xz --threads=0 --check=crc64 --lzma2=dict=64MiB --stdout > "$rootfs_tmp"
pipeline_status=$?
wait
set -e
[ "$pipeline_status" -eq 0 ] || { echo 'ERROR: rootfs compression pipeline failed' >&2; exit 1; }
rootfs_sha256=$(cat "$rootfs_digest")
actual_rootfs_bytes=$(tr -d '[:space:]' < "$rootfs_count")
[[ "$rootfs_sha256" =~ ^[0-9a-f]{64}$ ]] || { echo 'ERROR: invalid rootfs digest' >&2; exit 1; }
[ "$actual_rootfs_bytes" = "$rootfs_bytes" ] || {
    echo "ERROR: rootfs stream length $actual_rootfs_bytes does not match slot $rootfs_bytes" >&2
    exit 1
}

tar --format=posix --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
    -C "$work/boot-tree" -cf "$work/boot.tar" .
boot_sha256=$(sha256sum "$work/boot.tar" | awk '{print $1}')
[[ "$boot_sha256" =~ ^[0-9a-f]{64}$ ]] || { echo 'ERROR: invalid boot archive digest' >&2; exit 1; }

install -m0644 "$rootfs_tmp" "$rootfs"
install -m0644 "$work/boot.tar" "$boot_tar"
cat > "$work/manifest" <<EOF
version=$version
variant=$variant
boards=$boards
rootfs_sha256=$rootfs_sha256
rootfs_bytes=$rootfs_bytes
boot_sha256=$boot_sha256
format=1
EOF
install -m0644 "$work/manifest" "$manifest"
sync "$rootfs" "$boot_tar" "$manifest"

echo "Created update payload: $manifest"
