#!/bin/bash
# Drive ab-update against a fake device: a manifest, a slot selector stub, and
# the published runtime files. No root, no loop devices - everything this front
# end does is read published state or hand off to an engine, and that is
# precisely what is checked here.
set -uo pipefail

cli=${1:?path to ab-update is required}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
failures=0
ok()   { printf '  ok  %-46s -> %s\n' "$1" "$2"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

# --- a device that has never updated --------------------------------------
install -d "$work/run" "$work/state" "$work/lib" "$work/bin"
printf '%s\n' 'IMAGE_LAYOUT=ab' 'PANEL_VARIANT=luckfox-ctp' \
    'MICROPANEL_TOUCH_REVISION=abc123def456' 'IMAGE_VERSION=00.36' > "$work/image-manifest.env"
printf '%s\n' '#!/bin/sh' 'echo B' > "$work/bin/selector"; chmod 0755 "$work/bin/selector"
# Stand-ins that record what they were asked to do rather than doing it.
for e in updater checker; do
    printf '%s\n' '#!/bin/sh' "echo \"\$0 called with: \$*\" >> $work/calls" \
        'exit 0' > "$work/bin/$e"   # draining stdin here blocks when no pipe is passed
    chmod 0755 "$work/bin/$e"
done

run() {
    AB_UPDATE_CONFIG=/nonexistent \
    AB_IMAGE_MANIFEST="$work/image-manifest.env" \
    AB_STATE_DIR="$work/state" AB_RUNTIME_DIR="$work/run" \
    AB_SLOT_SELECTOR="$work/bin/selector" \
    AB_UPDATE_SCRIPT="$work/bin/updater" AB_CHECK_SCRIPT="$work/bin/checker" \
    AB_LOCK_FILE="$work/run/update.lock" \
        /bin/bash "$cli" "$@" 2>&1 </dev/null
}

# --- single-value queries are exactly one line, for scripting -------------
out=$(run --active-version)
[ "$out" = "00.36" ] && ok 'query: --active-version' "$out" || fail "--active-version gave '$out'"
out=$(run --active-slot)
[ "$out" = "B" ] && ok 'query: --active-slot' "$out" || fail "--active-slot gave '$out'"
out=$(run --active-revision)
[ "$out" = "abc123def456" ] && ok 'query: --active-revision' "$out" || fail "--active-revision gave '$out'"

# --- absent state is reported, never invented -----------------------------
run --state >/dev/null 2>&1 && fail '--state succeeded with no state recorded' \
    || ok 'query: --state with no history' 'fails rather than inventing one'
run --check-state >/dev/null 2>&1 && fail '--check-state succeeded with no check' \
    || ok 'query: --check-state before any check' 'fails rather than inventing one'

# --- published state is read back faithfully ------------------------------
printf '%s\n' 'state=committed' 'candidate_slot=B' 'version=00.36' > "$work/state/update-state"
printf '%s\n' 'state=available' 'version=00.99' > "$work/run/check"
printf '%s\n' 'phase=writing' 'progress=42' > "$work/run/progress"
out=$(run --state)
[ "$out" = committed ] && ok 'query: --state' "$out" || fail "--state gave '$out'"
out=$(run --check-state)
[ "$out" = available ] && ok 'query: --check-state' "$out" || fail "--check-state gave '$out'"

# --- a reader that cannot see the durable record still gets the truth ------
# The durable state is root-only by design, and the commit service publishes a
# bounded summary of it for everyone else. Read unprivileged, this tool used to
# answer "no update state recorded" on a device that had plainly been updated -
# not a smaller answer than root's, a wrong one. An absent durable file
# exercises the same branch as an unreadable one: both fail the same read.
mv "$work/state/update-state" "$work/state/update-state.hidden"
printf '%s\n' 'state=committed' > "$work/run/status"
out=$(run --state 2>/dev/null)
[ "$out" = committed ] && ok 'query: --state without the durable record' "$out" \
    || fail "--state fell back to '$out'"
# Captured, not piped into grep -q: this suite runs with `set -o pipefail`,
# and grep -q exits on the first match, so the command under test is killed
# mid-write and the pipeline reports 141 (SIGPIPE) however well it matched.
status_output=$(run status 2>/dev/null || true)
case "$status_output" in
    *"state              committed"*) ok 'status: reads the public summary too' 'committed' ;;
    *) fail 'status still says no update has run' ;;
esac
# The durable record wins when it is readable: it is the authority, and it
# carries detail the summary does not.
mv "$work/state/update-state.hidden" "$work/state/update-state"
printf '%s\n' 'state=fallback' > "$work/run/status"
out=$(run --state)
[ "$out" = committed ] && ok 'query: the durable record outranks the summary' "$out" \
    || fail "--state preferred the summary and gave '$out'"
rm -f "$work/run/status"

# --- status is a superset, and mentions what a person needs ---------------
out=$(run status)
for want in '00.36' 'committed' 'available' 'writing'; do
    printf '%s' "$out" | grep -Fq "$want" || fail "status omitted '$want'"
done
printf '%s' "$out" | grep -Fq 'Inactive slot' && ok 'status: one screen' 'version, slot, state, check, progress' \
    || fail 'status did not describe the inactive slot'

# --- install hands off to the engine; it never installs anything itself ---
# Installing needs root, so which assertion applies depends on who is running
# the suite. Both are worth making: unprivileged, the refusal must be a clear
# message rather than a confusing engine error; as root, the delegation must
# actually reach the engine with the source unchanged.
: > "$work/bundle.mpupdate"
if [ "$(id -u)" -eq 0 ]; then
    for src in ota usb; do
        rm -f "$work/calls"
        run install "$src" >/dev/null 2>&1
        grep -q "called with: $src" "$work/calls" 2>/dev/null \
            && ok "install $src" 'delegates to the engine' \
            || fail "install $src did not invoke the engine"
    done
    rm -f "$work/calls"
    run install --file="$work/bundle.mpupdate" >/dev/null 2>&1
    grep -q "called with: stdin" "$work/calls" 2>/dev/null \
        && ok 'install --file' 'delegates as the stdin source' \
        || fail 'install --file did not use the engine stdin source'
else
    for src in ota usb; do
        out=$(run install "$src")
        printf '%s' "$out" | grep -Fq 'needs root' \
            && ok "install $src unprivileged" 'refused, and says to use sudo' \
            || fail "install $src gave an unhelpful unprivileged error: $out"
    done
    [ -s "$work/calls" ] && fail 'the engine was invoked without root' \
        || ok 'unprivileged install' 'never reaches the engine'
fi

# --- the pre-install warning names the units that would block a commit ----
# Pinned statically elsewhere; exercised here, because the value of this
# warning is entirely in what it says to a person about to wait out a long
# download for an update that cannot stick.
# Only observable as root: the privilege check runs first, and rightly so -
# there is no point warning about a commit predicate to someone who cannot
# start the install at all.
if [ "$(id -u)" -eq 0 ]; then
    rm -f "$work/calls"
    warn=$(AB_UPDATE_CONFIG=/nonexistent AB_IMAGE_MANIFEST="$work/image-manifest.env" \
        AB_STATE_DIR="$work/state" AB_RUNTIME_DIR="$work/run" \
        AB_SLOT_SELECTOR="$work/bin/selector" AB_UPDATE_SCRIPT="$work/bin/updater" \
        AB_HEALTH_UNITS="definitely-absent-unit.service" \
        /bin/bash "$cli" install ota 2>&1 </dev/null)
    if printf '%s' "$warn" | grep -Fq 'definitely-absent-unit.service' &&
       printf '%s' "$warn" | grep -Fq 'fall back'; then
        ok 'install warns about a down commit unit' 'names the unit and the consequence'
    else
        fail "install did not warn about a down commit unit: $warn"
    fi
    # ...and warns without blocking: someone recovering a half-broken device
    # has to be able to install into it.
    grep -q "called with: ota" "$work/calls" 2>/dev/null \
        && ok 'the warning does not block the install' 'engine still invoked' \
        || fail 'the warning blocked the install'
fi

# --- bad input is refused, not guessed ------------------------------------
run install >/dev/null 2>&1 && fail 'install with no source succeeded' \
    || ok 'install with no source' 'refused'
run install github >/dev/null 2>&1 && fail 'install accepted an unknown source' \
    || ok 'install with an unknown source' 'refused'
run --file=/etc/passwd >/dev/null 2>&1 && fail 'a bare --file was accepted as a command' \
    || ok 'unknown top-level flag' 'refused'
run install --file=/nonexistent/bundle.mpupdate >/dev/null 2>&1 && fail 'install accepted a missing file' \
    || ok 'install --file with a missing path' 'refused'

# --- the rule this front end exists under ---------------------------------
# It composes and delegates. Any version comparison, compatibility rule or
# health judgement here would be a second copy of engine policy, and the copy
# people run would be the one no fixture covers.
! grep -qE '(offered|available).*(>|<|-gt|-lt)|sort -V|version_greater' "$cli" \
    && ok 'contains no version comparison' 'composes, never decides' \
    || fail 'the front end appears to compare versions'
grep -Fq 'exec "$updater"' "$cli" && ok 'installs only by exec-ing the engine' 'no second write path' \
    || fail 'the front end does not delegate installs by exec'

[ "$failures" -eq 0 ] || { echo "update-cli: $failures FAILURES" >&2; exit 1; }
printf '%s\n' 'update-cli: PASS'
