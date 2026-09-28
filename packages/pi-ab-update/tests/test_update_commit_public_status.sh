#!/bin/sh
set -eu

commit_helper=$1
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

state_directory=$temporary_directory/data/micropanel-touch-system
status_directory=$temporary_directory/run/micropanel-touch-update
mkdir -p "$state_directory"

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

# A tryboot candidate boot that never gets healthy says why when it gives up
# (here: its health unit never becomes active within a 1 s readiness wait).
printf '\001\000\000\000' > "$tryboot_marker"
printf '#!/bin/sh\ncase "$1" in current-slot) echo B ;; normal-slot) echo A ;; *) exit 1 ;; esac\n' > "$fake_selector"
write_state candidate-armed
reason=$(AB_STATE_DIR="$state_directory" AB_RUNTIME_DIR="$status_directory" \
    AB_HEALTH_UNITS="pi-ab-update-fixture-absent.service" AB_COMMIT_WAIT_SECONDS=1 \
    AB_SLOT_SELECTOR="$fake_selector" AB_TRYBOOT_MARKER="$tryboot_marker" \
    /bin/bash "$commit_helper")
printf '%s\n' "$reason" | grep -Fqx '[INFO] not committing candidate slot B: not healthy within 1 s: health unit pi-ab-update-fixture-absent.service is not active' || {
    echo "unexpected give-up reason: $reason" >&2; exit 1; }
grep -Fqx 'state=candidate-armed' "$state_directory/update-state"

printf '%s\n' 'update-commit-public-status: PASS'
