#!/bin/bash
set -e

# network-fallback-hook.sh - runs inside the ARM64 chroot.
#
# eth0 policy: DHCP with automatic static fallback via NetworkManager's
# native two-profile autoconnect-priority mechanism (RaspiOS bookworm/trixie
# use NM by default - no scripts, no dhcpcd):
#
#   1. eth0-dhcp (priority 10): DHCP, 15s timeout, single attempt
#   2. eth0-static-fallback (priority 0): 192.168.10.3/24, no gateway/DNS
#      (bench-network use; a bogus default route would blackhole traffic)
#
# Timing: carrier + ~15s DHCP timeout -> static active a second later.
# No carrier = no profile activates (NM waits for the cable).
# NM does NOT switch back automatically if a DHCP server appears
# mid-session - replug the cable or reboot to renegotiate (accepted).

NM_DIR=/etc/NetworkManager/system-connections
FALLBACK_IP="192.168.10.3/24"
DHCP_TIMEOUT=15

echo "======================================"
echo "  eth0 DHCP + static-fallback (NM)"
echo "======================================"
echo "Fallback IP: $FALLBACK_IP (after ${DHCP_TIMEOUT}s DHCP timeout)"

mkdir -p "$NM_DIR"

# Fixed UUIDs keep image builds deterministic (stamp/content stable).
cat > "$NM_DIR/eth0-dhcp.nmconnection" <<EOF
[connection]
id=eth0-dhcp
uuid=7a1e9c2f-3d54-4b8a-9c6e-1f2a3b4c5d6e
type=ethernet
interface-name=eth0
autoconnect=true
autoconnect-priority=10
autoconnect-retries=1

[ipv4]
method=auto
dhcp-timeout=$DHCP_TIMEOUT

[ipv6]
method=auto
EOF

cat > "$NM_DIR/eth0-static-fallback.nmconnection" <<EOF
[connection]
id=eth0-static-fallback
uuid=b8f4d7e1-6a29-4c3b-8d5f-2e3a4b5c6d7f
type=ethernet
interface-name=eth0
autoconnect=true
autoconnect-priority=0

[ipv4]
method=manual
address1=$FALLBACK_IP

[ipv6]
method=link-local
EOF

# NM refuses connection files that are not root-owned mode 600
chown root:root "$NM_DIR"/eth0-dhcp.nmconnection "$NM_DIR"/eth0-static-fallback.nmconnection
chmod 600 "$NM_DIR"/eth0-dhcp.nmconnection "$NM_DIR"/eth0-static-fallback.nmconnection

echo "Installed NM profiles:"
ls -l "$NM_DIR"
echo "eth0 network fallback configured."
