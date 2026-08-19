#!/bin/bash
# pi-ab-update: build the slot-neutral format=2 update bundle from a completed
# A/B image.  Host-side only: the device-side updater streams the bundle's
# rootfs member straight into its inactive slot and renders cmdline.txt from
# the template carried in the boot member.
#
# Published assets (deliberately version-less so the Stage 4
# `releases/latest/download/` URLs are stable; the real version lives inside
# the manifest):
#
#   <product>-<variant>.mpupdate      outer ustar bundle, fixed order:
#                                              1 manifest
#                                              2 manifest.sig
#                                              3 boot.tar
#                                              4 rootfs.img.xz  (last, streamed)
#   <product>-<variant>.manifest      standalone copy for cheap checks
#   <product>-<variant>.manifest.sig  its detached signature
#
# The standalone signature is published from the first format=2 release for the
# same reason the bundle carries one: Stage 4's check step verifies the tiny
# manifest *before* offering an update, so it needs a signature it can fetch
# alongside it. Publishing it only when Stage 4 lands would leave every release
# in between unverifiable by that step — exactly the migration gap that signing
# from day one exists to avoid.
#
# The former format=1 triplet is now a build intermediate only.
set -euo pipefail

export LC_ALL=C

image=""
output_dir=""
version=""
variant=""
boards=""
signing_key=""
product=""

script_dir=$(cd "$(dirname "$0")" && pwd)
release_key_tool=${AB_RELEASE_KEY_TOOL:-$script_dir/ab-release-key.sh}

usage() {
    cat >&2 <<'EOF'
Usage: ab-make-payload.sh --image FILE --output-dir DIR --version VER \
       --variant NAME --boards LIST --product NAME [--signing-key=FILE]
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
        --signing-key=*) signing_key=${argument#*=} ;;
        --product=*) product=${argument#*=} ;;
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
safe_token "$product" || { echo 'ERROR: --product must be a safe product name' >&2; exit 1; }
safe_boards "$boards" || { echo 'ERROR: --boards must be a comma-separated board allow-list' >&2; exit 1; }
[ -x "$release_key_tool" ] || {
    echo "ERROR: release signing helper is unavailable: $release_key_tool" >&2
    exit 1
}

for tool in losetup mount umount mountpoint mktemp mkfifo dd tee sha256sum xz tar sed awk stat install mv rm sync \
            blkid blockdev wc tr cp mkdir sleep e2label openssl; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: required host tool is missing: $tool" >&2
        exit 1
    }
done

loop=""
boot_mount=""
work=""
bundle_publish=""
manifest_publish=""
signature_publish=""
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
    # V5-01: the signal traps otherwise re-enter this function through EXIT.
    # Disarm them first so the unmount and label restore run exactly once.
    trap - EXIT HUP INT TERM
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
    rm -f -- "$bundle_publish" "$signature_publish" "$manifest_publish"
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
install -d "$boot_mount" "$work/boot-tree" "$work/bundle"
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

# Published names carry no version: the manifest is the authority on which
# release this is, and stable names give Stage 4 a stable download URL.
asset_prefix="${product}-${variant}"
mkdir -p "$output_dir"
bundle="$output_dir/${asset_prefix}.mpupdate"
manifest="$output_dir/${asset_prefix}.manifest"
manifest_signature="$output_dir/${asset_prefix}.manifest.sig"
for destination in "$bundle" "$manifest" "$manifest_signature"; do
    [ ! -d "$destination" ] || {
        echo "ERROR: payload destination is a directory: $destination" >&2
        exit 1
    }
done

# O-05: version-less asset names mean a second release in the same directory
# silently replaces the first. Republishing the same version is intentional and
# still allowed; replacing a different one is almost always a forgotten
# --payload-dir.
if [ -f "$manifest" ]; then
    existing_version=$(awk -F= '$1 == "version" { print $2; exit }' "$manifest" 2>/dev/null || true)
    if [ -n "$existing_version" ] && [ "$existing_version" != "$version" ]; then
        cat >&2 <<EOF
ERROR: $output_dir already holds release $existing_version.
       Publishing $version here would silently replace it, because asset names
       are deliberately version-less. Use a per-version --payload-dir.
EOF
        exit 1
    fi
fi

rootfs_tmp="$work/bundle/rootfs.img.xz"
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
    -C "$work/boot-tree" -cf "$work/bundle/boot.tar" .
boot_sha256=$(sha256sum "$work/bundle/boot.tar" | awk '{print $1}')
[[ "$boot_sha256" =~ ^[0-9a-f]{64}$ ]] || { echo 'ERROR: invalid boot archive digest' >&2; exit 1; }

cat > "$work/bundle/manifest" <<EOF
version=$version
variant=$variant
boards=$boards
rootfs_sha256=$rootfs_sha256
rootfs_bytes=$rootfs_bytes
boot_sha256=$boot_sha256
format=2
EOF

# Sign from the first format=2 release so Stage 4 can switch verification on
# without needing a migration release. The device currently accepts and ignores
# this member; it is never optional on the build side.
[ -n "$signing_key" ] || signing_key=$("$release_key_tool" key-path)
export MICROPANEL_RELEASE_KEY="$signing_key"
"$release_key_tool" ensure
"$release_key_tool" sign "$work/bundle/manifest" "$work/bundle/manifest.sig"
"$release_key_tool" verify "$work/bundle/manifest" "$work/bundle/manifest.sig" || {
    echo 'ERROR: freshly written manifest signature does not verify' >&2
    exit 1
}

# ustar keeps every member header a single fixed 512-byte block, which is what
# lets the device reader be a straightforward single pass over a pipe. Its
# 8 GiB per-member ceiling is far above any slot artifact, but check it rather
# than emit a silently truncated size field.
for member in manifest manifest.sig boot.tar rootfs.img.xz; do
    chmod 0644 "$work/bundle/$member"
    [ "$(stat -c %s "$work/bundle/$member")" -lt 8589934592 ] || {
        echo "ERROR: bundle member exceeds the ustar size limit: $member" >&2
        exit 1
    }
done
# Member order is part of the format: manifest first so a wrong or already
# installed release aborts after kilobytes, rootfs last so the multi-gigabyte
# tail streams straight into the inactive slot.
tar --format=ustar --owner=0 --group=0 --numeric-owner --mtime=@0 \
    -C "$work/bundle" -cf "$work/bundle.mpupdate" \
    manifest manifest.sig boot.tar rootfs.img.xz

# Rebuilding a release is intentional. Stage each asset beside its destination,
# then publish only after the complete replacement has been generated and
# checked. Publishing the standalone manifest last makes a partially
# interrupted publish fail closed for a future "check for updates" reader.
bundle_publish=$(mktemp "$output_dir/.${asset_prefix}.mpupdate.XXXXXX")
signature_publish=$(mktemp "$output_dir/.${asset_prefix}.manifest.sig.XXXXXX")
manifest_publish=$(mktemp "$output_dir/.${asset_prefix}.manifest.XXXXXX")
install -m0644 "$work/bundle.mpupdate" "$bundle_publish"
install -m0644 "$work/bundle/manifest.sig" "$signature_publish"
install -m0644 "$work/bundle/manifest" "$manifest_publish"
sync "$bundle_publish" "$signature_publish" "$manifest_publish"
# Publish the manifest last: a reader that finds it can rely on the bundle and
# the detached signature beside it already being complete.
mv -f -- "$bundle_publish" "$bundle"
bundle_publish=""
mv -f -- "$signature_publish" "$manifest_signature"
signature_publish=""
mv -f -- "$manifest_publish" "$manifest"
manifest_publish=""
sync "$bundle" "$manifest_signature" "$manifest"

echo "Created update payload: $bundle"

# GitHub refuses a release asset over 2 GiB, and it refuses it at upload time -
# after a full build and a long push. Worse, a release that somehow shipped
# oversized would fail on the device as a transport error, sending whoever
# debugged it after the network rather than the artifact. Say it here, on the
# build host, while it is still cheap to act on.
bundle_bytes=$(stat -c %s "$bundle")
asset_limit_bytes=${AB_ASSET_LIMIT_BYTES:-2147483648}          # GitHub: 2 GiB
asset_warn_bytes=${AB_ASSET_WARN_BYTES:-1932735283}            # 90% of that
if [ "$bundle_bytes" -ge "$asset_limit_bytes" ]; then
    echo "ERROR: the bundle is $bundle_bytes bytes, at or over the ${asset_limit_bytes}-byte" >&2
    echo "       per-asset limit for a GitHub release. It cannot be published there." >&2
    exit 1
elif [ "$bundle_bytes" -ge "$asset_warn_bytes" ]; then
    echo "WARNING: the bundle is $bundle_bytes bytes, within 10% of the" >&2
    echo "         ${asset_limit_bytes}-byte GitHub per-asset limit. Shrinking the root" >&2
    echo "         filesystem or choosing another distribution channel is due soon." >&2
fi
