#!/bin/bash
# Run every pi-ab-update suite. The two loopback fixtures need root and skip
# themselves without it, so this is useful both as a quick check and as the
# full pre-flash gate.
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

if [ "$(id -u)" -eq 0 ]; then
    run 'handler loopback'   bash "$engine/tests/test_system_update_handler_integration.sh" "$engine/ab-system-update"
    run 'layout loopback'    bash "$engine/tests/test_ab_layout_integration.sh"
else
    printf '\nSKIP: the two loopback fixtures need root (re-run with sudo)\n'
fi

printf '\n'
[ "$failures" -eq 0 ] || { printf 'pi-ab-update: %s SUITE(S) FAILED\n' "$failures" >&2; exit 1; }
printf 'pi-ab-update: all suites passed\n'
