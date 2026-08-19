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

printf '%s\n' 'update-commit-public-status: PASS'
