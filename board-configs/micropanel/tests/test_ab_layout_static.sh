#!/bin/sh
# micropanel A/B static contract. build-image.sh runs this in preflight for
# every --layout=ab build (so it must never invoke an A/B dry-run itself), and
# it runs standalone: sh board-configs/micropanel/tests/test_ab_layout_static.sh
#
# The engine's own contract is packages/pi-ab-update/tests/; this pins what is
# micropanel's: the board profile, the A/B-only switches that keep the
# single-slot product unchanged, and the lists the A/B image is built from.
set -eu

repo_root=$(unset CDPATH; cd -- "$(dirname -- "$0")/../../.." && pwd)
engine="$repo_root/packages/pi-ab-update"
board="$repo_root/board-configs/micropanel"
builder="$repo_root/build-image.sh"
finalizer="$engine/ab-finalize-layout.sh"
skeleton="$board/packages/micropanel-data-skeleton.sh"
assertions="$board/ab-assertions.sh"
conf="$board/board.conf"
ab_conf="$board/ab-update.conf"

fail() { echo "micropanel A/B contract: $*" >&2; exit 1; }

bash -n "$skeleton" "$assertions" "$finalizer" "$builder"
[ -x "$skeleton" ] || fail "skeleton is not executable: $skeleton"
[ -x "$assertions" ] || fail "assertions are not executable: $assertions"

# --- board.conf: the A/B profile ------------------------------------------------
for line in \
    'AB_LAYOUT=0' \
    'AB_IMAGE_SIZE_MB=15000' \
    'AB_ROOT_PARTITION_MB=5120' \
    'AB_FACTORY_PARTITION_MB=2048' \
    'SLOT_COMPATIBLE_BOARDS="pi4"' \
    'AB_PRODUCT="micropanel"' \
    'AB_UPDATE_CONF=ab-update.conf' \
    'AB_ASSERTIONS=ab-assertions.sh' \
    'AB_MANIFEST_PATH="/home/pi/micropanel/share/micropanel/image-manifest.env"' \
    'AB_APP_ACCOUNT="pi"' \
    'AB_APP_REVISION_KEY="MICROPANEL_REVISION"' \
    'AB_RELEASE_KEY_DIR="/etc/micropanel/release-signing"' \
    'DEFAULT_PANEL_VARIANT=base' \
    'DATA_SKELETON=packages/micropanel-data-skeleton.sh' \
    'RUNTIME_DEPS_ab=runtime-deps-ab.txt' \
    'HOOK_LIST_ab=hooks-ab.txt' \
    'POST_IMAGE_HOOK_ab=../../packages/pi-ab-update/ab-finalize-layout.sh'; do
    grep -Fqx "$line" "$conf" || fail "board.conf lacks: $line"
done
grep -Eq '^AB_BOOT_PARTITION_MB=[1-9][0-9]*$' "$conf" || fail 'board.conf lacks AB_BOOT_PARTITION_MB'
grep -Eq '^AB_RELEASE_URL_TEMPLATE="https://[^"]*@ASSET@"$' "$conf" || \
    fail 'AB_RELEASE_URL_TEMPLATE must be an https URL containing @ASSET@'

# The single-slot product must not change: everything A/B-only is a VAR_ab
# override. A plain POST_IMAGE_HOOK would make the finalizer append a /data
# partition to the 8 GB single-slot image; a plain slim hook would purge it.
for key in POST_IMAGE_HOOK IMAGE_SLIM_HOOK SLIM_REMOVE SLIM_MAX_ROOT_MB DATA_PARTITION_MB; do
    if grep -Eq "^$key=" "$conf"; then
        fail "$key is set for every layout; A/B-only inputs must be ${key}_ab"
    fi
done
grep -Fqx 'RUNTIME_DEPS=runtime-deps.txt' "$conf" || fail 'single-slot runtime deps moved'
grep -Fqx 'HOOK_LIST=hooks.txt' "$conf" || fail 'single-slot hook list moved'
# EXPAND_ROOT is part of the shared qt-bookworm base stamp; setting it here
# would rebuild the base under every other board of the profile. The builder
# forces the A/B apps stage off instead, and the finalizer strips the init=.
if grep -Eq '^EXPAND_ROOT=' "$conf"; then
    fail 'EXPAND_ROOT must stay the builder default on a shared-base board'
fi
grep -Fqx 'BASE_PROFILE=qt-bookworm' "$conf" || fail 'board left the qt-bookworm profile'

# ...and the builder mechanisms those rules rely on.
grep -Fq 'for _v in RUNTIME_DEPS HOOK_LIST POST_IMAGE_HOOK IMAGE_SLIM_HOOK SLIM_REMOVE SLIM_MAX_ROOT_MB; do' "$builder" || \
    fail 'builder lost the per-layout VAR_ab overrides'
grep -Fq '_lkey="${_v}_ab"' "$builder" || fail 'builder lost the per-layout VAR_ab overrides'
grep -Fq 'if [ "$AB_LAYOUT" = "1" ]; then APPS_EXPAND_ROOT=0; else APPS_EXPAND_ROOT="$EXPAND_ROOT"; fi' "$builder" || \
    fail 'builder no longer forces the A/B apps stage to --no-expand-root'
grep -Fq '"expand-root:$APPS_EXPAND_ROOT"' "$builder" || fail 'apps stamp lost APPS_EXPAND_ROOT'
grep -Fq -- '--no-expand-root") \' "$builder" || fail 'imager no longer receives --no-expand-root'
grep -Fq '    strip_first_boot_init "$boot_mount/cmdline.txt"' "$finalizer" || \
    fail 'finalizer no longer strips first-boot init='
grep -Fq 'RELEASE_URL_TEMPLATE="${ARG_RELEASE_URL_TEMPLATE:-${AB_RELEASE_URL_TEMPLATE:-' "$builder" || \
    fail 'builder ignores AB_RELEASE_URL_TEMPLATE'
# Board files the finalizer consumes must invalidate the apps stage.
grep -Fq '[ "$DATA_SKELETON_PATH" != "none" ] && in+=("file:$DATA_SKELETON_PATH")' "$builder" || \
    fail 'apps stamp does not track the data skeleton'
grep -Fq 'in+=("file:$AB_UPDATE_CONF_PATH")' "$builder" || \
    fail 'apps stamp does not track ab-update.conf'

# --- The layout plan ---------------------------------------------------------------
boot_mb=$(sed -n 's/^AB_BOOT_PARTITION_MB=\([0-9]*\)$/\1/p' "$conf")
plan=$(AB_IMAGE_SIZE_MB=15000 AB_BOOT_PARTITION_MB="$boot_mb" AB_ROOT_PARTITION_MB=5120 \
    AB_FACTORY_PARTITION_MB=2048 "$finalizer" --print-ab-layout)
for line in 'layout=ab' 'image_size_mib=15000' \
    "p1=MP_BOOT_A:${boot_mb}MiB:vfat" "p2=MP_BOOT_B:${boot_mb}MiB:vfat-reserved" \
    'p5=MP_ROOT_A:5120MiB:ext4' 'p6=MP_ROOT_B:5120MiB:ext4-reserved' \
    'p7=MP_FACTORY:2048MiB:ext4-reserved' 'p8=MICROPANEL_DATA:remainder:ext4' \
    'normal_selector=os_prefix=A/' 'tryboot_selector=os_prefix=B/'; do
    printf '%s\n' "$plan" | grep -Fqx "$line" || fail "layout plan lacks: $line"
done
# /data holds kodi state and disptool results; keep at least 2 GiB of it after
# the fixed slots (each logical partition costs a 1 MiB alignment window).
data_mb=$((15000 - 1 - 2 * boot_mb - 1 - 2 * 5120 - 2048 - 4))
[ "$data_mb" -ge 2048 ] || fail "only ${data_mb} MiB left for /data"
[ "$boot_mb" -eq 256 ] || [ "$boot_mb" -eq 384 ] || fail "boot slot is ${boot_mb} MiB; the decision was 256 or 384"

# --- ab-update.conf: strict KEY=value, consistent with board.conf ------------------
bad_lines=$(grep -Ev '^([[:space:]]*#.*|[[:space:]]*|AB_[A-Z_]+=[^[:space:]].*)$' "$ab_conf" || true)
[ -z "$bad_lines" ] || fail "ab-update.conf has lines the engine will not parse: $bad_lines"
grep -Fqx 'AB_PRODUCT=micropanel' "$ab_conf" || fail 'ab-update.conf AB_PRODUCT'
grep -Fqx 'AB_MANIFEST=/home/pi/micropanel/share/micropanel/image-manifest.env' "$ab_conf" || \
    fail 'ab-update.conf AB_MANIFEST disagrees with board.conf AB_MANIFEST_PATH'
grep -Fqx 'AB_VARIANT_KEY=IMAGE_VARIANT' "$ab_conf" || fail 'ab-update.conf AB_VARIANT_KEY'
grep -Fqx 'AB_APP_ACCOUNT=pi' "$ab_conf" || fail 'ab-update.conf AB_APP_ACCOUNT'
grep -Fqx 'AB_STATE_DIR=/data/micropanel-system' "$ab_conf" || fail 'ab-update.conf AB_STATE_DIR'
grep -Fq 'AB_RESET_BEFORE=' "$ab_conf" || fail 'ab-update.conf AB_RESET_BEFORE'
grep -Fq 'AB_RESET_SEED=' "$ab_conf" || fail 'ab-update.conf AB_RESET_SEED'
health_units=$(sed -n 's/^AB_HEALTH_UNITS=//p' "$ab_conf")
[ -n "$health_units" ] || fail 'AB_HEALTH_UNITS is empty'
# A health unit nothing enables never starts, and every update falls back.
for unit in $health_units; do
    grep -Eq "systemctl enable [^|;]*${unit}" "$board/hooks.txt" "$board/packages/"*.sh || \
        fail "health unit $unit is not enabled by any micropanel hook"
    printf '%s\n' "$(sed -n 's/^AB_RESET_BEFORE=//p' "$ab_conf")" | grep -Fqw "$unit" || \
        fail "health unit $unit reads /data but is not in AB_RESET_BEFORE"
done
# The engine is board-agnostic; nothing in it may name this product.
for engine_script in "$engine"/ab-*; do
    case "$engine_script" in *.service) continue ;; esac
    if grep -Eq 'micropanel|MicroPanel' "$engine_script"; then
        fail "engine script names a product: $engine_script"
    fi
done

# --- Variant: the published asset names and the manifest must agree ----------------
grep -Fq "require grep -Fqx 'IMAGE_VARIANT=base'" "$assertions" || \
    fail 'assertions must pin IMAGE_VARIANT=base to match DEFAULT_PANEL_VARIANT'

# --- Runtime deps: the A/B list is a superset of the single-slot one ---------------
strip_list() { sed -e 's/#.*//' -e 's/[[:space:]]//g' "$1" | sed '/^$/d'; }
for package in $(strip_list "$board/runtime-deps.txt"); do
    strip_list "$board/runtime-deps-ab.txt" | grep -Fqx "$package" || \
        fail "runtime-deps-ab.txt lacks $package from runtime-deps.txt"
done
for package in overlayroot xz-utils curl openssl ca-certificates util-linux e2fsprogs dosfstools; do
    strip_list "$board/runtime-deps-ab.txt" | grep -Fqx "$package" || \
        fail "runtime-deps-ab.txt lacks $package, which the A/B engine needs on the device"
done

# --- Hook lists: the A/B list is hooks.txt plus the appliance conversion, last -----
hook_lines() { grep -Ev '^[[:space:]]*(#|$)' "$1"; }
single_hooks=$(hook_lines "$board/hooks.txt")
single_count=$(printf '%s\n' "$single_hooks" | wc -l)
ab_prefix=$(hook_lines "$board/hooks-ab.txt" | head -n "$single_count")
[ "$ab_prefix" = "$single_hooks" ] || fail 'hooks-ab.txt no longer starts with exactly the lines of hooks.txt'
ab_extra=$(hook_lines "$board/hooks-ab.txt" | tail -n +"$((single_count + 1))")
for extra in $ab_extra; do
    [ "$extra" = 'packages/micropanel-appliance-hook.sh' ] || \
        fail "hooks-ab.txt has an unexpected A/B-only hook: $extra"
done

# The imager parses hook lists in its own process: every ${VAR} they use must be
# handed to it (in the invocation) or exported by the builder.
imager_invocation=$(awk '
    { window[NR % 8] = $0 }
    /"\$IMAGER" \\$/ {
        for (i = NR - 7; i <= NR; ++i) if (i > 0) print window[i % 8]
    }' "$builder")
for hook_list in "$board/hooks.txt" "$board/hooks-ab.txt"; do
    for hook_variable in $(hook_lines "$hook_list" | sed -n 's/.*${\([A-Za-z_][A-Za-z0-9_]*\)}.*/\1/p' | sort -u); do
        printf '%s\n' "$imager_invocation" | grep -Fq "$hook_variable=" && continue
        grep -Eq "^export $hook_variable=" "$builder" && continue
        fail "hook list uses \${$hook_variable} but the builder does not pass it to the imager: $hook_list"
    done
done

# --- The skeleton, for real, where we may chown ------------------------------------
# Preflight of a real build runs as root, so this part runs before every A/B
# image; a non-root run (dry-run, standalone) skips it.
if [ "$(id -u)" -eq 0 ]; then
    data=$(mktemp -d)
    trap 'rm -rf "$data"' EXIT HUP INT TERM
    "$skeleton" --root "$data" --uid 1000 --gid 1000
    for expected in 'micropanel 1000:1000:755' 'micropanel/ssh-host-keys 0:0:700' \
        'micropanel/var-lib-micropanel 0:0:755' 'micropanel-system 0:0:700' \
        'disp-settings 0:0:755' 'kodi 1000:1000:755' 'disptool-results 1000:1000:755' \
        'NetworkManager/system-connections 0:0:700'; do
        path=${expected% *}
        [ "$(stat -c '%u:%g:%a' "$data/$path")" = "${expected#* }" ] || \
            fail "skeleton: $path is $(stat -c '%u:%g:%a' "$data/$path"), expected ${expected#* }"
        grep -Fq "\"$path\")\" = " "$assertions" || grep -Fq "/$path\")\" = " "$assertions" || \
            fail "ab-assertions.sh does not check skeleton path $path"
    done
    # Idempotent: the factory reset re-runs it over a wiped mount.
    "$skeleton" --root "$data" --uid 1000 --gid 1000
fi

echo "micropanel A/B static contract: ok"
