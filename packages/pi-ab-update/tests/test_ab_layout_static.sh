#!/bin/sh
set -eu

repo_root=$(unset CDPATH; cd -- "$(dirname -- "$0")/../../.." && pwd)
engine="$repo_root/packages/pi-ab-update"
board="$repo_root/board-configs/micropanel-touch"
finalizer="$engine/ab-finalize-layout.sh"
selector="$engine/ab-slot-selector"
skeleton="$board/packages/micropanel-touch-data-skeleton.sh"
verifier="$engine/ab-verify-image.sh"
payload_generator="$engine/ab-make-payload.sh"
release_key_tool="$engine/ab-release-key.sh"
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
grep -Fqx 'AB_LAYOUT=0' "$board/board.conf"
grep -Fqx 'SLOT_COMPATIBLE_BOARDS="pi4"' "$board/board.conf"
grep -Fqx 'xz-utils' "$board/runtime-deps.txt"
# Stage 4 needs these on the device: curl to fetch, openssl to verify, and the
# CA bundle for an https release server.
grep -Fqx 'curl' "$board/runtime-deps.txt"
grep -Fqx 'openssl' "$board/runtime-deps.txt"
grep -Fqx 'ca-certificates' "$board/runtime-deps.txt"
grep -Fqx 'util-linux' "$board/runtime-deps.txt"
grep -Fq 'requires EXPAND_ROOT=0; first-boot root expansion would corrupt the A/B partition layout' "$builder"
grep -Fq 'for tool in sfdisk fdisk mkfs.ext4 mkfs.vfat e2fsck resize2fs e2label blkid blockdev mount; do' "$builder"
grep -Fq "bash \"\$ab_static_test\"" "$builder"
grep -Fq -- '--payload requires --layout=ab' "$builder"
grep -Fq -- '--app-revision=SHA' "$builder"
grep -Fq -- '--app-ref=REF' "$builder"
grep -Fq 'resolve_micropanel_touch_revision()' "$builder"
grep -Fq 'resolved=$(git_remote_rev "$MICROPANEL_TOUCH_APP_REPO" "$MICROPANEL_TOUCH_REF")' "$builder"
grep -Fq 'MicroPanel Touch builds require --app-revision=<40-character lowercase micropanel-touch commit> or --app-ref=<branch-or-tag>' "$builder"
grep -Fq 'MICROPANEL_TOUCH_APP_REPO="${MICROPANEL_TOUCH_APP_REPO:-}" "$IMAGER"' "$builder"
grep -Fq 'MICROPANEL_TOUCH_REVISION="$MICROPANEL_TOUCH_REVISION" \' "$builder"
grep -Fq 'AB_MANIFEST_PATH="${AB_MANIFEST_PATH:-}" AB_ASSERTIONS="$AB_ASSERTIONS_PATH" \' "$builder"
grep -Fq 'MICROPANEL_TOUCH_REVISION="$MICROPANEL_TOUCH_REVISION" \' "$builder"
grep -Fq 'AB_ENGINE_DIR="$SCRIPT_DIR/packages/pi-ab-update"' "$builder"


# The imager parses the hook list in its own process, so every ${VAR} a hook
# list references must be handed to it explicitly. A missing one used to fail
# silently: the imager raised its error inside a command substitution, which
# captured the message, and its cleanup trap then returned success.
imager_invocation=$(awk '
    { window[NR % 8] = $0 }
    /"\$IMAGER" \\$/ {
        for (i = NR - 7; i <= NR; ++i) if (i > 0) print window[i % 8]
    }' "$builder")
[ -n "$imager_invocation" ] || { echo 'no imager invocation found in the builder' >&2; exit 1; }
for hook_list in "$board/hooks.txt" \
                 "$board/hooks-luckfox-ctp.txt"; do
    hook_variables=$(sed -n 's/.*${\([A-Za-z_][A-Za-z0-9_]*\)}.*/\1/p' "$hook_list" | sort -u)
    for hook_variable in $hook_variables; do
        printf '%s\n' "$imager_invocation" | grep -Fq "$hook_variable=" || {
            echo "hook list uses \${$hook_variable} but the builder does not pass it to the imager: $hook_list" >&2
            exit 1
        }
    done
done
# ...and the imager must report and propagate its own failures.
grep -Fq 'exit "$exit_code"' "$repo_root/custom-pi-imager/custom-pi-imager.sh"
grep -Fq '[ERROR]${NC} $1" >&2' "$repo_root/custom-pi-imager/custom-pi-imager.sh"
grep -Fq 'apps stage produced no image' "$builder"

# The extracted engine is board-agnostic: no engine file may name a product.
# The board profile beside it supplies every product-specific value.
for engine_script in "$engine"/ab-*; do
    case "$engine_script" in *.service) continue ;; esac
    if grep -Eq 'micropanel|MicroPanel' "$engine_script"; then
        echo "engine script names a product: $engine_script" >&2
        grep -nE 'micropanel|MicroPanel' "$engine_script" >&2
        exit 1
    fi
done
[ -f "$board/ab-update.conf" ] || { echo 'board profile ab-update.conf is missing' >&2; exit 1; }
[ -x "$board/ab-assertions.sh" ] || { echo 'board assertions script is missing' >&2; exit 1; }
grep -Fqx 'AB_PRODUCT=micropanel-touch' "$board/ab-update.conf"
grep -Fq 'AB_HEALTH_UNITS=micropanel-touch.service micropanel-touch-privileged.service' "$board/ab-update.conf"
grep -Fq 'AB_HEALTH_HOOK=/usr/lib/micropanel-touch/update-health' "$board/ab-update.conf"
grep -Fqx 'AB_PRODUCT="micropanel-touch"' "$board/board.conf"
grep -Fqx 'POST_IMAGE_HOOK=../../packages/pi-ab-update/ab-finalize-layout.sh' "$board/board.conf"
# The engine installs itself into the image; the board ships no copy.
grep -Fq 'install_update_engine "$root_mount"' "$finalizer"
grep -Fq '/usr/local/sbin/ab-system-update' "$finalizer"
grep -Fq '/usr/local/sbin/ab-update-commit' "$finalizer"
grep -Fq 'multi-user.target.wants/ab-update-commit.service' "$finalizer"
grep -Fq 'ab-update.conf' "$finalizer"
# Stage 3: the reset is part of the engine and installs itself with it.
bash -n "$engine/ab-factory-reset" "$engine/ab-factory-reset-boot"
[ -x "$engine/ab-factory-reset" ] && [ -x "$engine/ab-factory-reset-boot" ] || {
    echo 'factory reset scripts are missing or not executable' >&2; exit 1; }
grep -Fq '/usr/local/sbin/ab-factory-reset' "$finalizer"
grep -Fq 'sysinit.target.wants/ab-factory-reset.service' "$finalizer"
grep -Fq 'AB_RESET_BEFORE' "$finalizer"
grep -Fq 'ab-factory-reset' "$verifier"
grep -Fq 'AB_RESET_BEFORE=' "$board/ab-update.conf"
grep -Fq 'AB_RESET_SEED=' "$board/ab-update.conf"
# The wipe refuses anything that is not its own writable mount: a durable
# partition that failed to mount would otherwise take the running root with it.
grep -Fq 'it is not a mount point' "$engine/ab-factory-reset-boot"
grep -Fq 'it is not mounted read-write' "$engine/ab-factory-reset-boot"
grep -Fq 'refusing an unsafe data mount path' "$engine/ab-factory-reset-boot"
# The marker is cleared last, so an interrupted reset repeats rather than
# leaving half a device.
marker_clear_line=$(grep -nF 'rm -f -- "$marker"' "$engine/ab-factory-reset-boot" | cut -d: -f1)
skeleton_line=$(grep -nF 'unable to recreate the durable skeleton' "$engine/ab-factory-reset-boot" | head -1 | cut -d: -f1)
[ "$skeleton_line" -lt "$marker_clear_line" ]
# The request writes a marker and reboots; it never wipes anything itself.
! grep -Fq 'rm -rf' "$engine/ab-factory-reset"
grep -Fq '"$reboot_command"' "$engine/ab-factory-reset"
# The marker is durable the moment it is written, so a request cancelled before
# the reboot is committed to must withdraw it rather than leave a reset armed.
# The window is milliseconds wide - too small to drive from outside without
# wedging the script open with test-only plumbing - so it is pinned here.
grep -Fq 'withdraw_marker()' "$engine/ab-factory-reset"
grep -Fq 'trap withdraw_marker HUP INT TERM' "$engine/ab-factory-reset"
withdraw_line=$(grep -nF 'trap withdraw_marker HUP INT TERM' "$engine/ab-factory-reset" | cut -d: -f1)
disarm_line=$(grep -nFx 'trap - HUP INT TERM' "$engine/ab-factory-reset" | tail -1 | cut -d: -f1)
marker_line=$(grep -nF 'mv -f "$temporary" "$marker"' "$engine/ab-factory-reset" | cut -d: -f1)
[ "$withdraw_line" -lt "$marker_line" ]
[ "$marker_line" -lt "$disarm_line" ]
# A detached reboot that fails must leave a trace: otherwise the device resets
# at whatever unrelated reboot comes next, possibly days later.
grep -Fq 'scheduled reboot failed' "$engine/ab-factory-reset"

# --- Stage 4: the check tool and the release source -----------------------
bash -n "$engine/ab-update-check"
[ -x "$engine/ab-update-check" ] || {
    echo "missing or non-executable update check: $engine/ab-update-check" >&2; exit 1; }
grep -Fq '/usr/local/sbin/ab-update-check' "$finalizer"
grep -Fq 'ab-update-check' "$verifier"
# The check verifies the manifest signature before it reads any field of it,
# so an attacker-supplied manifest never reaches the comparison logic.
awk '
    /openssl pkeyutl -verify/ { verified = NR }
    /^offered_version=\$\(read_exact_value/ { parsed = NR }
    END { exit !(verified && parsed && verified < parsed) }
' "$engine/ab-update-check"
# It fetches the manifest pair only: discovering that a release is already
# installed must not cost a payload download.
! grep -Fq 'BUNDLE_URL' "$engine/ab-update-check"
# The release source is board-authored and overridable per build; the URLs stay
# version-less because the version lives inside the signed manifest.
grep -Fq -- '--release-url-template=*' "$builder"
grep -Fq 'RELEASE_URL_TEMPLATE="${ARG_RELEASE_URL_TEMPLATE:-${MICROPANEL_TOUCH_RELEASE_URL_TEMPLATE:-}}"' "$builder"
grep -Fq '@ASSET@' "$builder"
grep -Fq '@ASSET@' "$board/board.conf"

# Elapsed-time checks must be monotonic. An RTC-less appliance boots in the
# past and jumps forward when NTP syncs - and a factory reset enlarges that
# jump - which would otherwise look like minutes of elapsed time that never
# happened: a spurious stall abort mid-write, or a commit deadline that expires
# early and drops a healthy candidate.
for timed_script in "$engine/ab-system-update" "$engine/ab-update-commit"; do
    grep -Fq 'monotonic_seconds()' "$timed_script"
    grep -Fq '/proc/uptime' "$timed_script"
    if grep -Fq 'date +%s' "$timed_script"; then
        echo "wall-clock elapsed time in $timed_script" >&2
        exit 1
    fi
done

# The health predicate is data plus one hook, not hardcoded unit names.
grep -Fq 'AB_HEALTH_UNITS' "$engine/ab-update-commit"
grep -Fq 'health_hook' "$engine/ab-update-commit"

# V5-05: exactly one place names the application/release repository, and it is
# also where the reserved Stage 4 OTA URL template lives.
grep -Fqx 'MICROPANEL_TOUCH_APP_REPO="https://github.com/hackboxguy/micropanel-touch.git"' \
    "$board/board.conf"
grep -Fq 'MICROPANEL_TOUCH_RELEASE_URL_TEMPLATE=' \
    "$board/board.conf"
grep -Fq 'releases/latest/download/@ASSET@' \
    "$board/board.conf"
duplicate_repo_references=$(grep -rlF 'github.com/hackboxguy/micropanel-touch' \
    "$repo_root/board-configs/micropanel-touch" "$builder" | grep -v '/tests/' | sort)
[ "$duplicate_repo_references" = "$board/board.conf" ] || {
    echo 'the micropanel-touch repository URL is duplicated outside board.conf:' >&2
    printf '%s\n' "$duplicate_repo_references" >&2
    exit 1
}
grep -Fq 'PAYLOAD_VARIANT="${VARIANT:-${DEFAULT_PANEL_VARIANT:-default}}"' "$builder"
grep -Fq -- '--signing-key=' "$builder"
grep -Fq 'PAYLOAD_PREFIX="${AB_PRODUCT:-$BOARD}-${PAYLOAD_VARIANT}"' "$builder"
grep -Fq 'PAYLOAD_BUNDLE="$PAYLOAD_DIR/$PAYLOAD_PREFIX.mpupdate"' "$builder"
grep -Fq 'RELEASE_KEY_TOOL="$AB_ENGINE_DIR/ab-release-key.sh"' "$builder"
grep -Fq 'UPDATE_SIGNING_PUBLIC_KEY="$RELEASE_SIGNING_PUBLIC_KEY"' "$builder"
grep -Fq 'UPDATE_RELEASE_URL_TEMPLATE=' "$builder"
grep -Fq 'IMAGE_VERSION="$VERSION"' "$builder"

# Stage 2b bundle format: fixed member order, rootfs last, always signed.
grep -Fq 'tar --format=ustar --owner=0 --group=0 --numeric-owner --mtime=@0 \' "$payload_generator"
grep -Fq '    manifest manifest.sig boot.tar rootfs.img.xz' "$payload_generator"
grep -Eq '^format=2$' "$payload_generator"
# O-02: the detached signature is published as its own asset from the first
# format=2 release, so Stage 4's check step has something to verify the tiny
# manifest against without fetching the bundle.
grep -Fq 'manifest_signature="$output_dir/${asset_prefix}.manifest.sig"' "$payload_generator"
grep -Fq 'mv -f -- "$signature_publish" "$manifest_signature"' "$payload_generator"
grep -Fq 'MANIFEST_SIG_URL=' "$finalizer"
grep -Fq 'MANIFEST_SIG_URL=' "$verifier"
# O-05: releases cannot silently share a payload directory.
grep -Fq 'PAYLOAD_DIR="${ARG_PAYLOAD_DIR:-$OUT_DIR/payloads/$VERSION}"' "$builder"
grep -Fq 'already holds release' "$payload_generator"
grep -Fq 'asset_prefix="${product}-${variant}"' "$payload_generator"
grep -Fq '"$release_key_tool" sign "$work/bundle/manifest" "$work/bundle/manifest.sig"' "$payload_generator"
grep -Fq '"$release_key_tool" verify "$work/bundle/manifest" "$work/bundle/manifest.sig"' "$payload_generator"
if grep -Eq '^format=1$' "$payload_generator"; then
    echo 'payload generator must publish format=2 bundles only' >&2
    exit 1
fi
grep -Fq 'openssl genpkey -algorithm ed25519' "$release_key_tool"
grep -Fq 'openssl pkeyutl -sign -inkey "$key_path" -rawin' "$release_key_tool"
grep -Fq 'AB_RELEASE_KEY_DIR' "$release_key_tool"
# The board keeps its existing key location, whose public half is already in
# flashed images; only a board without one takes the generic default.
grep -Fqx 'AB_RELEASE_KEY_DIR="/etc/micropanel-touch/release-signing"' "$board/board.conf"

# The finalizer bakes the Stage 4 groundwork into every A/B image.
grep -Fq 'install_update_source_config "$root_mount"' "$finalizer"
grep -Fq 'update-signing-key.pub' "$finalizer"
grep -Fq 'update-source.conf' "$finalizer"
grep -Fq 'AB_RELEASE_KEY_DIR' "$builder"
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
grep -Fq 'PANEL_VARIANT=piscreen' "$board/packages/micropanel-touch-hook.sh"
grep -Fqx 'DEFAULT_PANEL_VARIANT=piscreen' "$board/board.conf"
base_app_hook=$(grep '^packages/micropanel-touch-hook.sh|' \
    "$board/hooks.txt")
luckfox_app_hook=$(grep '^packages/micropanel-touch-hook.sh|' \
    "$board/hooks-luckfox-ctp.txt")
[ "$base_app_hook" = "$luckfox_app_hook" ] || {
    echo 'default and Luckfox hook lists pin different micropanel-touch revisions' >&2
    exit 1
}
printf '%s\n' "$base_app_hook" | grep -Fq '|${MICROPANEL_TOUCH_REVISION}|'
grep -Fq 'resolved_revision=$(git -C "$source_root" rev-parse HEAD)' \
    "$board/packages/micropanel-touch-hook.sh"
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
normal_a=$(AB_BOOT_CONFIG_TEMPLATE="$template" "$selector" render-normal A)
normal_b=$(AB_BOOT_CONFIG_TEMPLATE="$template" "$selector" render-normal B)
candidate_a=$(AB_BOOT_CONFIG_TEMPLATE="$template" "$selector" render-candidate A)
expected_normal_b=$(printf 'os_prefix=B/\ndtoverlay=vc4-kms-v3d')
expected_normal_a=$(printf 'os_prefix=A/\ndtoverlay=vc4-kms-v3d')
expected_candidate_a=$(printf 'os_prefix=A/\ndtoverlay=vc4-kms-v3d')
[ "$normal_a" = "$expected_normal_a" ]
[ "$normal_b" = "$expected_normal_b" ]
[ "$candidate_a" = "$expected_candidate_a" ]
