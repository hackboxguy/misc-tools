#!/bin/bash
# Create the durable micropanel state layout on /data (A/B images only).
#
# Run by the host-side image finalizer on first flash, by the engine's
# factory reset on the device (installed as /usr/local/sbin/ab-data-skeleton)
# and at every boot by micropanel-data-skeleton.service, so a reset device, a
# freshly flashed one and one updated in place cannot drift. Additive: a path
# that exists is left as it is. Keep every
# first-boot state directory here. PERSISTENCE.md says what binds to what.
#
# Pristine seeds come from the image itself: $AB_SEED_ROOT is the mounted
# authored root when the finalizer runs this, and /media/root-ro (the read-only
# lower root) when the factory reset does. A seed is copied only into an empty
# destination, so re-running this never overwrites device state.
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

seed_root=${AB_SEED_ROOT:-/media/root-ro}

# new_dir <install -d options...> <path>: create the directory with its owner
# and mode - only when it is not there. The skeleton also runs at every boot
# (micropanel-data-skeleton.service), so a device updated to a newer image
# gets the paths that image adds; what a device already has is never touched
# (install -d alone would reset an existing directory's mode and owner).
new_dir() {
    local path="${*: -1}"
    [ -d "$path" ] || install -d "$@"
}

# micropanel's own settings (settings.json is a symlink into here).
new_dir -m0755 -o "$account_uid" -g "$account_gid" "$data_root/micropanel"

# Device identity and update state (AB_STATE_DIR) are root-only system state.
# The two below live here rather than under the pi-owned micropanel/ so that pi
# cannot rename the host-key directory or the DIP-switch guard.
new_dir -m0700 -o root -g root "$data_root/micropanel-system"
# Restored into /etc/ssh at boot, so a device keeps its host keys across updates.
new_dir -m0700 -o root -g root "$data_root/micropanel-system/ssh-host-keys"
# Bound to /var/lib/micropanel. It holds the DIP-switch service's reboot-loop
# guard, which must survive the reboot it triggers.
new_dir -m0755 -o root -g root "$data_root/micropanel-system/var-lib-micropanel"
# ... and the Network app's reserved DHCP addresses (net-ctl.sh dhcp-reserve;
# dnsmasq reads the file as nobody, hence 0644). Empty: no reservations.
[ -e "$data_root/micropanel-system/var-lib-micropanel/dhcp-reservations" ] || \
    install -m0644 -o root -g root /dev/null "$data_root/micropanel-system/var-lib-micropanel/dhcp-reservations"

# Bound to /var/lib/disp-settings (the dual-display mode restored at boot).
# pi-owned: disp-settings-dual-display-restore.service chowns it to pi:pi on
# every boot anyway, so a reset device must start where a running one is.
new_dir -m0755 -o "$account_uid" -g "$account_gid" "$data_root/disp-settings"
# System Manager (br-wrapper): the logs of its sections, the last-install
# record and the acknowledged fallback. Not device state; a reset empties it.
new_dir -m0755 -o "$account_uid" -g "$account_gid" "$data_root/system-manager"
new_dir -m0755 -o "$account_uid" -g "$account_gid" "$data_root/system-manager/logs"
# Bound to /home/pi/.kodi (database, add-ons, settings).
new_dir -m0755 -o "$account_uid" -g "$account_gid" "$data_root/kodi"
# Bound to the disptool test framework's results directory (measurements).
new_dir -m0755 -o "$account_uid" -g "$account_gid" "$data_root/disptool-results"
# Bound to /home/pi/test-reports: the launcher's display-analysis reports
# (Analyze Color Gamut, Local Dimming APL) - report PNGs and their data.
new_dir -m0755 -o "$account_uid" -g "$account_gid" "$data_root/test-reports"

# als-dimmer's state (mode, manual brightness): every installed als-dimmer config
# names its state_file in here (the appliance hook rewrites them). root: the
# daemon runs as root. A reset empties it, so the dimmer starts in AUTO again.
new_dir -m0755 -o root -g root "$data_root/als-dimmer"

# Cluster Demo V2: the operator's overrides of the proxy's, the emulator's and
# the cluster's env files (can-proxyd.env, car-can-emulator.env,
# qt-cluster-demo.env), read after the image's. Empty: the image's defaults.
new_dir -m0755 -o "$account_uid" -g "$account_gid" "$data_root/cluster"

# Calibration results the Calibration Tools write (disp-tester's children,
# as pi): White Point Matching's white-point-calibration.json, which
# als-dimmer writes into the FPGA at every start, and the wp-cal profiles.
# Bound over /home/pi/system-settings. Empty: no calibration replayed.
new_dir -m0755 -o "$account_uid" -g "$account_gid" "$data_root/system-settings"

# als-dimmer's brightness-to-nits tables (calibrations/*.csv): Brightness
# Calibration's sweep replaces the panel's file (as root, sudo). Bound over
# /home/pi/als-dimmer/etc/als-dimmer/calibrations; seeded below with the
# image's reference tables.
new_dir -m0755 -o root -g root "$data_root/als-dimmer-calibrations"

# The Network app's WiFi switch as the user left it (wifi-radio.state, written
# by net-ctl.sh as root; micropanel-wifi-radio-restore.service applies it
# before NetworkManager starts). Empty: the image's default, WiFi on.
new_dir -m0755 -o root -g root "$data_root/network"

# NetworkManager's keyfile backend requires this restrictive mode.
new_dir -m0700 -o root -g root "$data_root/NetworkManager/system-connections"

# --- Seeds ------------------------------------------------------------------
# kodi: the image's add-ons hook builds a profile (database, keymaps, skin
# patch, settings) in /home/pi/.kodi. /data/kodi is bound over that path, so
# the authored tree survives only as the pristine copy in the lower root.
kodi_seed="$seed_root/home/pi/.kodi"
if [ -d "$kodi_seed" ] && [ -z "$(ls -A "$data_root/kodi")" ]; then
    cp -a "$kodi_seed/." "$data_root/kodi/"
    chown -R "$account_uid:$account_gid" "$data_root/kodi"
fi
# als-dimmer's calibration tables: every image table the device lacks, file by
# file - an update brings new tables, and a table a sweep replaced (the user's
# measurement of this panel) is never overwritten. A reset re-seeds them all.
calib_seed="$seed_root/home/pi/als-dimmer/etc/als-dimmer/calibrations"
if [ -d "$calib_seed" ]; then
    for table in "$calib_seed"/*; do
        [ -f "$table" ] || continue
        [ -e "$data_root/als-dimmer-calibrations/${table##*/}" ] || \
            cp -p "$table" "$data_root/als-dimmer-calibrations/"
    done
fi

# settings.json: the appliance hook moves an authored one (if the image ever
# ships one) to settings.json.default and links the live path into /data.
settings_seed="$seed_root/home/pi/micropanel/share/micropanel/settings.json.default"
if [ -f "$settings_seed" ] && [ ! -e "$data_root/micropanel/settings.json" ]; then
    install -m0644 -o "$account_uid" -g "$account_gid" "$settings_seed" \
        "$data_root/micropanel/settings.json"
fi
