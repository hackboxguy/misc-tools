#!/bin/bash
# Exercise the real factory-reset pair against a disposable loop-mounted
# filesystem: the request CLI, the early-boot wipe, the safety refusals, and
# the interrupted-reset retry. Run as root; ordinary users skip it.
set -uo pipefail

request=${1:?request script path is required}
boot=${2:?boot script path is required}
skeleton=${3:?data skeleton script path is required}

if [ "$(id -u)" -ne 0 ]; then
    echo 'SKIP: factory reset fixture requires root loop/mount access'
    exit 77
fi

work=$(mktemp -d)
loop=""
data=$work/data
failures=0

cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    mountpoint -q "$data" && umount "$data"
    [ -z "$loop" ] || losetup -d "$loop" 2>/dev/null || true
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

check() { # $1=label $2=condition-description; runs "$@" from $3
    shift 2
    :
}
ok()   { printf '  ok  %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

# A real filesystem, because the reset refuses to wipe anything that is not a
# mount point of its own - the guard that stops it destroying a running root
# when the durable partition failed to mount.
truncate -s 64M "$work/data.img"
loop=$(losetup --find --show "$work/data.img")
mkfs.ext4 -F -q "$loop"
mkdir -p "$data"
mount "$loop" "$data"

conf="$work/ab-update.conf"
seed_source="$work/lower-root/etc/NetworkManager/system-connections"
mkdir -p "$seed_source"
printf '[connection]\nid=shipped\n' > "$seed_source/shipped.nmconnection"
chmod 0600 "$seed_source/shipped.nmconnection"
cat > "$conf" <<CONF
AB_PRODUCT=fixture
AB_STATE_DIR=$data/fixture-system
AB_DATA_MOUNT=$data
AB_RESET_BEFORE=fixture.service
AB_RESET_SEED=$seed_source:NetworkManager/system-connections
CONF

reboot_log="$work/reboot.log"
reboot_command="$work/reboot"
printf '%s\n' '#!/bin/sh' 'printf "rebooted\n" >> "$REBOOT_LOG"' > "$reboot_command"
chmod 0755 "$reboot_command"

run_request() {
    AB_UPDATE_CONFIG="$conf" AB_APP_ACCOUNT="$(id -un)" \
    AB_REBOOT_COMMAND="$reboot_command" REBOOT_LOG="$reboot_log" \
    AB_REBOOT_DELAY_SECONDS=0 \
        /bin/bash "$request" "$@"
}
run_boot() {
    AB_UPDATE_CONFIG="$conf" AB_APP_ACCOUNT="$(id -un)" \
    AB_DATA_SKELETON="$skeleton" \
        /bin/bash "$boot"
}

seed_user_state() {
    mkdir -p "$data/fixture-system" "$data/micropanel-touch/logs" "$data/NetworkManager/system-connections"
    printf 'user settings\n' > "$data/micropanel-touch/settings.json"
    printf 'calibration\n' > "$data/micropanel-touch/touch-calibration.json"
    printf 'state=committed\ncandidate_slot=B\n' > "$data/fixture-system/update-state"
    printf 'deadbeef\n' > "$data/fixture-system/machine-id"
    printf '[connection]\nid=user-made\n' > "$data/NetworkManager/system-connections/user.nmconnection"
    sync
}

# --- the boot service is a no-op without a marker -------------------------
seed_user_state
run_boot >/dev/null 2>&1
[ -f "$data/micropanel-touch/settings.json" ] && ok 'no marker: durable state untouched' \
    || fail 'no marker: state was wiped anyway'

# --- requesting writes a marker and reboots, and wipes nothing itself -----
run_request >/dev/null 2>&1
[ -f "$data/fixture-system/factory-reset-requested" ] && ok 'request writes the marker' \
    || fail 'request did not write the marker'
[ "$(stat -c %a "$data/fixture-system/factory-reset-requested")" = 600 ] && ok 'marker is root-only 0600' \
    || fail 'marker has the wrong mode'
grep -q rebooted "$reboot_log" 2>/dev/null && ok 'request reboots' || fail 'request did not reboot'
[ -f "$data/micropanel-touch/settings.json" ] && ok 'request itself wipes nothing' \
    || fail 'request wiped state before the reboot'
run_request extra-argument >/dev/null 2>&1 && fail 'request accepted an argument' \
    || ok 'request refuses arguments'
rm -f "$data/fixture-system/factory-reset-requested"
: > "$reboot_log"
run_request --yes >/dev/null 2>&1
[ -f "$data/fixture-system/factory-reset-requested" ] && ok 'request accepts --yes' \
    || fail 'request refused --yes'

# --- a person at a terminal is asked first ---------------------------------
# This tool sits in root's PATH and used to erase the device with one command
# and no question; a reviewer proved the gap by running it on the bench
# expecting a refusal that did not apply. The broker has no terminal and is
# unaffected, which is why the confirmation is gated on one rather than on a
# flag the UI would have to remember to pass.
if command -v script >/dev/null 2>&1; then
    ask_on_a_terminal() { # $1=what to type; prints nothing, returns the exit status
        rm -f "$data/fixture-system/factory-reset-requested"
        : > "$reboot_log"
        printf '%s\n' "$1" | AB_UPDATE_CONFIG="$conf" AB_APP_ACCOUNT="$(id -un)" \
            AB_REBOOT_COMMAND="$reboot_command" REBOOT_LOG="$reboot_log" \
            AB_REBOOT_DELAY_SECONDS=0 \
            script -qec "/bin/bash $request" /dev/null >/dev/null 2>&1
    }
    ask_on_a_terminal 'no'
    [ ! -f "$data/fixture-system/factory-reset-requested" ] \
        && ok 'a terminal is asked, and "no" means no' \
        || fail 'the confirmation armed a reset anyway'
    grep -q rebooted "$reboot_log" 2>/dev/null && fail 'a cancelled reset rebooted' \
        || ok 'a cancelled reset does not reboot'
    ask_on_a_terminal 'erase'
    [ -f "$data/fixture-system/factory-reset-requested" ] \
        && ok 'a terminal that types "erase" gets one' \
        || fail 'the confirmation refused a confirmed reset'
    # ...and the flag skips the question even at a terminal, which is what a
    # script wants.
    rm -f "$data/fixture-system/factory-reset-requested"
    printf '' | AB_UPDATE_CONFIG="$conf" AB_APP_ACCOUNT="$(id -un)" \
        AB_REBOOT_COMMAND="$reboot_command" REBOOT_LOG="$reboot_log" \
        AB_REBOOT_DELAY_SECONDS=0 \
        script -qec "/bin/bash $request --yes" /dev/null >/dev/null 2>&1
    [ -f "$data/fixture-system/factory-reset-requested" ] \
        && ok '--yes skips the question at a terminal' \
        || fail '--yes still asked'
else
    echo '  --  skipped: no script(1) to allocate a terminal with'
fi
rm -f "$data/fixture-system/factory-reset-requested"

# --- a reset must not eat an update that is on trial ----------------------
# A tryboot candidate gets one boot, and the reset's own reboot spends it -
# then the wipe erases the record that a candidate existed, so nothing commits
# and the device falls back to the image it came from. The update vanishes and
# the reset runs on the old one. An owner hit exactly this on the bench.
rm -f "$data/fixture-system/factory-reset-requested"
: > "$reboot_log"
printf 'state=candidate-armed\ncandidate_slot=A\nversion=00.48\n' > "$data/fixture-system/update-state"
run_request >/dev/null 2>&1
refusal_status=$?
if [ "$refusal_status" -eq 0 ]; then
    fail 'the reset was requested while an update was on trial'
else
    ok 'refuses to reset while an update is on trial'
fi
# The broker never forwards handler output, so the reason travels as a code:
# 75 is EX_TEMPFAIL, and the screen turns it into words. A plain failure would
# reach the panel as "could not be started", which is true and useless.
[ "$refusal_status" -eq 75 ] && ok 'the refusal is distinguishable from a failure' \
    || fail "the refusal exits $refusal_status, which no caller can tell from a failure"
[ ! -f "$data/fixture-system/factory-reset-requested" ] && ok 'a refused reset leaves no marker' \
    || fail 'a refused reset armed itself anyway'
grep -q rebooted "$reboot_log" 2>/dev/null && fail 'a refused reset rebooted' \
    || ok 'a refused reset does not reboot'
# Captured, not piped: the request exits non-zero by design, and under
# `set -o pipefail` a pipeline inherits that even when grep matched.
refusal=$(run_request 2>&1 || true)
case "$refusal" in
    *'on trial'*) ok 'the refusal says why' ;;
    *) fail "the refusal does not say why: $refusal" ;;
esac

# ...and the states that are not a trial in progress do not block it. A
# candidate that already fell back is finished, not pending.
for finished in committed fallback; do
    printf 'state=%s\ncandidate_slot=A\n' "$finished" > "$data/fixture-system/update-state"
    rm -f "$data/fixture-system/factory-reset-requested"
    run_request >/dev/null 2>&1
    [ -f "$data/fixture-system/factory-reset-requested" ] \
        && ok "a reset is allowed after an update is $finished" \
        || fail "a reset was refused after an update is $finished"
done
rm -f "$data/fixture-system/factory-reset-requested"
printf 'state=committed\ncandidate_slot=B\n' > "$data/fixture-system/update-state"

# --- the deferred reboot lets the caller hear the answer -------------------
# An immediate reboot kills the caller mid-reply, so a broker-mediated UI
# reports a failure for a request that already succeeded. The request must
# return first and reboot a moment later.
: > "$reboot_log"
start=$(date +%s)
AB_UPDATE_CONFIG="$conf" AB_APP_ACCOUNT="$(id -un)" \
    AB_REBOOT_COMMAND="$reboot_command" REBOOT_LOG="$reboot_log" \
    AB_REBOOT_DELAY_SECONDS=2 /bin/bash "$request" >/dev/null 2>&1
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -le 1 ] && ok 'deferred request returns immediately' \
    || fail "deferred request blocked for ${elapsed}s"
grep -q rebooted "$reboot_log" 2>/dev/null && fail 'reboot fired before the caller returned' \
    || ok 'reboot has not fired yet when the request returns'
sleep 4
grep -q rebooted "$reboot_log" 2>/dev/null && ok 'deferred reboot fires afterwards' \
    || fail 'deferred reboot never fired'
rm -f "$data/fixture-system/factory-reset-requested"

# --- an interrupted reset retries -----------------------------------------
# Simulate a power cut part way through: the wipe happened, the marker did not
# get cleared. The next boot must simply run the whole thing again.
rm -rf "$data/micropanel-touch"
run_boot >/dev/null 2>&1
[ ! -f "$data/fixture-system/factory-reset-requested" ] && ok 'interrupted reset completes on retry' \
    || fail 'marker survived a completed reset'

# --- the full reset -------------------------------------------------------
seed_user_state
run_request >/dev/null 2>&1
run_boot >/dev/null 2>&1
[ ! -f "$data/micropanel-touch/settings.json" ] && ok 'settings wiped' || fail 'settings survived'
[ ! -f "$data/micropanel-touch/touch-calibration.json" ] && ok 'calibration wiped' || fail 'calibration survived'
[ ! -f "$data/fixture-system/machine-id" ] && ok 'machine identity wiped' || fail 'machine identity survived'
# Owner decision 2026-08-19: a reset device must look freshly flashed, so the
# A/B update record goes too.
[ ! -f "$data/fixture-system/update-state" ] && ok 'A/B update state cleared' || fail 'update state survived'
[ ! -f "$data/NetworkManager/system-connections/user.nmconnection" ] && ok 'user network profile wiped' \
    || fail 'user network profile survived'
# ...but the skeleton and the shipped profiles come back.
for directory in micropanel-touch micropanel-touch/logs micropanel-touch/ssh-host-keys \
                 fixture-system micropanel-touch-network/dhcp-server \
                 NetworkManager/system-connections; do
    [ -d "$data/$directory" ] || fail "skeleton directory missing after reset: $directory"
done
ok 'pristine skeleton recreated'
[ -f "$data/NetworkManager/system-connections/shipped.nmconnection" ] && ok 'shipped network profile re-seeded' \
    || fail 'shipped network profile was not re-seeded'
[ "$(stat -c %a "$data/NetworkManager/system-connections/shipped.nmconnection")" = 600 ] \
    && ok 're-seeded profile keeps its restrictive mode' || fail 're-seeded profile has the wrong mode'
[ ! -f "$data/fixture-system/factory-reset-requested" ] && ok 'marker cleared last' || fail 'marker survived'
[ -d "$data/lost+found" ] && ok 'filesystem lost+found preserved' || fail 'lost+found was deleted'

# --- a mount attached to what the wipe deletes ----------------------------
# The real shape of this: the running system bind-mounts
# /data/NetworkManager/system-connections onto /etc, and the wipe deletes the
# directory that mount is attached to. A bind mount holds an inode, not a
# path, so it keeps pointing at the deleted one - which presents as an empty
# directory that cannot be written to at all, and NetworkManager silently
# stops being able to save a profile. The panel scans, accepts a password and
# never joins. Found on the bench; asserted here.
bind_target=$work/bound-connections
mkdir -p "$bind_target"
if mount --bind "$data/NetworkManager/system-connections" "$bind_target" 2>/dev/null; then
    seed_user_state
    run_request >/dev/null 2>&1
    run_boot >/dev/null 2>&1
    if findmnt -rn -o SOURCE --target "$bind_target" 2>/dev/null | grep -q '//deleted'; then
        fail 'the wipe left a mount attached to a deleted directory'
    else
        ok 'mounts attached to wiped directories are re-established'
    fi
    # The property that actually matters is not the absence of a marker in
    # findmnt output - it is that the thing can be written to again.
    if touch "$bind_target/probe.nmconnection" 2>/dev/null; then
        ok 'a profile can still be written through the mount after a reset'
        rm -f "$bind_target/probe.nmconnection"
    else
        fail 'nothing can be written through the mount after a reset'
    fi
    umount "$bind_target" 2>/dev/null || true
else
    echo '  --  skipped: this fixture cannot create a bind mount'
fi
rmdir "$bind_target" 2>/dev/null || true

# --- safety refusals ------------------------------------------------------
# The reset must refuse a data path that is not a mount of its own: that is
# what a failed durable-partition mount looks like, and wiping it would take
# the running root with it.
notmount=$work/not-a-mount
mkdir -p "$notmount/fixture-system"
printf 'precious\n' > "$notmount/precious"
cat > "$work/bad.conf" <<CONF
AB_PRODUCT=fixture
AB_STATE_DIR=$notmount/fixture-system
AB_DATA_MOUNT=$notmount
CONF
printf 'requested=1\n' > "$notmount/fixture-system/factory-reset-requested"
if AB_UPDATE_CONFIG="$work/bad.conf" AB_DATA_SKELETON="$skeleton" /bin/bash "$boot" >/dev/null 2>&1; then
    fail 'reset wiped a directory that was not a mount point'
else
    [ -f "$notmount/precious" ] && ok 'refuses a data path that is not a mount point' \
        || fail 'refused but wiped anyway'
fi

[ "$failures" -eq 0 ] || { echo "factory-reset: $failures FAILURES" >&2; exit 1; }
printf '%s\n' 'factory-reset: PASS'
