#!/bin/bash
# test_data_skeleton_upgrade.sh [old skeleton] - the data skeleton on a device
# updated in place: an older image's skeleton made /data and the device wrote
# into it; the current skeleton (micropanel-data-skeleton.service runs it at
# every boot) must add the paths it knows and leave every existing entry -
# content, owner, mode - exactly as it was, and a second run must change
# nothing. Run as root (the skeleton chowns); others skip.
#   [old skeleton]: default, image 2.09's (git show 512ffd9:...)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
board=$(cd "$here/.." && pwd)
new=$board/packages/micropanel-data-skeleton.sh
[ "$(id -u)" -eq 0 ] || { echo "SKIP: needs root (the skeleton chowns)"; exit 77; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
old=${1:-}
if [ -z "$old" ]; then
    old=$work/old-skeleton.sh
    git -C "$board" show 512ffd9:board-configs/micropanel/packages/micropanel-data-skeleton.sh > "$old" || exit 1
fi
failures=0
ok() { printf '  ok  %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }
# path owner group mode [sha256 of a regular file], for every entry
listing() { (cd "$1" && find . -mindepth 1 | sort | while IFS= read -r p; do
    if [ -f "$p" ]; then printf '%s %s\n' "$(stat -c '%n %U %G %a' "$p")" "$(sha256sum < "$p" | cut -c1-16)"
    else stat -c '%n %U %G %a' "$p"; fi; done); }
data=$work/data; mkdir -p "$data"
seed=$work/no-seed

AB_SEED_ROOT=$seed bash "$old" --root "$data" --uid 1000 --gid 1000 || { echo "old skeleton failed"; exit 1; }
# the device lived with it: content, and a mode an app changed on purpose
echo '{"brightness":40}' > "$data/micropanel/settings.json"; chown 1000:1000 "$data/micropanel/settings.json"
echo 'dummy key' > "$data/micropanel-system/ssh-host-keys/ssh_host_ed25519_key"; chmod 0600 "$data/micropanel-system/ssh-host-keys/ssh_host_ed25519_key"
mkdir -p "$data/kodi/userdata"; echo '<settings/>' > "$data/kodi/userdata/guisettings.xml"; chown -R 1000:1000 "$data/kodi"
chmod 0750 "$data/test-reports"
before=$(listing "$data")
[ ! -e "$data/cluster" ] && [ ! -e "$data/micropanel-system/var-lib-micropanel/dhcp-reservations" ] \
    && ok "the older /data lacks cluster/ and dhcp-reservations (as on rig 1 after the 2.10 update)" \
    || fail "the old skeleton already makes the new paths - wrong baseline"

AB_SEED_ROOT=$seed bash "$new" --root "$data" --uid 1000 --gid 1000 || fail "new skeleton failed"
after=$(listing "$data")
added=$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed -n 's/^> //p')
removed=$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed -n 's/^< //p')
[ -z "$removed" ] && ok "every existing entry identical (content, owner, mode)" || fail "existing entries changed: $removed"
printf '%s\n' "$added" | grep -qx './cluster 1000 1000 755\|./cluster pi pi 755\|./cluster [^ ]* [^ ]* 755' \
    && ok "added: cluster/ (uid 1000, 0755)" || fail "cluster/ not added as expected: $added"
printf '%s\n' "$added" | grep -q '^./micropanel-system/var-lib-micropanel/dhcp-reservations root root 644 ' \
    && ok "added: dhcp-reservations (root, 0644)" || fail "dhcp-reservations not added as expected: $added"
[ "$(printf '%s\n' "$added" | wc -l)" = 2 ] && ok "nothing else added" || fail "unexpected additions: $added"
[ "$(stat -c %a "$data/test-reports")" = 750 ] && ok "a mode an app changed is kept (test-reports 0750)" \
    || fail "test-reports mode reset"

AB_SEED_ROOT=$seed bash "$new" --root "$data" --uid 1000 --gid 1000 || fail "second run failed"
[ "$(listing "$data")" = "$after" ] && ok "a second run changes nothing" || fail "a second run changed something"

# Control: the previous form (install -d on every boot) would reset that mode
AB_SEED_ROOT=$seed bash "$old" --root "$data" --uid 1000 --gid 1000 >/dev/null 2>&1
[ "$(stat -c %a "$data/test-reports")" = 755 ] && ok "control: the old skeleton resets an existing mode (why new_dir is needed)" \
    || fail "control: the old skeleton did not reset the mode - the test proves less than it says"

[ "$failures" -eq 0 ] && { echo "data skeleton upgrade: PASS"; exit 0; }
echo "data skeleton upgrade: $failures failure(s)"; exit 1
