#!/bin/bash
set -e

# Media-Mux Self-Hosted Addon Hook
#
# Configures the Pi to act as DHCP/DNS/DLNA server when USB storage is detected.
# This eliminates the need for an external pocket router.
#
# Boot behavior:
# - USB storage detected → Master mode (static IP, DHCP, DLNA)
# - No USB storage → Slave mode (DHCP client, connects to pocket router)

INSTALL_DIR="${HOOK_INSTALL_DEST:-/home/pi/media-mux}"
LOG_FILE="/var/log/media-mux-selfhosted-setup.log"

# Configuration
STATIC_IP="192.168.8.1"
NETMASK="24"
DHCP_RANGE_START="192.168.8.100"
DHCP_RANGE_END="192.168.8.200"
DHCP_LEASE_TIME="12h"
DLNA_PORT="8200"
USB_MOUNT_POINT="/media/usb"
ETH_INTERFACE="eth0"

echo "======================================"
echo "  Media-Mux Self-Hosted Addon Hook"
echo "======================================"
echo ""
echo "This addon enables USB-based master/slave mode detection."
echo ""

# Helper functions
log_step() {
    printf "%-50s " "$1"
}

log_ok() {
    echo "[OK]"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [OK] $1" >> "$LOG_FILE"
}

log_fail() {
    echo "[FAIL]"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [FAIL] $1" >> "$LOG_FILE"
    exit 1
}

#------------------------------------------------------------------------------
# Step 1: Disable dnsmasq and minidlna auto-start
#------------------------------------------------------------------------------
log_step "[1/6] Disabling dnsmasq/minidlna auto-start..."
systemctl stop dnsmasq 2>/dev/null || true
systemctl stop minidlna 2>/dev/null || true
systemctl disable dnsmasq 2>/dev/null || true
systemctl disable minidlna 2>/dev/null || true
log_ok "services disabled"

#------------------------------------------------------------------------------
# Step 2: Create dnsmasq configuration
#------------------------------------------------------------------------------
log_step "[2/6] Creating dnsmasq configuration..."
cat > /etc/dnsmasq.d/media-mux-selfhosted.conf << EOF
# Media-Mux Self-Hosted DHCP/DNS Configuration
# This file is managed by media-mux-selfhosted-addon-hook.sh

# Interface to listen on
interface=${ETH_INTERFACE}
bind-interfaces

# DHCP range
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_LEASE_TIME}

# Gateway (this device)
dhcp-option=3,${STATIC_IP}

# DNS (forward to public DNS)
server=8.8.8.8
server=8.8.4.4

# Local domain
domain=mediamux.local
local=/mediamux.local/

# Don't read /etc/resolv.conf
no-resolv

# DHCP authoritative mode
dhcp-authoritative
EOF
log_ok "dnsmasq config"

#------------------------------------------------------------------------------
# Step 3: Create minidlna configuration
#------------------------------------------------------------------------------
log_step "[3/6] Creating minidlna configuration..."
cat > /etc/minidlna-selfhosted.conf << EOF
# Media-Mux Self-Hosted DLNA Configuration
# This file is managed by media-mux-selfhosted-addon-hook.sh

# Network interface
network_interface=${ETH_INTERFACE}

# Port
port=${DLNA_PORT}

# Media directory (USB mount point)
media_dir=V,${USB_MOUNT_POINT}
media_dir=A,${USB_MOUNT_POINT}
media_dir=P,${USB_MOUNT_POINT}

# Friendly name (matches Kodi's pre-configured source)
friendly_name=dlnaserver

# Fixed UUID matching pocket router's minidlna config
# This allows the same sources.xml to work with both self-hosted and pocket router DLNA
uuid=dlnaserver

# Database location
db_dir=/var/lib/minidlna

# Automatic discovery of new files
inotify=yes

# Strictly adhere to DLNA standards
strict_dlna=no

# Presentation URL
presentation_url=http://${STATIC_IP}:${DLNA_PORT}/

# Model name and number
model_name=Media-Mux
model_number=1
EOF
log_ok "minidlna config"

#------------------------------------------------------------------------------
# Step 4: Create USB mount point
#------------------------------------------------------------------------------
log_step "[4/6] Creating USB mount point..."
mkdir -p "${USB_MOUNT_POINT}"
log_ok "mount point"

#------------------------------------------------------------------------------
# Step 5: Create boot script
#------------------------------------------------------------------------------
log_step "[5/6] Creating selfhosted boot script..."

cat > "$INSTALL_DIR/media-mux-selfhosted-boot.sh" << 'BOOTSCRIPT'
#!/bin/bash
#
# media-mux-selfhosted-boot.sh
# Runs at boot to detect USB and configure master/slave mode
#

LOG_FILE="/var/log/media-mux-selfhosted.log"
STATIC_IP="192.168.8.1"
NETMASK="24"
ETH_INTERFACE="eth0"
USB_MOUNT_POINT="/media/usb"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

#------------------------------------------------------------------------------
# Detect USB storage device
#------------------------------------------------------------------------------
detect_usb_storage() {
    # Look for USB block devices (exclude boot SD card)
    for dev in /sys/block/sd*; do
        if [ -d "$dev" ]; then
            devname=$(basename "$dev")
            # Check if it's a USB device
            if readlink -f "$dev/device" | grep -q "usb"; then
                echo "/dev/${devname}"
                return 0
            fi
        fi
    done
    return 1
}

#------------------------------------------------------------------------------
# Mount USB storage
#------------------------------------------------------------------------------
mount_usb() {
    local device="$1"

    # Try to find a partition, otherwise use the device directly
    if [ -b "${device}1" ]; then
        device="${device}1"
    fi

    log "Mounting $device to $USB_MOUNT_POINT"

    # Create mount point
    mkdir -p "$USB_MOUNT_POINT"

    # Try to mount (support ntfs, vfat, ext4)
    if mount -o ro "$device" "$USB_MOUNT_POINT" 2>/dev/null; then
        log "USB mounted successfully (read-only)"
        return 0
    elif mount "$device" "$USB_MOUNT_POINT" 2>/dev/null; then
        log "USB mounted successfully"
        return 0
    else
        log "Failed to mount USB device"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Configure master mode (static IP, DHCP, DLNA)
#------------------------------------------------------------------------------
configure_master_mode() {
    log "=== MASTER MODE ==="

    # Stop NetworkManager and dhcpcd from managing eth0
    log "Stopping network managers for $ETH_INTERFACE..."
    systemctl stop NetworkManager 2>/dev/null || true
    systemctl stop dhcpcd 2>/dev/null || true

    # Release any DHCP lease
    dhclient -r "$ETH_INTERFACE" 2>/dev/null || true

    # Kill any dhclient processes for this interface
    pkill -f "dhclient.*$ETH_INTERFACE" 2>/dev/null || true

    # Configure static IP
    log "Setting static IP: $STATIC_IP/$NETMASK on $ETH_INTERFACE"
    ip addr flush dev "$ETH_INTERFACE"
    ip addr add "${STATIC_IP}/${NETMASK}" dev "$ETH_INTERFACE"
    ip link set "$ETH_INTERFACE" up

    # Wait for interface to be ready
    sleep 2

    # Start dnsmasq (DHCP/DNS)
    log "Starting dnsmasq..."
    systemctl start dnsmasq
    if systemctl is-active --quiet dnsmasq; then
        log "dnsmasq started successfully"
    else
        log "ERROR: dnsmasq failed to start"
    fi

    # Ensure minidlna database directory exists with correct permissions
    log "Preparing minidlna database directory..."
    mkdir -p /var/lib/minidlna
    chown minidlna:minidlna /var/lib/minidlna 2>/dev/null || true

    # Start minidlna with our config (without -R to avoid startup issues)
    # The -r flag does a soft rescan, -R does a full rebuild which can fail at boot
    log "Starting minidlna..."
    minidlnad -f /etc/minidlna-selfhosted.conf
    sleep 3
    if pgrep -x minidlnad > /dev/null; then
        log "minidlna started successfully"
        # Trigger rescan after daemon is running
        log "Triggering media rescan..."
        kill -HUP $(pgrep -x minidlnad) 2>/dev/null || true
    else
        log "minidlna first attempt failed, retrying..."
        sleep 2
        minidlnad -f /etc/minidlna-selfhosted.conf
        sleep 2
        if pgrep -x minidlnad > /dev/null; then
            log "minidlna started successfully on retry"
        else
            log "ERROR: minidlna failed to start"
        fi
    fi

    log "Master mode configured successfully"
    log "  Static IP: $STATIC_IP"
    log "  DHCP range: 192.168.8.100-200"
    log "  DLNA: http://${STATIC_IP}:8200/"
    log "  USB media: $USB_MOUNT_POINT"
}

#------------------------------------------------------------------------------
# Configure slave mode (DHCP client)
#------------------------------------------------------------------------------
configure_slave_mode() {
    log "=== SLAVE MODE ==="
    log "No USB storage detected - running as DHCP client"

    # Let the system's default network manager handle DHCP
    # Just ensure NetworkManager or dhcpcd is running
    if systemctl is-enabled NetworkManager 2>/dev/null; then
        log "NetworkManager will handle DHCP"
        systemctl start NetworkManager 2>/dev/null || true
    elif systemctl is-enabled dhcpcd 2>/dev/null; then
        log "dhcpcd will handle DHCP"
        systemctl start dhcpcd 2>/dev/null || true
    else
        # Fallback to manual dhclient
        log "Using dhclient for DHCP"
        dhclient "$ETH_INTERFACE" 2>/dev/null || true
    fi

    log "Waiting for network..."
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
log "========================================"
log "Media-Mux Self-Hosted Boot"
log "========================================"

# Wait for system to settle (USB devices to be recognized)
log "Waiting for USB devices to settle..."
sleep 3

# Detect USB storage (with retry)
USB_DEVICE=""
for i in 1 2 3; do
    USB_DEVICE=$(detect_usb_storage)
    if [ -n "$USB_DEVICE" ]; then
        break
    fi
    log "USB detection attempt $i - not found, retrying..."
    sleep 2
done

if [ -n "$USB_DEVICE" ]; then
    log "USB storage detected: $USB_DEVICE"

    if mount_usb "$USB_DEVICE"; then
        configure_master_mode
    else
        log "USB mount failed - falling back to slave mode"
        configure_slave_mode
    fi
else
    log "No USB storage detected"
    configure_slave_mode
fi

log "Boot script complete"
BOOTSCRIPT

chmod +x "$INSTALL_DIR/media-mux-selfhosted-boot.sh"
log_ok "boot script"

#------------------------------------------------------------------------------
# Step 6: Create systemd service
#------------------------------------------------------------------------------
log_step "[6/6] Creating systemd service..."
cat > /etc/systemd/system/media-mux-selfhosted.service << EOF
[Unit]
Description=Media-Mux Self-Hosted Boot
After=local-fs.target
Before=network-online.target
Wants=local-fs.target

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/media-mux-selfhosted-boot.sh
RemainAfterExit=yes
TimeoutStartSec=60
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable media-mux-selfhosted.service
log_ok "systemd service"

#------------------------------------------------------------------------------
# Set ownership
#------------------------------------------------------------------------------
echo ""
echo "Setting ownership..."
chown 1000:1000 "$INSTALL_DIR/media-mux-selfhosted-boot.sh"

#------------------------------------------------------------------------------
# Complete
#------------------------------------------------------------------------------
echo ""
echo "======================================"
echo "  Self-Hosted Addon Installation Complete"
echo "======================================"
echo ""
echo "Boot behavior:"
echo "  - USB storage attached → Master mode"
echo "    - Static IP: ${STATIC_IP}"
echo "    - DHCP: ${DHCP_RANGE_START}-${DHCP_RANGE_END}"
echo "    - DLNA: http://${STATIC_IP}:${DLNA_PORT}/"
echo ""
echo "  - No USB storage → Slave mode (DHCP client)"
echo ""
echo "USB mount point: ${USB_MOUNT_POINT}"
echo "Log file: /var/log/media-mux-selfhosted.log"
echo "======================================"
