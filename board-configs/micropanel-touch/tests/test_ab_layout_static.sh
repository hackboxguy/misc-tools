#!/bin/sh
set -eu

repo_root=$(unset CDPATH; cd -- "$(dirname -- "$0")/../../.." && pwd)
finalizer="$repo_root/board-configs/micropanel-touch/packages/finalize-image-layout.sh"
selector="$repo_root/board-configs/micropanel-touch/packages/micropanel-touch-slot-selector"
skeleton="$repo_root/board-configs/micropanel-touch/packages/micropanel-touch-data-skeleton.sh"
verifier="$repo_root/board-configs/micropanel-touch/packages/verify-ab-image-layout.sh"
builder="$repo_root/build-image.sh"

bash -n "$finalizer" "$selector" "$skeleton" "$verifier" "$builder"

plan=$(AB_IMAGE_SIZE_MB=15000 "$finalizer" --print-ab-layout)
printf '%s\n' "$plan" | grep -Fqx 'layout=ab'
printf '%s\n' "$plan" | grep -Fqx 'p1=MP_BOOT_A:256MiB:vfat'
printf '%s\n' "$plan" | grep -Fqx 'p2=MP_BOOT_B:256MiB:vfat-reserved'
printf '%s\n' "$plan" | grep -Fqx 'p5=MP_ROOT_A:5120MiB:ext4'
printf '%s\n' "$plan" | grep -Fqx 'p6=MP_ROOT_B:5120MiB:ext4-reserved'
printf '%s\n' "$plan" | grep -Fqx 'p7=MP_FACTORY:2048MiB:ext4-reserved'
printf '%s\n' "$plan" | grep -Fqx 'p8=MICROPANEL_DATA:remainder:ext4'
printf '%s\n' "$plan" | grep -Fqx 'normal_selector=flat-A-config.txt'
printf '%s\n' "$plan" | grep -Fqx 'tryboot_selector=os_prefix=B/'
# The post-image hook is invoked once, immediately after the two-partition
# apps image is authored. Its A/B branch must create, rather than expect, p8.
grep -Fqx "    [ \"\$partition_count\" -eq 2 ] || {" "$finalizer"
grep -Fqx "    seed_network_connections \"\$root_mount\" \"\$data_mount\"" "$finalizer"
grep -Fqx "    install -d -m0700 -o root -g root \"\$2/NetworkManager/system-connections\"" "$finalizer"

"$builder" --help | grep -Fq -- '--layout=MODE'
if "$builder" --board=micropanel-touch --layout=invalid --dry-run >/dev/null 2>&1; then
    echo 'invalid --layout was accepted' >&2
    exit 1
fi
grep -Fqx 'AB_LAYOUT=0' "$repo_root/board-configs/micropanel-touch/board.conf"
grep -Fqx 'xz-utils' "$repo_root/board-configs/micropanel-touch/runtime-deps.txt"
