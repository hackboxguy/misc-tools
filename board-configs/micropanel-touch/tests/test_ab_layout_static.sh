#!/bin/sh
set -eu

repo_root=$(unset CDPATH; cd -- "$(dirname -- "$0")/../../.." && pwd)
finalizer="$repo_root/board-configs/micropanel-touch/packages/finalize-image-layout.sh"
selector="$repo_root/board-configs/micropanel-touch/packages/micropanel-touch-slot-selector"
skeleton="$repo_root/board-configs/micropanel-touch/packages/micropanel-touch-data-skeleton.sh"
verifier="$repo_root/board-configs/micropanel-touch/packages/verify-ab-image-layout.sh"
payload_generator="$repo_root/board-configs/micropanel-touch/packages/make-ab-update-payload.sh"
builder="$repo_root/build-image.sh"

bash -n "$finalizer" "$selector" "$skeleton" "$verifier" "$payload_generator" "$builder"
[ -x "$payload_generator" ] || { echo "missing payload generator: $payload_generator" >&2; exit 1; }

plan=$(AB_IMAGE_SIZE_MB=15000 "$finalizer" --print-ab-layout)
printf '%s\n' "$plan" | grep -Fqx 'layout=ab'
printf '%s\n' "$plan" | grep -Fqx 'p1=MP_BOOT_A:256MiB:vfat'
printf '%s\n' "$plan" | grep -Fqx 'p2=MP_BOOT_B:256MiB:vfat-reserved'
printf '%s\n' "$plan" | grep -Fqx 'p5=MP_ROOT_A:5120MiB:ext4'
printf '%s\n' "$plan" | grep -Fqx 'p6=MP_ROOT_B:5120MiB:ext4-reserved'
printf '%s\n' "$plan" | grep -Fqx 'p7=MP_FACTORY:2048MiB:ext4-reserved'
printf '%s\n' "$plan" | grep -Fqx 'p8=MICROPANEL_DATA:remainder:ext4'
printf '%s\n' "$plan" | grep -Fqx 'normal_selector=os_prefix=A/'
printf '%s\n' "$plan" | grep -Fqx 'tryboot_selector=os_prefix=B/'
# The post-image hook is invoked once, immediately after the two-partition
# apps image is authored. Its A/B branch must create, rather than expect, p8.
grep -Fqx "    [ \"\$partition_count\" -eq 2 ] || {" "$finalizer"
grep -Fqx "    seed_network_connections \"\$root_mount\" \"\$data_mount\"" "$finalizer"
grep -Fqx "    install -d -m0700 -o root -g root \"\$2/NetworkManager/system-connections\"" "$finalizer"
grep -Fqx "slot_compatible_boards=\${SLOT_COMPATIBLE_BOARDS:-pi4}" "$finalizer"
grep -Fqx "    render_boot_selector \"\$root_mount\" \"\$boot_mount\" render-normal A config.txt" "$finalizer"
grep -Fqx "    render_boot_selector \"\$root_mount\" \"\$boot_mount\" render-candidate B tryboot.txt" "$finalizer"
if grep -Fq "'LABEL=MP_ROOT_A / ext4" "$finalizer"; then
    echo 'slot-specific root fstab entry returned' >&2
    exit 1
fi

"$builder" --help | grep -Fq -- '--layout=MODE'
"$builder" --help | grep -Fq -- '--payload'
if "$builder" --board=micropanel-touch --layout=invalid --dry-run >/dev/null 2>&1; then
    echo 'invalid --layout was accepted' >&2
    exit 1
fi
grep -Fqx 'AB_LAYOUT=0' "$repo_root/board-configs/micropanel-touch/board.conf"
grep -Fqx 'SLOT_COMPATIBLE_BOARDS="pi4"' "$repo_root/board-configs/micropanel-touch/board.conf"
grep -Fqx 'xz-utils' "$repo_root/board-configs/micropanel-touch/runtime-deps.txt"
grep -Fq 'requires EXPAND_ROOT=0; first-boot root expansion would corrupt the A/B partition layout' "$builder"
grep -Fq 'for tool in sfdisk fdisk mkfs.ext4 mkfs.vfat e2fsck resize2fs e2label blkid blockdev mount; do' "$builder"
grep -Fq "bash \"\$ab_static_test\"" "$builder"
grep -Fq -- '--payload requires --layout=ab' "$builder"
grep -Fq 'make-ab-update-payload.sh' "$builder"
grep -Fq 'root=LABEL=@MICROPANEL_SLOT@' "$payload_generator"
grep -Fq 'tee >(sha256sum' "$payload_generator"

template=$(mktemp)
trap 'rm -f "$template"' EXIT HUP INT TERM
printf '%s\n' 'dtoverlay=vc4-kms-v3d' > "$template"
normal_a=$(MICROPANEL_BOOT_CONFIG_TEMPLATE="$template" "$selector" render-normal A)
normal_b=$(MICROPANEL_BOOT_CONFIG_TEMPLATE="$template" "$selector" render-normal B)
candidate_a=$(MICROPANEL_BOOT_CONFIG_TEMPLATE="$template" "$selector" render-candidate A)
expected_normal_b=$(printf 'os_prefix=B/\ndtoverlay=vc4-kms-v3d')
expected_normal_a=$(printf 'os_prefix=A/\ndtoverlay=vc4-kms-v3d')
expected_candidate_a=$(printf 'os_prefix=A/\ndtoverlay=vc4-kms-v3d')
[ "$normal_a" = "$expected_normal_a" ]
[ "$normal_b" = "$expected_normal_b" ]
[ "$candidate_a" = "$expected_candidate_a" ]
