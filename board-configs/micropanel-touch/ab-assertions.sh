#!/bin/bash
# MicroPanel Touch assertions for the pi-ab-update image verifier.
#
# The engine checks the cross-board layout and its own footprint; this checks
# what is true of *this* product's image: its app account, its manifest keys,
# and the durable /data skeleton its first boot depends on.
set -euo pipefail

root_mount=${AB_ROOT_MOUNT:?AB_ROOT_MOUNT is required}
data_mount=${AB_DATA_MOUNT:?AB_DATA_MOUNT is required}
image_manifest=${AB_IMAGE_MANIFEST:?AB_IMAGE_MANIFEST is required}
expected_revision=${MICROPANEL_TOUCH_REVISION:-}

require() { "$@" || { echo "ERROR: board assertion failed: $*" >&2; exit 1; }; }

require grep -Fq 'SLOT_COMPATIBLE_BOARDS=pi4' "$image_manifest"
require grep -Eq '^PANEL_VARIANT=[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' "$image_manifest"
if [ -n "$expected_revision" ]; then
    require grep -Fqx "MICROPANEL_TOUCH_REVISION=$expected_revision" "$image_manifest"
else
    require grep -Eq '^MICROPANEL_TOUCH_REVISION=[0-9a-f]{40}$' "$image_manifest"
fi
# The health hook the board profile points AB_HEALTH_HOOK at.
require test -x "$root_mount/usr/lib/micropanel-touch/update-health"

for directory in micropanel-touch micropanel-touch/logs micropanel-touch/ssh-host-keys \
                 micropanel-touch-system micropanel-touch-network/dhcp-server \
                 NetworkManager/system-connections xmproxy; do
    require test -d "$data_mount/$directory"
done
app_account=$(awk -F: '$1 == "micropanel-touch" { print $3 ":" $4; exit }' "$root_mount/etc/passwd")
case "$app_account" in
    [0-9]*:[0-9]*) ;;
    *) echo "ERROR: missing micropanel-touch account in root A" >&2; exit 1 ;;
esac
app_group=${app_account#*:}
require test "$(stat -c '%u:%g:%a' "$data_mount/micropanel-touch")" = "${app_account}:750"
require test "$(stat -c '%u:%g:%a' "$data_mount/micropanel-touch/logs")" = "${app_account}:750"
require test "$(stat -c '%u:%g:%a' "$data_mount/micropanel-touch/ssh-host-keys")" = '0:0:700'
require test "$(stat -c '%u:%g:%a' "$data_mount/micropanel-touch-system")" = '0:0:700'
require test "$(stat -c '%u:%g:%a' "$data_mount/micropanel-touch-network")" = "0:${app_group}:750"
require test "$(stat -c '%u:%g:%a' "$data_mount/micropanel-touch-network/dhcp-server")" = "0:${app_group}:750"
require test "$(stat -c '%u:%g:%a' "$data_mount/NetworkManager/system-connections")" = '0:0:700'
# xmproxy (jsonrpc-tcp-srv): binaries, defaults, account, units and manifest key
require test -x "$root_mount/opt/xmproxy/bin/xmproxysrv"
require test -x "$root_mount/opt/xmproxy/bin/sysmgr"
require test -x "$root_mount/opt/xmproxy/bin/xmproxy-seed.sh"
require test -f "$root_mount/opt/xmproxy/share/xmproxy/etc/manifest.json"
require test -f "$root_mount/usr/lib/sysusers.d/xmproxy.conf"
require grep -Eq '^xmproxy:' "$root_mount/etc/passwd"
for unit in xmproxy-seed sysmgr xmproxysrv; do
    require test -L "$root_mount/etc/systemd/system/multi-user.target.wants/$unit.service"
done
require grep -Eq '^JSONRPC_TCP_SRV_REVISION=[0-9a-f]{40}$' "$image_manifest"
require test "$(stat -c '%u:%g:%a' "$data_mount/xmproxy")" = '0:0:755'
