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
grep -Fq '[ "${pair#*=}" = 0 ] || give_up "health unit ${pair%%=*} has already restarted (${pair#*=})"' "$commit_helper"
grep -Fq 'while ! candidate_is_healthy "$restarts"; do' "$commit_helper"
grep -Fq 'candidate_is_healthy "$restarts" || give_up "health lost in the settle window: $(health_failure "$restarts")"' "$commit_helper"
# An empty unit list would make the predicate assert nothing at all.
grep -Fq 'AB_HEALTH_UNITS is empty' "$commit_helper"
grep -Fq 'write_update_state fallback' "$commit_helper"
grep -Fq 'publish_status fallback' "$commit_helper"
grep -Fq 'publish_status committed' "$commit_helper"
grep -Fq '"$selector" commit "$current_slot"' "$commit_helper"
grep -Fq 'write_update_state committed' "$commit_helper"
# A candidate running on a normal boot that the normal selector selects was
# committed out of band; the record follows the boot selector.
grep -Fq 'elif [ "$("$selector" normal-slot 2>/dev/null || true)" = "$current_slot" ]; then' "$commit_helper"
# E3: never a oneshot - a target waits for its oneshots to finish, so a health
# unit ordered after multi-user.target would wait for this service to give up.
grep -Fqx 'Type=exec' "$unit" || { echo 'the commit unit is not Type=exec (a oneshot blocks multi-user.target)' >&2; exit 1; }
if grep -Eq '^Type=oneshot' "$unit"; then echo 'the commit unit is a oneshot again (blocks multi-user.target)' >&2; exit 1; fi
grep -Fqx 'RuntimeMaxSec=5min' "$unit"
# Every exit from a candidate boot without a commit logs the reason.
grep -Fq "give_up \"not healthy within \${wait_seconds} s: \$(health_failure \"\$restarts\")\"" "$commit_helper"
if awk '/^publish_status candidate-armed$/ { armed = 1 } armed && /\|\| exit 0$/ { found = 1 } END { exit !found }' "$commit_helper"; then
    echo 'a candidate-boot exit path gives no reason' >&2; exit 1
fi
# A refused candidate does not keep running (v11 §3.1b): after give_up's line,
# reboot - only on a tryboot candidate boot, only with AB_ON_REFUSAL=reboot
# (the default) - and record the reason beside update-state, never in it (an
# older committed image parses update-state strictly).
grep -Fq 'on_refusal=$(ab_setting "${AB_ON_REFUSAL:-}" AB_ON_REFUSAL reboot)' "$commit_helper"
grep -Fq 'if [ "$on_refusal" = reboot ] && is_tryboot_candidate; then' "$commit_helper"
grep -Fq 'case "$on_refusal" in reboot|stay) ;; *) die' "$commit_helper"
grep -Fq 'refusal_file=${AB_REFUSAL_FILE:-$state_dir/update-refusal}' "$commit_helper"
awk '/^give_up\(\) \{/ { g = 1 } g && /record_refusal/ { r = 1 } g && /"\$reboot_command"/ { b = r } g && /^}/ { g = 0 } END { exit !b }' "$commit_helper" || {
    echo 'give_up does not record the reason before it reboots' >&2; exit 1; }
if awk '/^write_update_state\(\) \{/ { w = 1 } w && /refused/ { bad = 1 } w && /^}/ { w = 0 } END { exit !bad }' "$commit_helper"; then
    echo 'the refusal reason went into update-state (older images parse it strictly)' >&2; exit 1
fi
# Ordering after the health units is a per-board drop-in the finalizer writes
# from AB_HEALTH_UNITS, so the shared unit itself names none of them.
if grep -Eq 'micropanel|MicroPanel' "$unit"; then echo "test_update_commit_policy.sh: forbidden pattern found (line $LINENO)" >&2; exit 1; fi
if grep -Eq 'micropanel|MicroPanel' "$commit_helper"; then echo "test_update_commit_policy.sh: forbidden pattern found (line $LINENO)" >&2; exit 1; fi

printf '%s\n' 'update-commit-policy: PASS'
