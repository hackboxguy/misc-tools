#!/bin/sh
set -eu

commit_helper=$1
unit=$2

grep -Fq 'if ! is_tryboot_candidate; then' "$commit_helper"
grep -Fq 'ConditionPathExists=/usr/local/sbin/ab-slot-selector' "$unit"
# The health predicate is data plus one optional hook. Every configured unit
# must be active, none may have restarted, and the hook must exit 0.
grep -Fq 'for unit in $health_units; do' "$commit_helper"
grep -Fq 'systemctl is-active --quiet "$unit" || return 1' "$commit_helper"
grep -Fq 'systemctl show --value --property=NRestarts "$unit"' "$commit_helper"
grep -Fq '"$health_hook" >/dev/null 2>&1 || return 1' "$commit_helper"
grep -Fq '[ -x "$health_hook" ] || return 1' "$commit_helper"
grep -Fq '[ "${pair#*=}" = 0 ] || exit 0' "$commit_helper"
grep -Fq 'while ! candidate_is_healthy "$restarts"; do' "$commit_helper"
grep -Fq 'candidate_is_healthy "$restarts" || exit 0' "$commit_helper"
# An empty unit list would make the predicate assert nothing at all.
grep -Fq 'AB_HEALTH_UNITS is empty' "$commit_helper"
grep -Fq 'write_update_state fallback' "$commit_helper"
grep -Fq 'publish_status fallback' "$commit_helper"
grep -Fq 'publish_status committed' "$commit_helper"
grep -Fq '"$selector" commit "$current_slot"' "$commit_helper"
grep -Fq 'write_update_state committed' "$commit_helper"
grep -Fq 'TimeoutStartSec=3min' "$unit"
# Ordering after the health units is a per-board drop-in the finalizer writes
# from AB_HEALTH_UNITS, so the shared unit itself names none of them.
! grep -Eq 'micropanel|MicroPanel' "$unit"
! grep -Eq 'micropanel|MicroPanel' "$commit_helper"

printf '%s\n' 'update-commit-policy: PASS'
