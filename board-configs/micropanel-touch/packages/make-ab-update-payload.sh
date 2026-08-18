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

for tool in losetup mount umount mountpoint mktemp mkfifo dd tee sha256sum xz tar sed awk stat install mv rm sync \
            blkid blockdev wc tr cp mkdir sleep e2label; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: required host tool is missing: $tool" >&2
        exit 1
    }
done

loop=""
boot_mount=""
work=""
rootfs_publish=""
boot_tar_publish=""
manifest_publish=""
hash_fifo=""
count_fifo=""
hash_pid=""
count_pid=""
source_root_label_neutralized=0

# e2label updates the ext4 superblock checksum.  Directly overwriting
# s_volume_name in a raw stream does not, so it produces an image that e2fsck
# correctly rejects before the device can arm the candidate slot.
restore_source_root_label() {
    [ "$source_root_label_neutralized" -eq 1 ] || return 0
    [ -n "$loop" ] || return 1
    if ! e2label "${loop}p5" MP_ROOT_A; then
        return 1
    fi
    if ! sync -f "${loop}p5"; then
        return 1
    fi
    source_root_label_neutralized=0
}

cleanup() {
    local status=$?
    [ -z "$hash_pid" ] || wait "$hash_pid" 2>/dev/null || true
    [ -z "$count_pid" ] || wait "$count_pid" 2>/dev/null || true
    if [ -n "$boot_mount" ] && mountpoint -q "$boot_mount"; then
        umount "$boot_mount" || true
    fi
    if [ "$source_root_label_neutralized" -eq 1 ]; then
        if ! restore_source_root_label; then
            echo "ERROR: unable to restore MP_ROOT_A on source image ${loop}p5" >&2
        fi
    fi
    [ -z "$loop" ] || losetup -d "$loop" 2>/dev/null || true
    rm -f -- "$rootfs_publish" "$boot_tar_publish" "$manifest_publish"
    rm -f -- "$hash_fifo" "$count_fifo"
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

loop=$(losetup --find --show --partscan "$image")
wait_for_partitions
[ "$(blkid -s LABEL -o value "${loop}p1")" = MP_BOOT_A ] || {
    echo 'ERROR: image p1 is not MP_BOOT_A' >&2
    exit 1
}
source_root_label=$(blkid -s LABEL -o value "${loop}p5" 2>/dev/null || true)
case "$source_root_label" in
    MP_ROOT_A) ;;
    '')
        # A preceding generator killed by SIGKILL or host power loss can leave
        # p5 label-neutral. Treat that exact state as recoverable and reassert
        # the authored source label before this invocation returns.
        echo 'INFO: source p5 is label-neutral; this run will restore MP_ROOT_A' >&2
        ;;
    *)
        echo 'ERROR: image p5 is not MP_ROOT_A or label-neutral' >&2
        exit 1
        ;;
esac

work=$(mktemp -d)
boot_mount="$work/boot-mounted"
install -d "$boot_mount" "$work/boot-tree"
mount -o ro "${loop}p1" "$boot_mount"
[ -d "$boot_mount/A" ] || { echo 'ERROR: A/B image has no A boot tree' >&2; exit 1; }
[ -f "$boot_mount/A/cmdline.txt" ] || { echo 'ERROR: A boot tree has no cmdline.txt' >&2; exit 1; }
[ "$(wc -l < "$boot_mount/A/cmdline.txt")" -eq 1 ] || {
    echo 'ERROR: A cmdline must contain exactly one line' >&2
    exit 1
}

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
    [ ! -d "$destination" ] || {
        echo "ERROR: payload destination is a directory: $destination" >&2
        exit 1
    }
done

rootfs_tmp="$work/rootfs.img.xz"
rootfs_digest="$work/rootfs.sha256"
rootfs_count="$work/rootfs.bytes"
rootfs_bytes=$(blockdev --getsize64 "${loop}p5")

# Build a label-neutral rootfs with the filesystem tool rather than editing
# superblock bytes in the stream.  e2label keeps ext4 metadata checksums valid;
# cleanup restores the source image on every normal failure or signal path.
source_root_label_neutralized=1
e2label "${loop}p5" ""
sync -f "${loop}p5"
[ -z "$(blkid -s LABEL -o value "${loop}p5" 2>/dev/null || true)" ] || {
    echo 'ERROR: unable to clear source root label for slot-neutral payload' >&2
    exit 1
}

# The only multi-gigabyte data path is this pipeline.  tee feeds the hasher
# and byte counter through explicitly waited-for FIFOs while xz writes the
# release artifact; it never stages an uncompressed rootfs in RAM or on the
# host filesystem.
hash_fifo="$work/rootfs-hash.fifo"
count_fifo="$work/rootfs-count.fifo"
mkfifo "$hash_fifo" "$count_fifo"
sha256sum < "$hash_fifo" | awk '{print $1}' > "$rootfs_digest" & hash_pid=$!
wc -c < "$count_fifo" > "$rootfs_count" & count_pid=$!
set +e
set -o pipefail
dd if="${loop}p5" bs=8M status=progress | tee "$hash_fifo" "$count_fifo" | \
    xz --threads=0 --check=crc64 --lzma2=dict=64MiB --stdout > "$rootfs_tmp"
pipeline_status=$?
wait "$hash_pid"; hash_status=$?; hash_pid=""
wait "$count_pid"; count_status=$?; count_pid=""
set -e
[ "$pipeline_status" -eq 0 ] && [ "$hash_status" -eq 0 ] && [ "$count_status" -eq 0 ] || {
    echo 'ERROR: rootfs compression pipeline failed' >&2
    exit 1
}
rm -f -- "$hash_fifo" "$count_fifo"
hash_fifo=""
count_fifo=""
rootfs_sha256=$(cat "$rootfs_digest")
actual_rootfs_bytes=$(tr -d '[:space:]' < "$rootfs_count")
[[ "$rootfs_sha256" =~ ^[0-9a-f]{64}$ ]] || { echo 'ERROR: invalid rootfs digest' >&2; exit 1; }
[ "$actual_rootfs_bytes" = "$rootfs_bytes" ] || {
    echo "ERROR: rootfs stream length $actual_rootfs_bytes does not match slot $rootfs_bytes" >&2
    exit 1
}
restore_source_root_label
[ "$(blkid -s LABEL -o value "${loop}p5")" = MP_ROOT_A ] || {
    echo 'ERROR: unable to restore source root label after payload generation' >&2
    exit 1
}

tar --format=posix --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
    -C "$work/boot-tree" -cf "$work/boot.tar" .
boot_sha256=$(sha256sum "$work/boot.tar" | awk '{print $1}')
[[ "$boot_sha256" =~ ^[0-9a-f]{64}$ ]] || { echo 'ERROR: invalid boot archive digest' >&2; exit 1; }

# Rebuilding an existing release version is intentional. Stage each artifact
# beside its destination, then publish only after the complete replacement
# triplet has been generated and checked. Publishing the manifest last makes a
# partially interrupted publish fail closed at the device-side hash checks.
rootfs_publish=$(mktemp "$output_dir/.${prefix}.rootfs.img.xz.XXXXXX")
boot_tar_publish=$(mktemp "$output_dir/.${prefix}.boot.tar.XXXXXX")
manifest_publish=$(mktemp "$output_dir/.${prefix}.manifest.XXXXXX")
install -m0644 "$rootfs_tmp" "$rootfs_publish"
install -m0644 "$work/boot.tar" "$boot_tar_publish"
cat > "$work/manifest" <<EOF
version=$version
variant=$variant
boards=$boards
rootfs_sha256=$rootfs_sha256
rootfs_bytes=$rootfs_bytes
boot_sha256=$boot_sha256
format=1
EOF
install -m0644 "$work/manifest" "$manifest_publish"
sync "$rootfs_publish" "$boot_tar_publish" "$manifest_publish"
mv -f -- "$rootfs_publish" "$rootfs"
rootfs_publish=""
mv -f -- "$boot_tar_publish" "$boot_tar"
boot_tar_publish=""
mv -f -- "$manifest_publish" "$manifest"
manifest_publish=""
sync "$rootfs" "$boot_tar" "$manifest"

echo "Created update payload: $manifest"
