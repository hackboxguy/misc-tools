#!/bin/bash
# Drive the real Stage 2b bundle reader through a pipe with deliberately
# malformed bundles. Every case here aborts before the handler resolves or
# touches a slot device, so this needs neither root nor loop devices.
set -euo pipefail

handler=${1:?handler path is required}

for tool in tar dd stat od sha256sum xz mktemp install flock openssl; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: missing test tool: $tool" >&2
        exit 1
    }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

# A disposable release keypair. Every bundle this suite builds is signed with
# it, which is itself the point: an unsigned bundle no longer reaches any of
# the checks below.
openssl genpkey -algorithm ed25519 -out "$work/release.key" 2>/dev/null
openssl pkey -in "$work/release.key" -pubout -out "$work/release.pub" 2>/dev/null
sign_manifest() { # $1=manifest path, $2=signature path
    openssl pkeyutl -sign -inkey "$work/release.key" -rawin -in "$1" -out "$2"
}

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
    write_manifest "$work/stage/manifest" 00.31 luckfox-ctp pi4 2 "$boot_sha256"
    sign_manifest "$work/stage/manifest" "$work/stage/manifest.sig"
    chmod 0644 "$work/stage"/*
}

# Anything that rewrites the manifest must re-sign it, or it is testing the
# signature check rather than whatever it meant to test.
reseal() { sign_manifest "$work/stage/manifest" "$work/stage/manifest.sig"; }

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
        AB_SIGNING_KEY="$work/release.pub" \
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

# Since Stage 4 the signature's *position* is part of the format, so a bundle
# whose second member is not a signature is indistinguishable from an unsigned
# one at the point of the check - and reporting it as unsigned is the honest
# answer for both.
reset_stage
build_bundle "$work/out-of-order.mpupdate" manifest boot.tar manifest.sig rootfs.img.xz
expect_phase 'signature after the boot archive' failed-signature "$work/out-of-order.mpupdate"

reset_stage
cp "$work/stage/manifest" "$work/stage/extra"
build_bundle "$work/unknown-member.mpupdate" manifest extra manifest.sig boot.tar rootfs.img.xz
expect_phase 'unknown member in the signature slot' failed-signature "$work/unknown-member.mpupdate"

reset_stage
install -d "$work/stage/manifest.sig.d"
rm -f "$work/stage/manifest.sig"
build_bundle "$work/directory-member.mpupdate" manifest manifest.sig.d boot.tar rootfs.img.xz
expect_phase 'directory member' failed-payload "$work/directory-member.mpupdate"

reset_stage
head -c 70000 /dev/zero | tr '\0' 'v' > "$work/stage/manifest"
reseal
build_bundle "$work/oversize-manifest.mpupdate" manifest manifest.sig boot.tar rootfs.img.xz
expect_phase 'oversize manifest' failed-payload "$work/oversize-manifest.mpupdate"

reset_stage
write_manifest "$work/stage/manifest" 00.31 luckfox-ctp pi4 1 "$boot_sha256"
reseal
build_bundle "$work/format1.mpupdate" manifest manifest.sig boot.tar rootfs.img.xz
expect_phase 'format=1 manifest' failed-payload "$work/format1.mpupdate"

reset_stage
write_manifest "$work/stage/manifest" 00.31 piscreen pi4 2 "$boot_sha256"
reseal
build_bundle "$work/wrong-variant.mpupdate" manifest manifest.sig boot.tar rootfs.img.xz
expect_phase 'wrong panel variant' failed-compatibility "$work/wrong-variant.mpupdate"

reset_stage
write_manifest "$work/stage/manifest" 00.31 luckfox-ctp pi5 2 "$boot_sha256"
reseal
build_bundle "$work/wrong-board.mpupdate" manifest manifest.sig boot.tar rootfs.img.xz
expect_phase 'unsupported board' failed-compatibility "$work/wrong-board.mpupdate"

# Manifest-first early abort: the running release must be recognized before any
# of the multi-gigabyte tail is read.
reset_stage
write_manifest "$work/stage/manifest" 00.30 luckfox-ctp pi4 2 "$boot_sha256"
reseal
build_bundle "$work/same-version.mpupdate" manifest manifest.sig boot.tar rootfs.img.xz
expect_phase 'already-installed version' failed-version "$work/same-version.mpupdate"

reset_stage
write_manifest "$work/stage/manifest" 00.31 luckfox-ctp pi4 2 \
    0000000000000000000000000000000000000000000000000000000000000000
reseal
build_bundle "$work/boot-digest.mpupdate" manifest manifest.sig boot.tar rootfs.img.xz
expect_phase 'boot archive digest mismatch' failed-integrity "$work/boot-digest.mpupdate"

reset_stage
cp "$work/bad-boot.tar" "$work/stage/boot.tar"
write_manifest "$work/stage/manifest" 00.31 luckfox-ctp pi4 2 "$bad_boot_sha256"
reseal
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

# Stage 4: the signature is mandatory and is checked before the manifest is
# parsed or acted on, for every source - a check applied only to the network
# path would leave USB, the path a physically present attacker uses, as the way
# around it.
reset_stage
rm -f "$work/stage/manifest.sig"
build_bundle "$work/unsigned.mpupdate" manifest boot.tar rootfs.img.xz
expect_phase 'unsigned bundle refused' failed-signature "$work/unsigned.mpupdate"

reset_stage
printf 'not a signature at all\n' > "$work/stage/manifest.sig"
build_bundle "$work/badsig.mpupdate" manifest manifest.sig boot.tar rootfs.img.xz
expect_phase 'corrupt signature refused' failed-signature "$work/badsig.mpupdate"

# Signed by the wrong key: the check is against *this device's* pinned key, not
# merely "somebody signed it".
reset_stage
openssl genpkey -algorithm ed25519 -out "$work/other.key" 2>/dev/null
openssl pkeyutl -sign -inkey "$work/other.key" -rawin \
    -in "$work/stage/manifest" -out "$work/stage/manifest.sig"
build_bundle "$work/foreignsig.mpupdate" manifest manifest.sig boot.tar rootfs.img.xz
expect_phase 'foreign key refused' failed-signature "$work/foreignsig.mpupdate"

# A manifest edited after signing - the attack the signature exists to stop.
reset_stage
sed -i 's/^version=00.31$/version=99.99/' "$work/stage/manifest"
build_bundle "$work/tampered.mpupdate" manifest manifest.sig boot.tar rootfs.img.xz
expect_phase 'manifest tampered after signing' failed-signature "$work/tampered.mpupdate"

# The verification must not depend on the clock: a raw ed25519 signature has no
# validity window, which is what keeps a permanently offline device updatable.
reset_stage
build_bundle "$work/signed.mpupdate" manifest manifest.sig boot.tar rootfs.img.xz
expect_phase 'signed bundle reaches slot resolution' failed-target "$work/signed.mpupdate"
if command -v faketime >/dev/null 2>&1; then
    runtime="$work/clock-runtime"; rm -rf "$runtime"
    if faketime '2000-01-01 00:00:00' env MICROPANEL_UNUSED=1 sh -c ':' 2>/dev/null; then
        AB_IMAGE_MANIFEST="$image_manifest" AB_SLOT_SELECTOR="$selector" \
            AB_UPDATE_REBOOT_COMMAND="$reboot_command" AB_RUNTIME_DIR="$runtime" \
            AB_STATE_DIR="$work/state" AB_BOARD=pi4 AB_SIGNING_KEY="$work/release.pub" \
            faketime '2000-01-01 00:00:00' /bin/bash "$handler" stdin \
            < "$work/signed.mpupdate" >/dev/null 2>&1 || true
        if grep -Fqx 'phase=failed-signature' "$runtime/progress" 2>/dev/null; then
            echo 'FAIL: signature verification depends on the clock' >&2
            failures=$((failures + 1))
        else
            printf '  ok  %-44s -> %s\n' 'signature verifies with a 26-year-old clock' 'clock-independent'
        fi
    fi
else
    printf '  skip  %s\n' 'clock-independence case: faketime is unavailable'
fi

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
    AB_BOARD=pi4 AB_SIGNING_KEY="$work/release.pub" \
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
    AB_BOARD=pi4 AB_SIGNING_KEY="$work/release.pub" \
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
