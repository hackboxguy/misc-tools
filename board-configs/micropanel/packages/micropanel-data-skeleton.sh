#!/bin/bash
# Create the durable micropanel state layout on /data (A/B images only).
#
# Run by the host-side image finalizer on first flash and by the engine's
# factory reset on the device (installed as /usr/local/sbin/ab-data-skeleton),
# so a reset device and a freshly flashed one cannot drift. Keep every
# first-boot state directory here. PERSISTENCE.md says what binds to what.
set -euo pipefail

data_root=""
account="pi"
account_uid=""
account_gid=""

usage() {
    cat >&2 <<'USAGE'
Usage: micropanel-data-skeleton.sh --root DIR [--account NAME]
       micropanel-data-skeleton.sh --root DIR --uid UID --gid GID
USAGE
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --root) data_root=${2:-}; shift 2 ;;
        --account) account=${2:-}; shift 2 ;;
        --uid) account_uid=${2:-}; shift 2 ;;
        --gid) account_gid=${2:-}; shift 2 ;;
        --help|-h) usage ;;
        *) echo "ERROR: unknown option: $1" >&2; usage ;;
    esac
done

[ -n "$data_root" ] || { echo "ERROR: --root is required" >&2; usage; }
case "$data_root" in
    /|.) echo "ERROR: refusing broad data root: $data_root" >&2; exit 2 ;;
esac

if [ -z "$account_uid" ] || [ -z "$account_gid" ]; then
    account_line=$(getent passwd "$account" || true)
    [ -n "$account_line" ] || {
        echo "ERROR: account '$account' is not present; pass --uid/--gid" >&2
        exit 1
    }
    account_uid=$(printf '%s\n' "$account_line" | awk -F: '{print $3}')
    account_gid=$(printf '%s\n' "$account_line" | awk -F: '{print $4}')
fi

[[ "$account_uid" =~ ^[0-9]+$ && "$account_gid" =~ ^[0-9]+$ ]] || {
    echo "ERROR: --uid and --gid must be numeric" >&2
    exit 2
}

# micropanel's own settings (settings.json is a symlink into here).
install -d -m0755 -o "$account_uid" -g "$account_gid" "$data_root/micropanel"
# Restored into /etc/ssh at boot, so a device keeps its host keys across updates.
install -d -m0700 -o root -g root "$data_root/micropanel/ssh-host-keys"
# Bound to /var/lib/micropanel. It holds the DIP-switch service's reboot-loop
# guard, which must survive the reboot it triggers.
install -d -m0755 -o root -g root "$data_root/micropanel/var-lib-micropanel"

# Device identity and update state (AB_STATE_DIR) are root-only system state.
install -d -m0700 -o root -g root "$data_root/micropanel-system"

# Bound to /var/lib/disp-settings (the dual-display mode restored at boot).
install -d -m0755 -o root -g root "$data_root/disp-settings"
# Bound to /home/pi/.kodi (database, add-ons, settings).
install -d -m0755 -o "$account_uid" -g "$account_gid" "$data_root/kodi"
# Bound to the disptool test framework's results directory (measurements).
install -d -m0755 -o "$account_uid" -g "$account_gid" "$data_root/disptool-results"

# NetworkManager's keyfile backend requires this restrictive mode.
install -d -m0700 -o root -g root "$data_root/NetworkManager/system-connections"
