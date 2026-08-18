#!/bin/sh
set -eu

repo_root=$(unset CDPATH; cd -- "$(dirname -- "$0")/../../.." && pwd)
finalizer="$repo_root/board-configs/micropanel-touch/packages/finalize-image-layout.sh"
selector="$repo_root/board-configs/micropanel-touch/packages/micropanel-touch-slot-selector"
skeleton="$repo_root/board-configs/micropanel-touch/packages/micropanel-touch-data-skeleton.sh"
verifier="$repo_root/board-configs/micropanel-touch/packages/verify-ab-image-layout.sh"
payload_generator="$repo_root/board-configs/micropanel-touch/packages/make-ab-update-payload.sh"
release_key_tool="$repo_root/board-configs/micropanel-touch/packages/micropanel-touch-release-key.sh"
builder="$repo_root/build-image.sh"

bash -n "$finalizer" "$selector" "$skeleton" "$verifier" "$payload_generator" "$release_key_tool" "$builder"
[ -x "$payload_generator" ] || { echo "missing payload generator: $payload_generator" >&2; exit 1; }
[ -x "$release_key_tool" ] || { echo "missing release key helper: $release_key_tool" >&2; exit 1; }

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
grep -Fqx 'util-linux' "$repo_root/board-configs/micropanel-touch/runtime-deps.txt"
grep -Fq 'requires EXPAND_ROOT=0; first-boot root expansion would corrupt the A/B partition layout' "$builder"
grep -Fq 'for tool in sfdisk fdisk mkfs.ext4 mkfs.vfat e2fsck resize2fs e2label blkid blockdev mount; do' "$builder"
grep -Fq "bash \"\$ab_static_test\"" "$builder"
grep -Fq -- '--payload requires --layout=ab' "$builder"
grep -Fq -- '--app-revision=SHA' "$builder"
grep -Fq -- '--app-ref=REF' "$builder"
grep -Fq 'resolve_micropanel_touch_revision()' "$builder"
grep -Fq 'resolved=$(git_remote_rev "$MICROPANEL_TOUCH_APP_REPO" "$MICROPANEL_TOUCH_REF")' "$builder"
grep -Fq 'MicroPanel Touch builds require --app-revision=<40-character lowercase micropanel-touch commit> or --app-ref=<branch-or-tag>' "$builder"
grep -Fq 'MICROPANEL_TOUCH_REVISION="$MICROPANEL_TOUCH_REVISION" "$IMAGER"' "$builder"
grep -Fq 'MICROPANEL_TOUCH_REVISION="$MICROPANEL_TOUCH_REVISION" "$PAYLOAD_IMAGE_VERIFIER" "$FINAL_IMG"' "$builder"
grep -Fq 'MICROPANEL_TOUCH_REVISION="$MICROPANEL_TOUCH_REVISION" \' "$builder"
grep -Fq 'make-ab-update-payload.sh' "$builder"

# V5-05: exactly one place names the application/release repository, and it is
# also where the reserved Stage 4 OTA URL template lives.
grep -Fqx 'MICROPANEL_TOUCH_APP_REPO="https://github.com/hackboxguy/micropanel-touch.git"' \
    "$repo_root/board-configs/micropanel-touch/board.conf"
grep -Fq 'MICROPANEL_TOUCH_RELEASE_URL_TEMPLATE=' \
    "$repo_root/board-configs/micropanel-touch/board.conf"
grep -Fq 'releases/latest/download/@ASSET@' \
    "$repo_root/board-configs/micropanel-touch/board.conf"
duplicate_repo_references=$(grep -rlF 'github.com/hackboxguy/micropanel-touch' \
    "$repo_root/board-configs/micropanel-touch" "$builder" | grep -v '/tests/' | sort)
[ "$duplicate_repo_references" = "$repo_root/board-configs/micropanel-touch/board.conf" ] || {
    echo 'the micropanel-touch repository URL is duplicated outside board.conf:' >&2
    printf '%s\n' "$duplicate_repo_references" >&2
    exit 1
}
grep -Fq 'verify-ab-image-layout.sh' "$builder"
grep -Fq '"$PAYLOAD_IMAGE_VERIFIER" "$FINAL_IMG"' "$builder"
grep -Fq 'PAYLOAD_VARIANT="${VARIANT:-${DEFAULT_PANEL_VARIANT:-default}}"' "$builder"
grep -Fq -- '--signing-key=' "$builder"
grep -Fq 'PAYLOAD_PREFIX="micropanel-touch-${PAYLOAD_VARIANT}"' "$builder"
grep -Fq 'PAYLOAD_BUNDLE="$PAYLOAD_DIR/$PAYLOAD_PREFIX.mpupdate"' "$builder"
grep -Fq 'RELEASE_KEY_TOOL="$BOARD_DIR/packages/micropanel-touch-release-key.sh"' "$builder"
grep -Fq 'UPDATE_SIGNING_PUBLIC_KEY="$RELEASE_SIGNING_PUBLIC_KEY"' "$builder"
grep -Fq 'UPDATE_RELEASE_URL_TEMPLATE=' "$builder"
grep -Fq 'IMAGE_VERSION="$VERSION"' "$builder"

# Stage 2b bundle format: fixed member order, rootfs last, always signed.
grep -Fq 'tar --format=ustar --owner=0 --group=0 --numeric-owner --mtime=@0 \' "$payload_generator"
grep -Fq '    manifest manifest.sig boot.tar rootfs.img.xz' "$payload_generator"
grep -Eq '^format=2$' "$payload_generator"
grep -Fq 'asset_prefix="micropanel-touch-${variant}"' "$payload_generator"
grep -Fq '"$release_key_tool" sign "$work/bundle/manifest" "$work/bundle/manifest.sig"' "$payload_generator"
grep -Fq '"$release_key_tool" verify "$work/bundle/manifest" "$work/bundle/manifest.sig"' "$payload_generator"
if grep -Eq '^format=1$' "$payload_generator"; then
    echo 'payload generator must publish format=2 bundles only' >&2
    exit 1
fi
grep -Fq 'openssl genpkey -algorithm ed25519' "$release_key_tool"
grep -Fq 'openssl pkeyutl -sign -inkey "$key_path" -rawin' "$release_key_tool"
grep -Fq '/etc/micropanel-touch/release-signing' "$release_key_tool"

# The finalizer bakes the Stage 4 groundwork into every A/B image.
grep -Fq 'install_update_source_config "$root_mount"' "$finalizer"
grep -Fq 'update-signing-key.pub' "$finalizer"
grep -Fq 'update-source.conf' "$finalizer"
grep -Fq 'IMAGE_VERSION=%s' "$finalizer"
grep -Fq 'IMAGE_VERSION=' "$verifier"
grep -Fq 'update-signing-key.pub' "$verifier"

grep -Fq 'root=LABEL=@MICROPANEL_SLOT@' "$payload_generator"
grep -Fq 'e2label "${loop}p5" ""' "$payload_generator"
grep -Fq 'restore_source_root_label' "$payload_generator"
grep -Fq 'source p5 is label-neutral; this run will restore MP_ROOT_A' "$payload_generator"
grep -Fq 'dd if="${loop}p5" bs=8M status=progress' "$payload_generator"
if grep -Fq 'ext4_volume_label_offset' "$payload_generator"; then
    echo 'payload generator must not edit ext4 superblock bytes directly' >&2
    exit 1
fi
grep -Fq 'mkfifo "$hash_fifo" "$count_fifo"' "$payload_generator"
grep -Fq 'wait "$hash_pid"' "$payload_generator"

# V5-01: every cleanup handler disarms its own traps before doing any work, so
# a signal cannot re-enter it through EXIT.
for script in "$payload_generator" "$selector"; do
    cleanup_line=$(grep -nE '^(cleanup|restore_boot_state)\(\) \{' "$script" | head -1 | cut -d: -f1)
    disarm_line=$(grep -nFx '    trap - EXIT HUP INT TERM' "$script" | head -1 | cut -d: -f1)
    [ -n "$cleanup_line" ] && [ -n "$disarm_line" ] && [ "$disarm_line" -gt "$cleanup_line" ] && \
        [ "$((disarm_line - cleanup_line))" -le 6 ] || {
        echo "cleanup handler does not disarm its traps first: $script" >&2
        exit 1
    }
done
grep -Fq 'PANEL_VARIANT=piscreen' "$repo_root/board-configs/micropanel-touch/packages/micropanel-touch-hook.sh"
grep -Fqx 'DEFAULT_PANEL_VARIANT=piscreen' "$repo_root/board-configs/micropanel-touch/board.conf"
base_app_hook=$(grep '^packages/micropanel-touch-hook.sh|' \
    "$repo_root/board-configs/micropanel-touch/hooks.txt")
luckfox_app_hook=$(grep '^packages/micropanel-touch-hook.sh|' \
    "$repo_root/board-configs/micropanel-touch/hooks-luckfox-ctp.txt")
[ "$base_app_hook" = "$luckfox_app_hook" ] || {
    echo 'default and Luckfox hook lists pin different micropanel-touch revisions' >&2
    exit 1
}
printf '%s\n' "$base_app_hook" | grep -Fq '|${MICROPANEL_TOUCH_REVISION}|'
grep -Fq 'resolved_revision=$(git -C "$source_root" rev-parse HEAD)' \
    "$repo_root/board-configs/micropanel-touch/packages/micropanel-touch-hook.sh"
grep -Fq 'verify_installed_app_revision "$root_mount"' "$finalizer"

# A release cannot silently use the old hook pin: its exact application
# revision is mandatory and the builder rejects an omitted pin before preflight
# or any expensive build stage begins.
missing_revision_output=$("$builder" --board=micropanel-touch --variant=luckfox-ctp \
    --layout=ab --version=fixture --dry-run 2>&1 || true)
printf '%s\n' "$missing_revision_output" | \
    grep -Fq 'MicroPanel Touch builds require --app-revision=<40-character lowercase micropanel-touch commit> or --app-ref=<branch-or-tag>'
conflicting_app_source_output=$("$builder" --board=micropanel-touch --variant=luckfox-ctp \
    --layout=ab --version=fixture --dry-run \
    --app-revision=0123456789012345678901234567890123456789 --app-ref=main 2>&1 || true)
printf '%s\n' "$conflicting_app_source_output" | \
    grep -Fq 'use exactly one of --app-revision=<40-character lowercase micropanel-touch commit> or --app-ref=<branch-or-tag>'

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
