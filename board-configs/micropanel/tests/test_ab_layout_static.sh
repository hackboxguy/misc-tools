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
[ "$ab_extra" = 'packages/micropanel-appliance-hook.sh' ] || \
    fail "hooks-ab.txt must be hooks.txt plus exactly packages/micropanel-appliance-hook.sh, last; A/B-only lines: $ab_extra"

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

# --- A/B slimming --------------------------------------------------------------------
slim_hook="$board/packages/micropanel-slim.sh"
slim_list="$board/slim-remove.txt"
grep -Fqx 'IMAGE_SLIM_HOOK_ab=packages/micropanel-slim.sh' "$conf" || fail 'board.conf lacks IMAGE_SLIM_HOOK_ab'
grep -Fqx 'SLIM_REMOVE_ab=slim-remove.txt' "$conf" || fail 'board.conf lacks SLIM_REMOVE_ab'
grep -Eq '^SLIM_MAX_ROOT_MB_ab=[1-9][0-9]*([[:space:]]+#.*)?$' "$conf" || fail 'board.conf lacks a numeric SLIM_MAX_ROOT_MB_ab'
[ -x "$slim_hook" ] || fail "slim hook missing or not executable: $slim_hook"
bash -n "$slim_hook"
for package in $(strip_list "$board/runtime-deps-ab.txt"); do
    if strip_list "$slim_list" | grep -Fqx "$package"; then
        fail "slim-remove.txt removes a declared runtime package: $package"
    fi
done
grep -Fq 'boot tree $((before_boot_kib / 1024)) MiB -> $((after_boot_kib / 1024)) MiB (x3 =' "$slim_hook" || \
    fail 'slim hook no longer prints the boot tree size'
grep -Fq 'AB_BOOT_PARTITION_MB="$([ "$AB_LAYOUT" = "1" ] && printf' "$builder" || \
    fail 'builder no longer passes the boot slot size to the slim hook'
# The custom kernel's files must be asserted after the stock-kernel purge.
for survivor in '"$boot/Image"' '"$boot/initramfs-custom"' '"$root_mount/boot/config-$release"' 'hh983-serializer.ko*'; do
    grep -Fq "$survivor" "$slim_hook" || fail "slim hook does not assert that $survivor survives"
done

# --- The appliance hook and its support files --------------------------------------
appliance="$board/packages/micropanel-appliance-hook.sh"
support="$board/packages/micropanel-appliance-hook.d"
[ -x "$appliance" ] || fail "appliance hook missing or not executable: $appliance"
bash -n "$appliance"
for tool in micropanel-restore-machine-id micropanel-restore-ssh-host-keys; do
    [ -x "$support/$tool" ] || fail "restore tool missing or not executable: $tool"
    sh -n "$support/$tool"
done
for unit in micropanel-machine-id.service micropanel-ssh-host-keys.service; do
    [ -f "$support/$unit" ] || fail "unit missing: $unit"
    grep -Fq "ExecStart=/usr/local/sbin/micropanel-restore-" "$support/$unit" || fail "$unit runs no restore tool"
    grep -Fq "\"\$support/$unit\" /etc/systemd/system/$unit" "$appliance" || fail "appliance hook does not install $unit"
done
grep -Fq 'systemctl enable micropanel-machine-id.service micropanel-ssh-host-keys.service' "$appliance" || \
    fail 'appliance hook does not enable the restore units'
# The config.txt include split: the hook points pi-config-txt.sh at the display
# file, emits the release-owned base, and hands the derived module configuration
# to a unit that runs every boot before anything that reads it or uses the drivers.
derive_unit="$support/micropanel-display-derive.service"
[ -f "$derive_unit" ] || fail "derive unit missing: $derive_unit"
grep -Fq -- '--apply-derived' "$derive_unit" || fail 'derive unit does not run --apply-derived'
grep -Fqx 'RequiresMountsFor=/boot/firmware' "$derive_unit" || fail 'derive unit does not wait for the boot partition'
for consumer in dip-switch-resolution.service micropanel.service als-dimmer.service; do
    grep -Eq "^Before=(.* )?$consumer( |$)" "$derive_unit" || fail "derive unit is not ordered before $consumer"
done
grep -Fq 'systemctl enable micropanel-display-derive.service' "$appliance" || fail 'appliance hook does not enable the derive unit'
grep -Fq 'rm -f /etc/modules-load.d/custom-drivers.conf' "$appliance" || fail 'appliance hook keeps the static driver list'
grep -Fq '"MICROPANEL_BOOT_CONFIG=$display_file" > /etc/default/micropanel' "$appliance" || \
    fail 'appliance hook does not write /etc/default/micropanel'
grep -Fq -- '--emit-base="$config"' "$appliance" || fail 'appliance hook does not emit the base config.txt'
grep -Fq "grep -q -- '--emit-base' \"\$pi_config\"" "$appliance" || \
    fail 'appliance hook does not refuse a pi-config-txt.sh that predates the split'

# The imager copies <hook>.d/ in as HOOK_SUPPORT_DIR, and the builder stamps it.
grep -Fq 'local support_dir="${hook_script%.sh}.d"' "$repo_root/custom-pi-imager/custom-pi-imager.sh" || \
    fail 'imager no longer copies hook support directories'
grep -Fq 'export HOOK_SUPPORT_DIR=' "$repo_root/custom-pi-imager/custom-pi-imager.sh" || \
    fail 'imager no longer exports HOOK_SUPPORT_DIR'
grep -Fq 'done < <(find "${hook_script%.sh}.d" -type f | LC_ALL=C sort)' "$builder" || \
    fail 'builder no longer stamps hook support files'
# The manifest: micropanel-hook.sh records what it built, only when the builder
# hands it AB_MANIFEST_PATH, which it does only for A/B builds.
grep -Fq 'AB_MANIFEST_PATH="$([ "$AB_LAYOUT" = "1" ] && printf' "$builder" || \
    fail 'builder passes AB_MANIFEST_PATH to single-slot hooks'
grep -Fq 'if [ -n "${AB_MANIFEST_PATH:-}" ]; then' "$board/packages/micropanel-hook.sh" || \
    fail 'micropanel-hook.sh records the manifest unconditionally'
grep -Fq "printf 'MICROPANEL_REVISION=%s\\n' \"\$(git -C /tmp/micropanel rev-parse HEAD)\"" \
    "$board/packages/micropanel-hook.sh" || fail 'micropanel-hook.sh no longer records its clone HEAD'

# Every unit that must wait for a factory reset exists in the image: shipped by
# the OS, enabled by an application hook, or created by the appliance hook.
os_units='NetworkManager.service'
for unit in $(sed -n 's/^AB_RESET_BEFORE=//p' "$ab_conf"); do
    printf '%s\n' $os_units | grep -Fqx "$unit" && continue
    [ -f "$support/$unit" ] && continue
    grep -Eq "(systemctl (enable|link) [^|;]*${unit%.service}(\.service)?|/${unit}( |$|;))" \
        "$board/hooks.txt" "$board/packages/"*.sh && continue
    fail "AB_RESET_BEFORE names $unit, which nothing installs or enables"
done
# Every bind the hook writes: the finalizer keeps it, and its consumer waits
# for the reset.
binds=$(grep -Ev '^[[:space:]]*(#|$)' "$support/fstab.binds")
[ -n "$binds" ] || fail 'fstab.binds is empty'
reset_before=" $(sed -n 's/^AB_RESET_BEFORE=//p' "$ab_conf") "
fstab_fixture=$(mktemp)
printf '%s\n' 'PARTUUID=x-02 / ext4 defaults 0 1' 'PARTUUID=x-01 /boot/firmware vfat defaults 0 2' > "$fstab_fixture"
printf '%s\n' "$binds" >> "$fstab_fixture"
# Run the finalizer's own fstab rewrite, not a copy of its rule.
eval "$(sed -n '/^replace_ab_fstab() {/,/^}/p' "$finalizer")"
fixture_root=$(mktemp -d)
install -d "$fixture_root/etc"
cp "$fstab_fixture" "$fixture_root/etc/fstab"
replace_ab_fstab "$fixture_root"
printf '%s\n' "$binds" | while IFS= read -r bind_line; do
    grep -Fqx -- "$bind_line" "$fixture_root/etc/fstab" || fail "the A/B finalizer drops the bind: $bind_line"
    case "$bind_line" in
        *x-systemd.after=ab-factory-reset.service*) ;;
        *) fail "bind does not wait for the factory reset: $bind_line" ;;
    esac
    consumer=$(printf '%s\n' "$bind_line" | sed -n 's/.*x-systemd\.before=\([^, ]*\).*/\1/p')
    [ -n "$consumer" ] || fail "bind names no consumer: $bind_line"
    case "$reset_before" in *" $consumer "*) ;; *) fail "bind consumer $consumer is not in AB_RESET_BEFORE" ;; esac
    source_dir=$(printf '%s\n' "$bind_line" | awk '{print $1}')
    grep -Fq "\"\$data_root/${source_dir#/data/}\"" "$skeleton" || fail "skeleton does not create bind source $source_dir"
done
rm -rf "$fstab_fixture" "$fixture_root"

# --- The skeleton, for real, where we may chown ------------------------------------
# Preflight of a real build runs as root, so this part runs before every A/B
# image; a non-root run (dry-run, standalone) skips it.
if [ "$(id -u)" -eq 0 ]; then
    data=$(mktemp -d)
    trap 'rm -rf "$data"' EXIT HUP INT TERM
    # An empty seed root: nothing to seed, only the layout.
    AB_SEED_ROOT="$data/no-seed" "$skeleton" --root "$data" --uid 1000 --gid 1000
    for expected in 'micropanel 1000:1000:755' 'micropanel-system/ssh-host-keys 0:0:700' \
        'micropanel-system/var-lib-micropanel 0:0:755' 'micropanel-system 0:0:700' \
        'disp-settings 0:0:755' 'kodi 1000:1000:755' 'disptool-results 1000:1000:755' \
        'NetworkManager/system-connections 0:0:700'; do
        path=${expected% *}
        [ "$(stat -c '%u:%g:%a' "$data/$path")" = "${expected#* }" ] || \
            fail "skeleton: $path is $(stat -c '%u:%g:%a' "$data/$path"), expected ${expected#* }"
        grep -Fq "\"$path\")\" = " "$assertions" || grep -Fq "/$path\")\" = " "$assertions" || \
            fail "ab-assertions.sh does not check skeleton path $path"
    done
    # Idempotent: the factory reset re-runs it over a wiped mount.
    AB_SEED_ROOT="$data/no-seed" "$skeleton" --root "$data" --uid 1000 --gid 1000

    # Seeds: kodi's tree and an authored settings.json are copied from the seed
    # root with pi ownership, and only into an empty destination.
    seeded=$(mktemp -d)
    seed="$seeded/seed-root"
    install -d "$seed/home/pi/.kodi/userdata/Database" "$seed/home/pi/micropanel/share/micropanel"
    printf '%s\n' pristine > "$seed/home/pi/.kodi/userdata/Database/fixture.db"
    printf '%s\n' '{}' > "$seed/home/pi/micropanel/share/micropanel/settings.json.default"
    AB_SEED_ROOT="$seed" "$skeleton" --root "$seeded/data" --uid 1000 --gid 1000
    [ "$(cat "$seeded/data/kodi/userdata/Database/fixture.db")" = pristine ] || fail 'skeleton did not seed kodi'
    [ -z "$(find "$seeded/data/kodi" ! -user 1000 -print -quit)" ] || fail 'seeded kodi tree is not owned by pi'
    [ "$(stat -c '%u' "$seeded/data/micropanel/settings.json")" = 1000 ] || fail 'skeleton did not seed settings.json'
    printf '%s\n' device-state > "$seeded/data/kodi/userdata/Database/fixture.db"
    printf '%s\n' '{"device":1}' > "$seeded/data/micropanel/settings.json"
    AB_SEED_ROOT="$seed" "$skeleton" --root "$seeded/data" --uid 1000 --gid 1000
    [ "$(cat "$seeded/data/kodi/userdata/Database/fixture.db")" = device-state ] || \
        fail 'skeleton overwrote a non-empty kodi profile'
    [ "$(cat "$seeded/data/micropanel/settings.json")" = '{"device":1}' ] || \
        fail 'skeleton overwrote an existing settings.json'
    rm -rf "$seeded"
fi

echo "micropanel A/B static contract: ok"
