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
REPO_RAW_URL="https://raw.githubusercontent.com/hackboxguy/media-mux/master"

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
# Step 1: Disable dnsmasq, minidlna, and chrony auto-start
#------------------------------------------------------------------------------
log_step "[1/11] Disabling dnsmasq/minidlna/chrony auto-start..."
systemctl stop dnsmasq 2>/dev/null || true
systemctl stop minidlna 2>/dev/null || true
systemctl stop chrony 2>/dev/null || true
systemctl disable dnsmasq 2>/dev/null || true
systemctl disable minidlna 2>/dev/null || true
systemctl disable chrony 2>/dev/null || true
log_ok "services disabled"

#------------------------------------------------------------------------------
# Step 2: Create dnsmasq configuration
#------------------------------------------------------------------------------
log_step "[2/11] Creating dnsmasq configuration..."
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

# NTP server (this device)
dhcp-option=42,${STATIC_IP}

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
log_step "[3/11] Creating minidlna configuration..."
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

# Log directory
log_dir=/var/log

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
log_step "[4/11] Creating USB mount point..."
mkdir -p "${USB_MOUNT_POINT}"
log_ok "mount point"

#------------------------------------------------------------------------------
# Step 5: Create chrony configurations
#------------------------------------------------------------------------------
log_step "[5/11] Creating chrony configurations..."

# Master mode config (NTP server)
cat > /etc/chrony/chrony-master.conf << EOF
# Media-Mux Chrony Master Configuration (NTP Server)
# This file is managed by media-mux-selfhosted-addon-hook.sh

# Use public NTP servers as upstream (when internet is available)
pool pool.ntp.org iburst

# Allow NTP clients on the local network
allow 192.168.8.0/24

# Serve time even if not synchronized to an upstream source
local stratum 10

# Record the rate at which the system clock gains/loses time
driftfile /var/lib/chrony/drift

# Log files location
logdir /var/log/chrony

# Step clock if offset is larger than 1 second (faster initial sync)
makestep 1 3
EOF

# Slave mode config (NTP client)
cat > /etc/chrony/chrony-slave.conf << EOF
# Media-Mux Chrony Slave Configuration (NTP Client)
# This file is managed by media-mux-selfhosted-addon-hook.sh

# Use the master Pi as NTP server
server ${STATIC_IP} iburst prefer

# Fallback to public NTP if master is unreachable
pool pool.ntp.org iburst

# Record the rate at which the system clock gains/loses time
driftfile /var/lib/chrony/drift

# Log files location
logdir /var/log/chrony

# Step clock if offset is larger than 1 second (faster initial sync)
makestep 1 3
EOF

log_ok "chrony configs"

#------------------------------------------------------------------------------
# Step 6: Create boot script
#------------------------------------------------------------------------------
log_step "[6/11] Creating selfhosted boot script..."

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

    # Ensure minidlna directories exist with correct permissions
    log "Preparing minidlna directories..."
    mkdir -p /var/lib/minidlna
    mkdir -p /run/minidlna
    chown -R minidlna:minidlna /var/lib/minidlna 2>/dev/null || true
    chown -R minidlna:minidlna /run/minidlna 2>/dev/null || true

    # Start minidlna with our config
    log "Starting minidlna..."
    minidlnad -f /etc/minidlna-selfhosted.conf
    sleep 3
    if pgrep -f minidlnad > /dev/null; then
        log "minidlna started successfully (PID: $(pgrep -f minidlnad))"
    else
        log "minidlna first attempt failed, retrying..."
        sleep 2
        minidlnad -f /etc/minidlna-selfhosted.conf
        sleep 2
        if pgrep -f minidlnad > /dev/null; then
            log "minidlna started successfully on retry (PID: $(pgrep -f minidlnad))"
        else
            log "ERROR: minidlna failed to start"
        fi
    fi

    # Start chrony as NTP server
    log "Starting chrony (NTP server)..."
    chronyd -f /etc/chrony/chrony-master.conf
    sleep 2
    if pgrep -f chronyd > /dev/null; then
        log "chrony started successfully (PID: $(pgrep -f chronyd))"
    else
        log "ERROR: chrony failed to start"
    fi

    log "Master mode configured successfully"
    log "  Static IP: $STATIC_IP"
    log "  DHCP range: 192.168.8.100-200"
    log "  DLNA: http://${STATIC_IP}:8200/"
    log "  NTP: serving time to clients"
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
    sleep 5

    # Start chrony as NTP client (sync from master)
    log "Starting chrony (NTP client)..."
    chronyd -f /etc/chrony/chrony-slave.conf
    sleep 2
    if pgrep -f chronyd > /dev/null; then
        log "chrony started successfully (PID: $(pgrep -f chronyd))"
    else
        log "WARNING: chrony failed to start"
    fi
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
log_step "[7/11] Creating systemd service..."
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
# Step 8: Download Kodi add-on from GitHub
#------------------------------------------------------------------------------
log_step "[8/11] Downloading Kodi add-on from GitHub..."

ADDON_SRC_DIR="${INSTALL_DIR}/kodi-addon/service.mediamux.sync"
mkdir -p "${ADDON_SRC_DIR}/resources/keymaps"

# List of files to download (Python code - no compilation needed)
ADDON_FILES=(
    "addon.xml"
    "default.py"
    "service.py"
    "context.py"
    "stop.py"
    "VideoOSD.xml"
    "start-sync-playback.png"
    "stop-sync-playback.png"
    "resources/keymaps/mediamux.xml"
)

DOWNLOAD_OK=true
for file in "${ADDON_FILES[@]}"; do
    target="${ADDON_SRC_DIR}/${file}"
    mkdir -p "$(dirname "$target")"
    if ! curl -fsSL -o "$target" "${REPO_RAW_URL}/kodi-addon/service.mediamux.sync/${file}"; then
        echo "[WARN] Failed to download: ${file}"
        DOWNLOAD_OK=false
    fi
done

if [ "$DOWNLOAD_OK" = true ]; then
    chown -R 1000:1000 "${INSTALL_DIR}/kodi-addon"
    log_ok "kodi addon download"
else
    echo "[PARTIAL] Some files failed to download"
fi

# Download sync and stop scripts (ensure latest versions from GitHub)
log_step "        Downloading sync script..."
if curl -fsSL -o "${INSTALL_DIR}/media-mux-sync-kodi-players.sh" "${REPO_RAW_URL}/media-mux-sync-kodi-players.sh"; then
    chmod +x "${INSTALL_DIR}/media-mux-sync-kodi-players.sh"
    chown 1000:1000 "${INSTALL_DIR}/media-mux-sync-kodi-players.sh"
    log_ok "sync script"
else
    echo "[WARN] Failed to download sync script"
fi

log_step "        Downloading stop script..."
if curl -fsSL -o "${INSTALL_DIR}/media-mux-stop-kodi-players.sh" "${REPO_RAW_URL}/media-mux-stop-kodi-players.sh"; then
    chmod +x "${INSTALL_DIR}/media-mux-stop-kodi-players.sh"
    chown 1000:1000 "${INSTALL_DIR}/media-mux-stop-kodi-players.sh"
    log_ok "stop script"
else
    echo "[WARN] Failed to download stop script"
fi

# Download Kodi Addons database template (pre-configured addon settings)
log_step "        Downloading Addons33.db template..."
KODI_TEMPLATE_DIR="${INSTALL_DIR}/kodi-addon/templates/Database"
mkdir -p "${KODI_TEMPLATE_DIR}"
if curl -fsSL -o "${KODI_TEMPLATE_DIR}/Addons33.db" "${REPO_RAW_URL}/kodi-addon/templates/Database/Addons33.db"; then
    chown 1000:1000 "${KODI_TEMPLATE_DIR}/Addons33.db"
    log_ok "Addons33.db template"
else
    echo "[WARN] Failed to download Addons33.db template"
fi

#------------------------------------------------------------------------------
# Step 9: Install Kodi Media-Mux Sync add-on
#------------------------------------------------------------------------------
log_step "[9/11] Installing Kodi Media-Mux Sync add-on..."

KODI_USER_HOME="/home/pi"
KODI_ADDONS_DIR="${KODI_USER_HOME}/.kodi/addons"
KODI_USERDATA_DIR="${KODI_USER_HOME}/.kodi/userdata"
ADDON_SRC_DIR="${INSTALL_DIR}/kodi-addon/service.mediamux.sync"

# Create Kodi directories if they don't exist
mkdir -p "${KODI_ADDONS_DIR}"
mkdir -p "${KODI_USERDATA_DIR}/keymaps"

# Copy the add-on
if [ -d "${ADDON_SRC_DIR}" ]; then
    rm -rf "${KODI_ADDONS_DIR}/service.mediamux.sync"
    cp -r "${ADDON_SRC_DIR}" "${KODI_ADDONS_DIR}/"
    # Remove VideoOSD.xml and icons from add-on dir (they go elsewhere)
    rm -f "${KODI_ADDONS_DIR}/service.mediamux.sync/VideoOSD.xml"
    rm -f "${KODI_ADDONS_DIR}/service.mediamux.sync/start-sync-playback.png"
    rm -f "${KODI_ADDONS_DIR}/service.mediamux.sync/stop-sync-playback.png"
    chown -R 1000:1000 "${KODI_ADDONS_DIR}/service.mediamux.sync"
    log_ok "kodi addon"
else
    echo "[SKIP] Add-on source not found at ${ADDON_SRC_DIR}"
fi

#------------------------------------------------------------------------------
# Step 10: Patch Kodi Estuary skin with Sync button
#------------------------------------------------------------------------------
log_step "[10/11] Patching Kodi skin with Sync button..."

SYSTEM_SKIN_DIR="/usr/share/kodi/addons/skin.estuary"
USER_SKIN_DIR="${KODI_ADDONS_DIR}/skin.estuary"

# Copy Estuary skin to user directory if not already there
if [ -d "${SYSTEM_SKIN_DIR}" ] && [ ! -d "${USER_SKIN_DIR}" ]; then
    cp -r "${SYSTEM_SKIN_DIR}" "${USER_SKIN_DIR}"
fi

if [ -d "${USER_SKIN_DIR}" ]; then
    # Copy custom icons (sync and stop)
    mkdir -p "${USER_SKIN_DIR}/media/osd/fullscreen/buttons"
    if [ -f "${ADDON_SRC_DIR}/start-sync-playback.png" ]; then
        cp "${ADDON_SRC_DIR}/start-sync-playback.png" "${USER_SKIN_DIR}/media/osd/fullscreen/buttons/"
    fi
    if [ -f "${ADDON_SRC_DIR}/stop-sync-playback.png" ]; then
        cp "${ADDON_SRC_DIR}/stop-sync-playback.png" "${USER_SKIN_DIR}/media/osd/fullscreen/buttons/"
    fi

    # Copy patched VideoOSD.xml
    if [ -f "${ADDON_SRC_DIR}/VideoOSD.xml" ]; then
        cp "${ADDON_SRC_DIR}/VideoOSD.xml" "${USER_SKIN_DIR}/xml/VideoOSD.xml"
    fi

    # Copy keymap
    if [ -f "${ADDON_SRC_DIR}/resources/keymaps/mediamux.xml" ]; then
        cp "${ADDON_SRC_DIR}/resources/keymaps/mediamux.xml" "${KODI_USERDATA_DIR}/keymaps/"
    fi

    chown -R 1000:1000 "${USER_SKIN_DIR}"
    chown -R 1000:1000 "${KODI_USERDATA_DIR}/keymaps"
    log_ok "skin patch"
else
    echo "[SKIP] Kodi skin not found at ${USER_SKIN_DIR}"
fi

#------------------------------------------------------------------------------
# Step 11: Install pre-configured Kodi addons database
#------------------------------------------------------------------------------
log_step "[11/11] Installing Kodi addons database template..."

KODI_DB_DIR="${KODI_USER_HOME}/.kodi/userdata/Database"
KODI_TEMPLATE_DIR="${INSTALL_DIR}/kodi-addon/templates/Database"

# Create Kodi Database directory
mkdir -p "${KODI_DB_DIR}"

# Copy pre-configured Addons33.db template
# This template has:
#   - service.mediamux.sync enabled (no startup prompt)
#   - service.xbmc.versioncheck disabled (no version popup)
if [ -f "${KODI_TEMPLATE_DIR}/Addons33.db" ]; then
    cp "${KODI_TEMPLATE_DIR}/Addons33.db" "${KODI_DB_DIR}/"
    chown -R 1000:1000 "${KODI_DB_DIR}"
    log_ok "Addons33.db installed"
else
    echo "[WARN] Addons33.db template not found at ${KODI_TEMPLATE_DIR}"
fi

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
echo "    - NTP: serving time to clients"
echo ""
echo "  - No USB storage → Slave mode"
echo "    - DHCP client"
echo "    - NTP client (syncs from master)"
echo ""
echo "USB mount point: ${USB_MOUNT_POINT}"
echo "Log file: /var/log/media-mux-selfhosted.log"
echo ""
echo "Kodi Sync Add-on:"
echo "  - OSD button: Tap screen during playback → 'Sync' button"
echo "  - Keyboard shortcut: Press 'S' during video"
echo "  - Programs menu: Programs → Add-ons → Media-Mux Sync"
echo "======================================"
