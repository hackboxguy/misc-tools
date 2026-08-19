#!/bin/bash
# Run every pi-ab-update suite. The three loopback fixtures need root and skip
# themselves without it, so this is useful both as a quick check and as the
# full pre-flash gate. The update-check suite starts a local HTTP server on
# the loopback interface; nothing here reaches the network.
set -uo pipefail

engine=$(cd "$(dirname "$0")/.." && pwd)
failures=0

run() { # $1=label, rest=command
    local label=$1; shift
    printf '\n=== %s ===\n' "$label"
    if "$@"; then
        printf '    %s: PASS\n' "$label"
    else
        printf '    %s: FAIL\n' "$label" >&2
        failures=$((failures + 1))
    fi
}

run 'static contract'        sh "$engine/tests/test_ab_layout_static.sh"
run 'handler policy'         sh "$engine/tests/test_system_update_handler_policy.sh" "$engine/ab-system-update"
run 'bundle reader'          bash "$engine/tests/test_update_bundle_reader.sh" "$engine/ab-system-update"
run 'commit policy'          sh "$engine/tests/test_update_commit_policy.sh" "$engine/ab-update-commit" "$engine/ab-update-commit.service"
run 'commit public status'   sh "$engine/tests/test_update_commit_public_status.sh" "$engine/ab-update-commit"
run 'update check'           bash "$engine/tests/test_ota_check.sh" "$engine/ab-update-check"

if [ "$(id -u)" -eq 0 ]; then
    run 'handler loopback'   bash "$engine/tests/test_system_update_handler_integration.sh" "$engine/ab-system-update"
    # These fixtures allocate loop devices back to back. Letting udev finish
    # with the ones just released costs a moment and removes the most likely
    # explanation for the layout fixture's rare failures inside a full pass.
    # Unproven as a fix - the failure has never reproduced on demand - but it
    # is free, and the fixture now reports where it died if it recurs.
    command -v udevadm >/dev/null 2>&1 && udevadm settle || true
    run 'layout loopback'    bash "$engine/tests/test_ab_layout_integration.sh"
    run 'factory reset'      bash "$engine/tests/test_factory_reset.sh" \
        "$engine/ab-factory-reset" "$engine/ab-factory-reset-boot" \
        "$engine/../../board-configs/micropanel-touch/packages/micropanel-touch-data-skeleton.sh"
else
    printf '\nSKIP: the three loopback fixtures need root (re-run with sudo)\n'
fi

printf '\n'
[ "$failures" -eq 0 ] || { printf 'pi-ab-update: %s SUITE(S) FAILED\n' "$failures" >&2; exit 1; }
printf 'pi-ab-update: all suites passed\n'
