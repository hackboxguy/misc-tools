#!/bin/bash
# Exercise the A/B finalizer and its verifier using a deliberately tiny,
# self-contained two-partition apps-image fixture. Run on a Linux host with
# loop-device and mount privileges: sudo tests/test_ab_layout_integration.sh
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../../.." && pwd)
finalizer="$repo_root/board-configs/micropanel-touch/packages/finalize-image-layout.sh"
verifier="$repo_root/board-configs/micropanel-touch/packages/verify-ab-image-layout.sh"
payload_generator="$repo_root/board-configs/micropanel-touch/packages/make-ab-update-payload.sh"
release_key_tool="$repo_root/board-configs/micropanel-touch/packages/micropanel-touch-release-key.sh"

[ "$(id -u)" -eq 0 ] || {
    echo "ERROR: run as root so the fixture can use loop partitions" >&2
    exit 1
}
for tool in truncate sfdisk losetup mkfs.vfat mkfs.ext4 mount umount mountpoint install sync dd tr xz tar sha256sum wc blkid sleep e2fsck e2label; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: missing host tool: $tool" >&2
        exit 1
    }
done

work=$(mktemp -d)
image="$work/apps-source.img"
source_loop=""
source_boot_mount="$work/source-boot"
source_root_mount="$work/source-root"

unmount_if_mounted() {
    local directory=$1
    [ -n "$directory" ] && mountpoint -q "$directory" && umount "$directory"
}

cleanup() {
    local status=$?
    unmount_if_mounted "$source_root_mount" || true
    unmount_if_mounted "$source_boot_mount" || true
    [ -z "$source_loop" ] || losetup -d "$source_loop" 2>/dev/null || true
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

# 32 MiB FAT boot + 64 MiB authored root. The finalizer expands this into a
# 384 MiB A/B image with deliberately small but proportionate test slots.
truncate -s 160M "$image"
sfdisk "$image" <<EOF
label: dos
unit: sectors

${image}1 : start=2048, size=65536, type=c, bootable
${image}2 : start=67584, size=131072, type=83
EOF

source_loop=$(losetup --find --show --partscan "$image")
retries=0
while [ "$retries" -lt 20 ]; do
    [ -b "${source_loop}p1" ] && [ -b "${source_loop}p2" ] && break
    sleep 1
    retries=$((retries + 1))
done
if ! { [ -b "${source_loop}p1" ] && [ -b "${source_loop}p2" ]; }; then
    echo "ERROR: fixture loop partitions did not appear" >&2
    exit 1
fi

mkfs.vfat -F32 -n SOURCE_BOOT "${source_loop}p1" >/dev/null
mkfs.ext4 -F -L SOURCE_ROOT "${source_loop}p2" >/dev/null
install -d "$source_boot_mount" "$source_root_mount"
mount "${source_loop}p1" "$source_boot_mount"
mount "${source_loop}p2" "$source_root_mount"

printf '%s\n' 'dtoverlay=vc4-kms-v3d' > "$source_boot_mount/config.txt"
printf '%s\n' \
    'console=serial0,115200 root=PARTUUID=fixture-root rootfstype=ext4 fsck.repair=yes rootwait overlayroot=tmpfs:recurse=0' \
    > "$source_boot_mount/cmdline.txt"
printf '%s\n' 'fixture kernel payload' > "$source_boot_mount/kernel8.img"
install -d "$source_boot_mount/overlays"
printf '%s\n' 'fixture overlay payload' > "$source_boot_mount/overlays/vc4-kms-v3d.dtbo"

install -d "$source_root_mount/etc/NetworkManager/system-connections"
manifest="$source_root_mount/opt/micropanel-touch/share/micropanel-touch/image-manifest.env"
fixture_app_revision=0123456789012345678901234567890123456789
install -Dm0644 /dev/null "$manifest"
printf '%s\n' \
    'root:x:0:0:root:/root:/bin/bash' \
    'micropanel-touch:x:1234:1234:MicroPanel Touch:/nonexistent:/usr/sbin/nologin' \
    > "$source_root_mount/etc/passwd"
printf '%s\n' \
    'PARTUUID=fixture-root / ext4 defaults 0 1' \
    'PARTUUID=fixture-boot /boot/firmware vfat defaults 0 2' \
    > "$source_root_mount/etc/fstab"
printf '%s\n' 'IMAGE_VERSION=fixture' \
    "MICROPANEL_TOUCH_REVISION=$fixture_app_revision" \
    'PANEL_VARIANT=piscreen' > "$manifest"
printf '%s\n' '[connection]' 'id=fixture' > "$source_root_mount/etc/NetworkManager/system-connections/fixture.nmconnection"
chmod 0600 "$source_root_mount/etc/NetworkManager/system-connections/fixture.nmconnection"
chmod 0700 "$source_root_mount/etc/NetworkManager/system-connections"

sync
unmount_if_mounted "$source_root_mount"
unmount_if_mounted "$source_boot_mount"
losetup -d "$source_loop"
source_loop=""

# DATA_PARTITION_MB intentionally remains unset: it has no meaning when p8
# is the A/B layout's remainder and this verifies that it is not a hidden
# requirement of the finalizer API.
# A disposable release key: the real one lives outside every checkout.
release_key="$work/release-signing/ed25519-release.key"
MICROPANEL_RELEASE_KEY="$release_key" "$release_key_tool" ensure 2>/dev/null

env -u DATA_PARTITION_MB MICROPANEL_TOUCH_REVISION="$fixture_app_revision" \
    IMAGE_PATH="$image" AB_LAYOUT=1 AB_IMAGE_SIZE_MB=384 \
    AB_BOOT_PARTITION_MB=32 AB_ROOT_PARTITION_MB=96 AB_FACTORY_PARTITION_MB=32 \
    SLOT_COMPATIBLE_BOARDS=pi4 IMAGE_VERSION=fixture-running \
    UPDATE_SIGNING_PUBLIC_KEY="$release_key.pub" \
    UPDATE_RELEASE_URL_TEMPLATE='https://example.invalid/releases/latest/download/@ASSET@' \
    "$finalizer"

MICROPANEL_TOUCH_REVISION="$fixture_app_revision" "$verifier" "$image"
# Stage 2b publishes exactly two version-less assets: the bundle and a
# standalone copy of its manifest.
asset_prefix="$work/payload/micropanel-touch-luckfox-ctp"
bundle="$asset_prefix.mpupdate"
manifest="$asset_prefix.manifest"
failing_bin="$work/failing-bin"
install -d "$failing_bin"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$failing_bin/xz"
chmod 0755 "$failing_bin/xz"
if PATH="$failing_bin:$PATH" "$payload_generator" --image="$image" --output-dir="$work/failed-payload" \
    --version=fixture-failure --variant=luckfox-ctp --boards=pi4 \
    --signing-key="$release_key" >/dev/null 2>&1; then
    echo 'ERROR: payload generator accepted a forced compression failure' >&2
    exit 1
fi
[ ! -e "$work/failed-payload/micropanel-touch-luckfox-ctp.mpupdate" ] || {
    echo 'ERROR: a failed payload generation published a bundle' >&2
    exit 1
}
source_loop=$(losetup --find --show --partscan --read-only "$image")
retries=0
while [ "$retries" -lt 20 ]; do
    [ -b "${source_loop}p5" ] && break
    sleep 1
    retries=$((retries + 1))
done
[ "$(blkid -s LABEL -o value "${source_loop}p5")" = MP_ROOT_A ] || {
    echo 'ERROR: failed payload generation did not restore source root label' >&2
    exit 1
}
losetup -d "$source_loop"
source_loop=""
mkdir -p "$work/payload"
printf '%s\n' 'obsolete payload artifact' > "$manifest"
printf '%s\n' 'obsolete payload artifact' > "$bundle"
"$payload_generator" --image="$image" --output-dir="$work/payload" \
    --version=fixture-1 --variant=luckfox-ctp --boards=pi4 --signing-key="$release_key"
[ -f "$bundle" ] && [ -f "$manifest" ]
# The retired format=1 triplet must not reappear beside the published assets.
[ "$(find "$work/payload" -maxdepth 1 -type f | wc -l)" -eq 2 ] || {
    echo 'ERROR: the payload directory holds more than the two published assets' >&2
    ls -1 "$work/payload" >&2
    exit 1
}

grep -Fqx 'version=fixture-1' "$manifest"
grep -Fqx 'variant=luckfox-ctp' "$manifest"
grep -Fqx 'boards=pi4' "$manifest"
grep -Fqx 'format=2' "$manifest"

# Member order is the format. The device reader is single-pass, so a bundle
# whose members moved would abort rather than install.
bundle_members=$(tar -tf "$bundle" | tr '\n' ' ')
[ "$bundle_members" = 'manifest manifest.sig boot.tar rootfs.img.xz ' ] || {
    echo "ERROR: bundle member order is $bundle_members" >&2
    exit 1
}
# ustar keeps every header one fixed 512-byte block, which is what makes the
# device-side reader a straightforward single pass over a pipe.
[ "$(dd if="$bundle" bs=1 skip=257 count=5 status=none)" = ustar ] || {
    echo 'ERROR: bundle is not a ustar archive' >&2
    exit 1
}

install -d "$work/unbundled"
tar -xf "$bundle" -C "$work/unbundled"
cmp "$work/unbundled/manifest" "$manifest"
MICROPANEL_RELEASE_KEY="$release_key" "$release_key_tool" \
    verify "$work/unbundled/manifest" "$work/unbundled/manifest.sig" || {
    echo 'ERROR: the published bundle signature does not verify' >&2
    exit 1
}
boot_tar="$work/unbundled/boot.tar"
rootfs="$work/unbundled/rootfs.img.xz"

rootfs_sha256=$(awk -F= '$1 == "rootfs_sha256" {print $2}' "$manifest")
rootfs_bytes=$(awk -F= '$1 == "rootfs_bytes" {print $2}' "$manifest")
boot_sha256=$(awk -F= '$1 == "boot_sha256" {print $2}' "$manifest")
[[ "$rootfs_sha256" =~ ^[0-9a-f]{64}$ ]]
[[ "$boot_sha256" =~ ^[0-9a-f]{64}$ ]]
[ "$(xz -dc "$rootfs" | sha256sum | awk '{print $1}')" = "$rootfs_sha256" ]
[ "$(xz -dc "$rootfs" | wc -c | tr -d '[:space:]')" = "$rootfs_bytes" ]
neutral_rootfs="$work/neutral-rootfs.img"
xz -dc "$rootfs" > "$neutral_rootfs"
[ -z "$(dd if="$neutral_rootfs" bs=1 skip=$((1024 + 0x78)) count=16 status=none | tr -d '\000')" ] || {
    echo 'ERROR: payload rootfs retained its source-slot ext4 label' >&2
    exit 1
}
e2fsck -fn "$neutral_rootfs" >/dev/null
source_loop=$(losetup --find --show --partscan --read-only "$image")
retries=0
while [ "$retries" -lt 20 ]; do
    [ -b "${source_loop}p5" ] && break
    sleep 1
    retries=$((retries + 1))
done
[ "$(blkid -s LABEL -o value "${source_loop}p5")" = MP_ROOT_A ] || {
    echo 'ERROR: payload generation did not restore source root label' >&2
    exit 1
}
losetup -d "$source_loop"
source_loop=""
MICROPANEL_TOUCH_REVISION="$fixture_app_revision" "$verifier" "$image"

# Simulate the source-image state left by a host kill while its label was
# neutralized. The next payload invocation must self-heal p5 before it exits.
source_loop=$(losetup --find --show --partscan "$image")
retries=0
while [ "$retries" -lt 20 ]; do
    [ -b "${source_loop}p5" ] && break
    sleep 1
    retries=$((retries + 1))
done
e2label "${source_loop}p5" ""
sync -f "${source_loop}p5"
losetup -d "$source_loop"
source_loop=""
"$payload_generator" --image="$image" --output-dir="$work/recovered-payload" \
    --version=fixture-recovery --variant=luckfox-ctp --boards=pi4 --signing-key="$release_key"
source_loop=$(losetup --find --show --partscan --read-only "$image")
retries=0
while [ "$retries" -lt 20 ]; do
    [ -b "${source_loop}p5" ] && break
    sleep 1
    retries=$((retries + 1))
done
[ "$(blkid -s LABEL -o value "${source_loop}p5")" = MP_ROOT_A ] || {
    echo 'ERROR: recovery payload generation did not repair source root label' >&2
    exit 1
}
losetup -d "$source_loop"
source_loop=""
MICROPANEL_TOUCH_REVISION="$fixture_app_revision" "$verifier" "$image"
[ "$(sha256sum "$boot_tar" | awk '{print $1}')" = "$boot_sha256" ]
tar -tf "$boot_tar" | grep -Fqx './cmdline.txt.template'
if tar -tf "$boot_tar" | grep -Fqx './cmdline.txt'; then
    echo 'ERROR: boot payload retained slot-bound cmdline.txt' >&2
    exit 1
fi
tar -xOf "$boot_tar" ./cmdline.txt.template | tr ' ' '\n' | \
    grep -Fqx 'root=LABEL=@MICROPANEL_SLOT@'
echo "A/B finalizer integration test passed"
