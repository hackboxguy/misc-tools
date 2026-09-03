#!/bin/bash
# Create the durable MicroPanel Touch state layout.
#
# This file is deliberately usable both by the host-side image finalizer and
# by a later in-system factory-reset handler.  Keep all first-boot state
# directories here so those two paths cannot drift.
set -euo pipefail

data_root=""
account="micropanel-touch"
account_uid=""
account_gid=""

usage() {
    cat >&2 <<'EOF'
Usage: micropanel-touch-data-skeleton.sh --root DIR [--account NAME]
       micropanel-touch-data-skeleton.sh --root DIR --uid UID --gid GID
EOF
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

install -d -m0750 -o "$account_uid" -g "$account_gid" "$data_root/micropanel-touch"
install -d -m0750 -o "$account_uid" -g "$account_gid" "$data_root/micropanel-touch/logs"
install -d -m0700 -o root -g root "$data_root/micropanel-touch/ssh-host-keys"

# Device identity is security-sensitive system state. It intentionally lives
# outside the HMI account's writable application directory.
install -d -m0700 -o root -g root "$data_root/micropanel-touch-system"

# The DHCP-server configuration is root-owned but visible to the HMI so it
# can restore selector state; the HMI must never be able to write it.
install -d -m0750 -o root -g "$account_gid" "$data_root/micropanel-touch-network"
install -d -m0750 -o root -g "$account_gid" \
    "$data_root/micropanel-touch-network/dhcp-server"

# xmproxy (jsonrpc-tcp-srv): the daemon's etc and state subdirectories are
# created and seeded by xmproxy-seed.service at boot, because the xmproxy
# account's uid is only known inside the image. Only the root directory is
# part of the skeleton so a factory reset leaves a well-defined tree.
install -d -m0755 -o root -g root "$data_root/xmproxy"

# NetworkManager's keyfile backend requires this restrictive mode.
install -d -m0700 -o root -g root "$data_root/NetworkManager/system-connections"
