#!/bin/sh
set -eu

commit_helper=$1
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

state_directory=$temporary_directory/data/micropanel-touch-system
status_directory=$temporary_directory/run/micropanel-touch-update
mkdir -p "$state_directory"
# The filesystem holding the fixture stands in for /data (it must be the
# mount the state directory is on, read-write, for a refusal to be recorded).
data_mount=$(findmnt -rn -T "$state_directory" -o TARGET)
# Never the real reboot: a refusal on a candidate boot reboots by default.
reboot_log=$temporary_directory/reboot.log
fake_reboot=$temporary_directory/reboot
printf '#!/bin/sh\necho reboot >> "%s"\n' "$reboot_log" > "$fake_reboot"
chmod 0755 "$fake_reboot"
export AB_REBOOT_COMMAND="$fake_reboot" AB_DATA_MOUNT="$data_mount"

write_state() {
    printf '%s\n' \
        "state=$1" \
        'candidate_slot=B' \
        'version=00.17' \
        'variant=luckfox-ctp' > "$state_directory/update-state"
    chmod 0600 "$state_directory/update-state"
}

run_helper() {
    AB_STATE_DIR="$state_directory" \
    AB_RUNTIME_DIR="$status_directory" \
    AB_HEALTH_UNITS="fixture.service" \
    /bin/bash "$commit_helper"
}

# These normal-boot states must be visible to the unprivileged HMI without
# requiring a slot selector or a live systemd instance.
write_state committed
run_helper
grep -Fqx 'state=committed' "$status_directory/status"
test "$(stat -c %a "$status_directory")" = 755
test "$(stat -c %a "$status_directory/status")" = 644

write_state fallback
run_helper
grep -Fqx 'state=fallback' "$status_directory/status"
# state= first, then the candidate the state is about.
[ "$(head -n 1 "$status_directory/status")" = 'state=fallback' ]
grep -Fqx 'version=00.17' "$status_directory/status"
grep -Fqx 'candidate_slot=B' "$status_directory/status"

# A normal boot running the candidate that the normal selector already selects:
# committed out of band (by hand), and recorded as such.
fake_selector=$temporary_directory/selector
tryboot_marker=$temporary_directory/tryboot
printf '\000\000\000\000' > "$tryboot_marker"
run_normal_boot() { # $1=current slot $2=normal slot
    printf '#!/bin/sh\ncase "$1" in current-slot) echo %s ;; normal-slot) echo %s ;; *) exit 1 ;; esac\n' "$1" "$2" > "$fake_selector"
    chmod 0755 "$fake_selector"
    AB_STATE_DIR="$state_directory" AB_RUNTIME_DIR="$status_directory" AB_HEALTH_UNITS="fixture.service" \
    AB_SLOT_SELECTOR="$fake_selector" AB_TRYBOOT_MARKER="$tryboot_marker" \
    /bin/bash "$commit_helper" >/dev/null
}
write_state candidate-armed
run_normal_boot B B
grep -Fqx 'state=committed' "$state_directory/update-state"
grep -Fqx 'state=committed' "$status_directory/status"
# ...but not while the normal selector still boots the other slot.
write_state candidate-armed
run_normal_boot B A
grep -Fqx 'state=candidate-armed' "$state_directory/update-state"
grep -Fqx 'state=candidate-armed' "$status_directory/status"
# and a normal boot of the other slot is still a fallback.
write_state candidate-armed
run_normal_boot A A
grep -Fqx 'state=fallback' "$state_directory/update-state"

# None of the normal boots above may reboot: only a refused tryboot candidate
# does.
[ ! -e "$reboot_log" ] || { echo 'a normal boot requested a reboot' >&2; exit 1; }

# A tryboot candidate boot that never gets healthy says why when it gives up
# (here: its health unit never becomes active within a 1 s readiness wait)...
refusal_file=$state_directory/update-refusal
expected_reason='not healthy within 1 s: health unit pi-ab-update-fixture-absent.service is not active'
run_refused_candidate() { # $1=AB_ON_REFUSAL (empty = the default)
    printf '\001\000\000\000' > "$tryboot_marker"
    printf '#!/bin/sh\ncase "$1" in current-slot) echo B ;; normal-slot) echo A ;; *) exit 1 ;; esac\n' > "$fake_selector"
    write_state candidate-armed
    rm -f "$reboot_log" "$refusal_file"
    AB_ON_REFUSAL="$1" AB_STATE_DIR="$state_directory" AB_RUNTIME_DIR="$status_directory" \
        AB_HEALTH_UNITS="pi-ab-update-fixture-absent.service" AB_COMMIT_WAIT_SECONDS=1 \
        AB_SLOT_SELECTOR="$fake_selector" AB_TRYBOOT_MARKER="$tryboot_marker" \
        /bin/bash "$commit_helper"
}
reason=$(run_refused_candidate '')
printf '%s\n' "$reason" | grep -Fqx "[INFO] not committing candidate slot B: $expected_reason" || {
    echo "unexpected give-up reason: $reason" >&2; exit 1; }
grep -Fqx 'state=candidate-armed' "$state_directory/update-state"
# ...records why, durably and root-only, beside (not inside) update-state...
grep -Fqx 'version=00.17' "$refusal_file"
grep -Fqx 'candidate_slot=B' "$refusal_file"
grep -Fqx "refused_reason=$expected_reason" "$refusal_file"
test "$(stat -c %a "$refusal_file")" = 600
[ "$(wc -l < "$state_directory/update-state")" = 4 ] || { echo 'the refusal changed update-state' >&2; exit 1; }
# ...and, by default, reboots: the tryboot flag is spent, the committed slot boots.
[ "$(cat "$reboot_log" 2>/dev/null)" = reboot ] || { echo 'a refused candidate did not reboot' >&2; exit 1; }
printf '%s\n' "$reason" | grep -Fqx '[INFO] rebooting to the committed slot (AB_ON_REFUSAL=reboot)'

# The committed slot's boot records the fallback, and the reason reaches the
# public status (and so the UI) with it.
printf '\000\000\000\000' > "$tryboot_marker"
printf '#!/bin/sh\ncase "$1" in current-slot) echo A ;; normal-slot) echo A ;; *) exit 1 ;; esac\n' > "$fake_selector"
AB_STATE_DIR="$state_directory" AB_RUNTIME_DIR="$status_directory" AB_HEALTH_UNITS="fixture.service" \
    AB_SLOT_SELECTOR="$fake_selector" AB_TRYBOOT_MARKER="$tryboot_marker" /bin/bash "$commit_helper" >/dev/null
grep -Fqx 'state=fallback' "$state_directory/update-state"
grep -Fqx 'state=fallback' "$status_directory/status"
grep -Fqx "refused_reason=$expected_reason" "$status_directory/status"
[ "$(cat "$reboot_log")" = reboot ] || { echo 'the fallback boot rebooted again' >&2; exit 1; }
# Later boots keep publishing it while the state is that fallback.
run_helper >/dev/null
grep -Fqx "refused_reason=$expected_reason" "$status_directory/status"
# A reason recorded for a different candidate is not this fallback's.
sed -i 's/^version=.*/version=00.16/' "$refusal_file"
run_helper >/dev/null
if grep -q '^refused_reason=' "$status_directory/status"; then echo 'a stale refusal was published' >&2; exit 1; fi

# AB_ON_REFUSAL=stay keeps the refused candidate up (bench inspection), still
# recording why.
reason=$(run_refused_candidate stay)
printf '%s\n' "$reason" | grep -Fqx "[INFO] not committing candidate slot B: $expected_reason"
[ ! -e "$reboot_log" ] || { echo 'AB_ON_REFUSAL=stay rebooted' >&2; exit 1; }
grep -Fqx "refused_reason=$expected_reason" "$refusal_file"
# Anything else is refused outright, as every other setting is.
if run_refused_candidate later >/dev/null 2>&1; then echo 'AB_ON_REFUSAL=later was accepted' >&2; exit 1; fi
[ ! -e "$reboot_log" ] || { echo 'an invalid AB_ON_REFUSAL rebooted' >&2; exit 1; }

printf '%s\n' 'update-commit-public-status: PASS'
