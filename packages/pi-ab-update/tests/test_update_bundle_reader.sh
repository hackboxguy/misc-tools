#!/bin/bash
# Drive the real Stage 2b bundle reader through a pipe with deliberately
# malformed bundles. Every case here aborts before the handler resolves or
# touches a slot device, so this needs neither root nor loop devices.
set -euo pipefail

handler=${1:?handler path is required}

for tool in tar dd stat od sha256sum xz mktemp install flock; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: missing test tool: $tool" >&2
        exit 1
    }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

image_manifest="$work/image-manifest.env"
printf '%s\n' \
    'IMAGE_LAYOUT=ab' \
    'PANEL_VARIANT=luckfox-ctp' \
    'SLOT_COMPATIBLE_BOARDS=pi4' \
    'IMAGE_VERSION=00.30' > "$image_manifest"

selector="$work/selector"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" A' > "$selector"
chmod 0755 "$selector"

reboot_command="$work/reboot"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$reboot_command"
chmod 0755 "$reboot_command"

# A syntactically valid boot archive, plus the digests a manifest must carry.
install -d "$work/boot-tree"
printf '%s\n' \
    'console=tty1 root=LABEL=@MICROPANEL_SLOT@ rootfstype=ext4 rootwait overlayroot=tmpfs:recurse=0' \
    > "$work/boot-tree/cmdline.txt.template"
printf '%s\n' 'fixture kernel' > "$work/boot-tree/kernel8.img"
tar --format=posix --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
    -C "$work/boot-tree" -cf "$work/boot.tar" .
boot_sha256=$(sha256sum "$work/boot.tar" | awk '{print $1}')

# A boot archive that violates the slot-neutral cmdline rule.
install -d "$work/bad-boot-tree"
cp "$work/boot-tree/cmdline.txt.template" "$work/bad-boot-tree/"
printf '%s\n' 'not slot neutral' > "$work/bad-boot-tree/cmdline.txt"
tar --format=posix --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
    -C "$work/bad-boot-tree" -cf "$work/bad-boot.tar" .
bad_boot_sha256=$(sha256sum "$work/bad-boot.tar" | awk '{print $1}')

printf 'placeholder rootfs stream\n' > "$work/rootfs.img"
xz --threads=1 --check=crc64 --lzma2=dict=1MiB --stdout "$work/rootfs.img" > "$work/rootfs.img.xz"
rootfs_sha256=$(sha256sum "$work/rootfs.img" | awk '{print $1}')
rootfs_bytes=$(stat -c %s "$work/rootfs.img")

write_manifest() { # $1=destination $2=version $3=variant $4=boards $5=format $6=boot digest
    printf '%s\n' \
        "version=$2" \
        "variant=$3" \
        "boards=$4" \
        "rootfs_sha256=$rootfs_sha256" \
        "rootfs_bytes=$rootfs_bytes" \
        "boot_sha256=$6" \
        "format=$5" > "$1"
}

# $1=bundle path, remaining args are staged member names in publication order.
build_bundle() {
    local bundle=$1
    shift
    tar --format=ustar --owner=0 --group=0 --numeric-owner --mtime=@0 \
        -C "$work/stage" -cf "$bundle" "$@"
}

reset_stage() {
    rm -rf "$work/stage"
    install -d "$work/stage"
    cp "$work/boot.tar" "$work/stage/boot.tar"
    cp "$work/rootfs.img.xz" "$work/stage/rootfs.img.xz"
    printf 'not a real ed25519 signature\n' > "$work/stage/manifest.sig"
    write_manifest "$work/stage/manifest" 00.31 luckfox-ctp pi4 2 "$boot_sha256"
    chmod 0644 "$work/stage"/*
}

failures=0
expect_phase() { # $1=label $2=expected phase $3=bundle
    local runtime="$work/runtime"
    rm -rf "$runtime"
    if AB_IMAGE_MANIFEST="$image_manifest" \
        AB_SLOT_SELECTOR="$selector" \
        AB_REBOOT_COMMAND="$reboot_command" \
        AB_RUNTIME_DIR="$runtime" \
        AB_STATE_DIR="$work/state" \
        AB_BOARD=pi4 \
        /bin/bash "$handler" stdin < "$3" >/dev/null 2>&1; then
        echo "FAIL: $1 was accepted" >&2
        failures=$((failures + 1))
        return
    fi
    if ! grep -Fqx "phase=$2" "$runtime/progress" 2>/dev/null; then
        echo "FAIL: $1 reported $(sed -n 's/^phase=//p' "$runtime/progress" 2>/dev/null) instead of $2" >&2
        failures=$((failures + 1))
        return
    fi
    printf '  ok  %-44s -> %s\n' "$1" "$2"
}

: > "$work/empty.mpupdate"
expect_phase 'empty bundle' failed-payload "$work/empty.mpupdate"

reset_stage
build_bundle "$work/manifest-not-first.mpupdate" boot.tar manifest manifest.sig rootfs.img.xz
expect_phase 'manifest is not the first member' failed-payload "$work/manifest-not-first.mpupdate"

reset_stage
build_bundle "$work/no-boot.mpupdate" manifest manifest.sig rootfs.img.xz
expect_phase 'boot archive missing' failed-payload "$work/no-boot.mpupdate"

reset_stage
build_bundle "$work/out-of-order.mpupdate" manifest boot.tar manifest.sig rootfs.img.xz
expect_phase 'signature after the boot archive' failed-payload "$work/out-of-order.mpupdate"

reset_stage
cp "$work/stage/manifest" "$work/stage/extra"
build_bundle "$work/unknown-member.mpupdate" manifest extra manifest.sig boot.tar rootfs.img.xz
expect_phase 'unknown member name' failed-payload "$work/unknown-member.mpupdate"

reset_stage
install -d "$work/stage/manifest.sig.d"
rm -f "$work/stage/manifest.sig"
build_bundle "$work/directory-member.mpupdate" manifest manifest.sig.d boot.tar rootfs.img.xz
expect_phase 'directory member' failed-payload "$work/directory-member.mpupdate"

reset_stage
head -c 70000 /dev/zero | tr '\0' 'v' > "$work/stage/manifest"
build_bundle "$work/oversize-manifest.mpupdate" manifest manifest.sig boot.tar rootfs.img.xz
expect_phase 'oversize manifest' failed-payload "$work/oversize-manifest.mpupdate"

reset_stage
write_manifest "$work/stage/manifest" 00.31 luckfox-ctp pi4 1 "$boot_sha256"
build_bundle "$work/format1.mpupdate" manifest manifest.sig boot.tar rootfs.img.xz
expect_phase 'format=1 manifest' failed-payload "$work/format1.mpupdate"

reset_stage
write_manifest "$work/stage/manifest" 00.31 piscreen pi4 2 "$boot_sha256"
build_bundle "$work/wrong-variant.mpupdate" manifest manifest.sig boot.tar rootfs.img.xz
expect_phase 'wrong panel variant' failed-compatibility "$work/wrong-variant.mpupdate"

reset_stage
write_manifest "$work/stage/manifest" 00.31 luckfox-ctp pi5 2 "$boot_sha256"
build_bundle "$work/wrong-board.mpupdate" manifest manifest.sig boot.tar rootfs.img.xz
expect_phase 'unsupported board' failed-compatibility "$work/wrong-board.mpupdate"

# Manifest-first early abort: the running release must be recognized before any
# of the multi-gigabyte tail is read.
reset_stage
write_manifest "$work/stage/manifest" 00.30 luckfox-ctp pi4 2 "$boot_sha256"
build_bundle "$work/same-version.mpupdate" manifest manifest.sig boot.tar rootfs.img.xz
expect_phase 'already-installed version' failed-version "$work/same-version.mpupdate"

reset_stage
write_manifest "$work/stage/manifest" 00.31 luckfox-ctp pi4 2 \
    0000000000000000000000000000000000000000000000000000000000000000
build_bundle "$work/boot-digest.mpupdate" manifest manifest.sig boot.tar rootfs.img.xz
expect_phase 'boot archive digest mismatch' failed-integrity "$work/boot-digest.mpupdate"

reset_stage
cp "$work/bad-boot.tar" "$work/stage/boot.tar"
write_manifest "$work/stage/manifest" 00.31 luckfox-ctp pi4 2 "$bad_boot_sha256"
build_bundle "$work/bad-boot.mpupdate" manifest manifest.sig boot.tar rootfs.img.xz
expect_phase 'boot archive carries a slot-bound cmdline' failed-boot "$work/bad-boot.mpupdate"

# A stick yanked out of Windows before the copy flushes leaves a truncated
# bundle. Every truncation point must still name a specific cause: "the update
# stopped safely" tells an operator nothing about a half-copied file.
reset_stage
build_bundle "$work/whole.mpupdate" manifest manifest.sig boot.tar rootfs.img.xz
whole_bytes=$(stat -c %s "$work/whole.mpupdate")
manifest_bytes=$(stat -c %s "$work/stage/manifest")
signature_bytes=$(stat -c %s "$work/stage/manifest.sig")
boot_bytes=$(stat -c %s "$work/stage/boot.tar")

# ...inside the very first header.
head -c 200 "$work/whole.mpupdate" > "$work/cut-header.mpupdate"
expect_phase 'truncated inside the first header' failed-payload "$work/cut-header.mpupdate"

# ...part way through the manifest member.
head -c $((512 + manifest_bytes / 2)) "$work/whole.mpupdate" > "$work/cut-manifest.mpupdate"
expect_phase 'truncated inside the manifest' failed-payload "$work/cut-manifest.mpupdate"

# ...part way through the boot archive, which must fail its digest.
head -c $((512 + 512 + 512 + 512 + boot_bytes / 2)) "$work/whole.mpupdate" \
    > "$work/cut-boot.mpupdate"
expect_phase 'truncated inside the boot archive' failed-integrity "$work/cut-boot.mpupdate"

# ...just short of the end, so only the rootfs tail is missing. Off hardware
# this stops at slot resolution; on a device it reaches the digest and fails
# there. Either way the point holds: never the generic internal class.
head -c $((whole_bytes - 4096)) "$work/whole.mpupdate" > "$work/cut-rootfs.mpupdate"
expect_phase 'truncated rootfs reaches slot resolution' failed-target "$work/cut-rootfs.mpupdate"

# A bundle with no signature member is still accepted until Stage 4 turns
# device-side verification on; it must reach the target-resolution stage rather
# than be refused as malformed.
reset_stage
rm -f "$work/stage/manifest.sig"
build_bundle "$work/unsigned.mpupdate" manifest boot.tar rootfs.img.xz
expect_phase 'unsigned bundle reaches slot resolution' failed-target "$work/unsigned.mpupdate"

reset_stage
build_bundle "$work/signed.mpupdate" manifest manifest.sig boot.tar rootfs.img.xz
expect_phase 'signed bundle reaches slot resolution' failed-target "$work/signed.mpupdate"

# A second invocation must refuse without disturbing the owner's telemetry.
reset_stage
build_bundle "$work/locked.mpupdate" manifest manifest.sig boot.tar rootfs.img.xz
runtime="$work/lock-runtime"
rm -rf "$runtime"
install -d -m0700 "$runtime/private"
printf 'phase=writing\nprogress=42\n' > "$runtime/progress"
exec {owner_fd}>"$runtime/private/update.lock"
flock -n "$owner_fd"
if AB_IMAGE_MANIFEST="$image_manifest" \
    AB_SLOT_SELECTOR="$selector" \
    AB_REBOOT_COMMAND="$reboot_command" \
    AB_RUNTIME_DIR="$runtime" \
    AB_STATE_DIR="$work/state" \
    AB_BOARD=pi4 \
    /bin/bash "$handler" stdin < "$work/locked.mpupdate" >/dev/null 2>&1; then
    echo 'FAIL: a concurrent update was accepted' >&2
    failures=$((failures + 1))
fi
grep -Fqx 'phase=writing' "$runtime/progress" || {
    echo "FAIL: a refused concurrent update overwrote the owner's progress" >&2
    failures=$((failures + 1))
}
grep -Fqx 'progress=42' "$runtime/progress" || {
    echo "FAIL: a refused concurrent update overwrote the owner's progress" >&2
    failures=$((failures + 1))
}
exec {owner_fd}>&-
printf '  ok  %-44s -> %s\n' 'concurrent update refused' 'owner telemetry intact'

# V5-03: a handler that dies before it owns the lock must publish nothing.
runtime="$work/prelock-runtime"
rm -rf "$runtime"
if AB_IMAGE_MANIFEST="$image_manifest" \
    AB_SLOT_SELECTOR="$selector" \
    AB_RUNTIME_DIR="$runtime" \
    AB_BOARD=pi4 \
    /bin/bash "$handler" not-a-source >/dev/null 2>&1; then
    echo 'FAIL: the handler accepted an unknown source enum' >&2
    failures=$((failures + 1))
fi
[ ! -e "$runtime/progress" ] || {
    echo 'FAIL: a pre-lock refusal published update telemetry' >&2
    failures=$((failures + 1))
}
printf '  ok  %-44s -> %s\n' 'unknown source enum' 'no telemetry published'

# Nothing above may report the generic class: every one of these has a cause
# worth naming, and `failed-internal` is undiagnosable from the UI.
if grep -Rqs 'phase=failed-internal' "$work"/*runtime*/progress 2>/dev/null; then
    echo 'FAIL: a case reported the generic internal class' >&2
    failures=$((failures + 1))
fi

[ "$failures" -eq 0 ] || {
    echo "update-bundle-reader: $failures FAILURES" >&2
    exit 1
}
printf '%s\n' 'update-bundle-reader: PASS'
