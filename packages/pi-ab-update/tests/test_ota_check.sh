#!/bin/bash
# Drive the real check step against a real local HTTP server - the same shape
# as the bench setup, and a faithful one: because authenticity comes from a
# pinned signature rather than the transport, plain HTTP exercises the same
# trust path a TLS release source would.
set -uo pipefail

check=${1:?check script path is required}

for tool in python3 openssl curl mktemp awk; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing test tool: $tool" >&2; exit 1; }
done

work=$(mktemp -d)
server_pid=""
cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

failures=0
ok()   { printf '  ok  %-46s -> %s\n' "$1" "$2"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

serve="$work/serve"; mkdir -p "$serve"
openssl genpkey -algorithm ed25519 -out "$work/release.key" 2>/dev/null
openssl pkey -in "$work/release.key" -pubout -out "$work/release.pub" 2>/dev/null
openssl genpkey -algorithm ed25519 -out "$work/other.key" 2>/dev/null

write_release() { # $1=version
    printf '%s\n' "version=$1" 'variant=luckfox-ctp' 'boards=pi4' \
        "rootfs_sha256=$(printf '%064d' 0)" 'rootfs_bytes=5368709120' \
        "boot_sha256=$(printf '%064d' 0)" 'format=2' > "$serve/manifest"
    openssl pkeyutl -sign -inkey "$work/release.key" -rawin \
        -in "$serve/manifest" -out "$serve/manifest.sig"
}

# A fixed, unprivileged port; the server only ever serves this temp directory.
port=8731
( cd "$serve" && exec python3 -m http.server "$port" --bind 127.0.0.1 ) >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 1 40); do
    curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1 && break
    sleep 0.25
done

image_manifest="$work/image-manifest.env"
printf '%s\n' 'IMAGE_LAYOUT=ab' 'PANEL_VARIANT=luckfox-ctp' \
    'SLOT_COMPATIBLE_BOARDS=pi4' 'IMAGE_VERSION=00.34' > "$image_manifest"

source_config="$work/update-source.conf"
printf '%s\n' \
    "MANIFEST_URL=http://127.0.0.1:$port/manifest" \
    "MANIFEST_SIG_URL=http://127.0.0.1:$port/manifest.sig" \
    "BUNDLE_URL=http://127.0.0.1:$port/bundle.mpupdate" > "$source_config"

run_check() {
    AB_IMAGE_MANIFEST="$image_manifest" AB_SOURCE_CONFIG="$source_config" \
    AB_CHECK_MAX_SECONDS="${AB_CHECK_MAX_SECONDS:-10}" \
    AB_SIGNING_KEY="$work/release.pub" AB_RUNTIME_DIR="$work/runtime" \
    AB_BOARD=pi4 AB_NETWORK_TIMEOUT=5 \
        /bin/bash "$check" >/dev/null 2>&1
}
state() { awk -F= '/^state/{print $2}' "$work/runtime/check" 2>/dev/null; }
offered() { awk -F= '/^version/{print $2}' "$work/runtime/check" 2>/dev/null; }

# --- a newer release is offered -------------------------------------------
write_release 00.35
run_check
[ "$(state)" = available ] && [ "$(offered)" = 00.35 ] && ok 'newer release offered' 'available 00.35' \
    || fail "newer release: state=$(state) version=$(offered)"

# --- the running version reports up to date, and stops --------------------
write_release 00.34
run_check
[ "$(state)" = up-to-date ] && ok 'running version' 'up-to-date' || fail "same version: state=$(state)"

# --- an older release is a real offer: rollback is the recovery path -------
write_release 00.28
run_check
[ "$(state)" = available ] && [ "$(offered)" = 00.28 ] && ok 'older release offered (downgrade)' 'available 00.28' \
    || fail "downgrade: state=$(state) version=$(offered)"

# --- a manifest edited after signing --------------------------------------
write_release 00.35
sed -i 's/^version=00.35$/version=99.99/' "$serve/manifest"
run_check
[ "$(state)" = signature ] && ok 'manifest tampered after signing' 'signature' \
    || fail "tampered manifest: state=$(state)"

# --- signed by a key this device does not trust ---------------------------
write_release 00.35
openssl pkeyutl -sign -inkey "$work/other.key" -rawin \
    -in "$serve/manifest" -out "$serve/manifest.sig"
run_check
[ "$(state)" = signature ] && ok 'foreign signing key' 'signature' || fail "foreign key: state=$(state)"

# --- wrong variant and wrong board ----------------------------------------
write_release 00.35
sed -i 's/^variant=luckfox-ctp$/variant=piscreen/' "$serve/manifest"
openssl pkeyutl -sign -inkey "$work/release.key" -rawin -in "$serve/manifest" -out "$serve/manifest.sig"
run_check
[ "$(state)" = compatibility ] && ok 'release for another panel variant' 'compatibility' \
    || fail "wrong variant: state=$(state)"

write_release 00.35
sed -i 's/^boards=pi4$/boards=pi5/' "$serve/manifest"
openssl pkeyutl -sign -inkey "$work/release.key" -rawin -in "$serve/manifest" -out "$serve/manifest.sig"
run_check
[ "$(state)" = compatibility ] && ok 'release for another board' 'compatibility' \
    || fail "wrong board: state=$(state)"

# --- a server that connects and then says nothing --------------------------
# The failure mode --max-time exists for: without it this holds "checking" until
# the client's reply timeout, for two files totalling a few hundred bytes.
python3 - "$work/stall.port" <<'STALL' &
import socket, sys, time
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', 0)); srv.listen(8)
open(sys.argv[1], 'w').write(str(srv.getsockname()[1]))
held = []
deadline = time.time() + 60
while time.time() < deadline:
    srv.settimeout(1.0)
    try:
        conn, _ = srv.accept()
    except socket.timeout:
        continue
    held.append(conn)   # accepted, and deliberately never answered
STALL
stall_pid=$!
for _ in $(seq 1 40); do [ -s "$work/stall.port" ] && break; sleep 0.25; done
stall_port=$(cat "$work/stall.port" 2>/dev/null)
if [ -n "$stall_port" ]; then
    printf '%s\n' \
        "MANIFEST_URL=http://127.0.0.1:$stall_port/manifest" \
        "MANIFEST_SIG_URL=http://127.0.0.1:$stall_port/manifest.sig" \
        "BUNDLE_URL=http://127.0.0.1:$stall_port/bundle.mpupdate" > "$source_config"
    started=$SECONDS
    AB_CHECK_MAX_SECONDS=3 run_check
    elapsed=$((SECONDS - started))
    if [ "$(state)" = network ] && [ "$elapsed" -lt 30 ]; then
        ok 'server connects then stalls' "network (${elapsed}s)"
    else
        fail "stalling server: state=$(state) elapsed=${elapsed}s"
    fi
else
    echo '  skip  stalling server: could not start the stand-in'
fi
kill "$stall_pid" 2>/dev/null || true
wait "$stall_pid" 2>/dev/null || true
printf '%s\n' \
    "MANIFEST_URL=http://127.0.0.1:$port/manifest" \
    "MANIFEST_SIG_URL=http://127.0.0.1:$port/manifest.sig" \
    "BUNDLE_URL=http://127.0.0.1:$port/bundle.mpupdate" > "$source_config"

# --- the server is gone ----------------------------------------------------
write_release 00.35
kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true   # 143 from our own TERM is expected
    server_pid=""
run_check
[ "$(state)" = network ] && ok 'release server unreachable' 'network' || fail "unreachable: state=$(state)"

# --- nothing was fetched beyond the manifest pair --------------------------
# The check must never pull the payload; that is what makes "up to date" cheap.
[ ! -e "$work/runtime/bundle.mpupdate" ] && ok 'check never downloads a payload' 'manifest pair only' \
    || fail 'the check downloaded a payload'

[ "$failures" -eq 0 ] || { echo "ota-check: $failures FAILURES" >&2; exit 1; }
printf '%s\n' 'ota-check: PASS'
