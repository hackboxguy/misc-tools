#!/bin/bash
set -e

# Media-Mux Pre-compiled Binaries Installation Hook
#
# Downloads and installs pre-compiled media-mux without build tools.
# No git, gcc, or npm required on target.
#
# Environment variables:
# - HOOK_GIT_REPO: Override download URL (optional)
# - HOOK_INSTALL_DEST: Installation directory (default: /home/pi/media-mux)

BINS_VERSION="01"
# Note: Change branch from 'dynamic-config' to 'master' once merged
RELEASE_URL="${HOOK_GIT_REPO:-https://raw.githubusercontent.com/hackboxguy/media-mux/dynamic-config/bins/media-mux-bins-${BINS_VERSION}-arm64.tar.gz}"
INSTALL_DIR="${HOOK_INSTALL_DEST:-/home/pi/media-mux}"
LOG_FILE="/var/log/media-mux-setup.log"

echo "======================================"
echo "  Media-Mux Bins Installation Hook"
echo "======================================"
echo ""
echo "Download URL: $RELEASE_URL"
echo "Install directory: $INSTALL_DIR"
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
# Step 1: Download pre-compiled tarball
#------------------------------------------------------------------------------
log_step "[1/7] Downloading pre-compiled media-mux..."
cd /tmp
rm -f media-mux-bins.tar.gz
if curl -fSL -o media-mux-bins.tar.gz "$RELEASE_URL"; then
    log_ok "download"
else
    log_fail "Failed to download from $RELEASE_URL"
fi

#------------------------------------------------------------------------------
# Step 2: Extract to install directory
#------------------------------------------------------------------------------
log_step "[2/7] Extracting to $INSTALL_DIR..."
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
if tar -xzf media-mux-bins.tar.gz -C "$INSTALL_DIR"; then
    log_ok "extract"
else
    log_fail "Failed to extract tarball"
fi
rm -f media-mux-bins.tar.gz

#------------------------------------------------------------------------------
# Step 3: Setup autoplay symlink (auto-negotiation mode)
#------------------------------------------------------------------------------
log_step "[3/7] Setting up auto-startup player..."
cd "$INSTALL_DIR"
rm -f media-mux-autoplay.sh
ln -s media-mux-autoplay-master.sh media-mux-autoplay.sh
log_ok "autoplay symlink"

#------------------------------------------------------------------------------
# Step 4: Create first-boot marker
#------------------------------------------------------------------------------
log_step "[4/7] Creating first-boot marker..."
touch "$INSTALL_DIR/.first-boot-pending"
chmod +x "$INSTALL_DIR/media-mux-first-boot.sh"
log_ok "first-boot marker"

#------------------------------------------------------------------------------
# Step 5: Setup rc.local (auto-negotiation mode)
#------------------------------------------------------------------------------
log_step "[5/7] Configuring rc.local..."
cp "$INSTALL_DIR/rc.local.auto" /etc/rc.local
chmod +x /etc/rc.local
log_ok "rc.local"

#------------------------------------------------------------------------------
# Step 6: Setup Kodi configuration
#------------------------------------------------------------------------------
log_step "[6/7] Configuring Kodi settings..."
mkdir -p /home/pi/.kodi/userdata
cp "$INSTALL_DIR/sources.xml" /home/pi/.kodi/userdata/ 2>/dev/null || true
cp "$INSTALL_DIR/guisettings.xml" /home/pi/.kodi/userdata/ 2>/dev/null || true
log_ok "Kodi config"

#------------------------------------------------------------------------------
# Step 7: Configure HDMI audio output
#------------------------------------------------------------------------------
log_step "[7/7] Configuring HDMI audio..."
CONFIG_FILE="/boot/firmware/config.txt"
if [ -f "$CONFIG_FILE" ]; then
    if ! grep -q "^hdmi_drive=2" "$CONFIG_FILE" 2>/dev/null; then
        echo "hdmi_drive=2" >> "$CONFIG_FILE"
    fi
fi
# Create PulseAudio config to set HDMI as default sink
mkdir -p /home/pi/.config/pulse
cat > /home/pi/.config/pulse/default.pa << 'PULSE_EOF'
.include /etc/pulse/default.pa
# Set HDMI as default sink for media-mux
set-default-sink alsa_output.platform-fef05700.hdmi.hdmi-stereo
PULSE_EOF
log_ok "HDMI audio"

#------------------------------------------------------------------------------
# Set ownership to pi user (uid:gid 1000:1000)
#------------------------------------------------------------------------------
echo ""
echo "Setting ownership..."
chown -R 1000:1000 "$INSTALL_DIR"
chown -R 1000:1000 /home/pi/.kodi 2>/dev/null || true
chown -R 1000:1000 /home/pi/.config 2>/dev/null || true

#------------------------------------------------------------------------------
# Verify installation
#------------------------------------------------------------------------------
echo ""
echo "Verifying installation..."
if [ -x "$INSTALL_DIR/media-mux-controller" ]; then
    echo "  media-mux-controller: OK"
else
    echo "  media-mux-controller: MISSING"
fi
if [ -d "$INSTALL_DIR/kodisync/node_modules" ]; then
    echo "  kodisync/node_modules: OK"
else
    echo "  kodisync/node_modules: MISSING"
fi

#------------------------------------------------------------------------------
# Complete
#------------------------------------------------------------------------------
echo ""
echo "======================================"
echo "  Media-Mux Installation Complete"
echo "======================================"
echo "Mode: AUTO-NEGOTIATION (pre-compiled)"
echo "Hostname will be generated from MAC address on first boot"
echo "Any device can trigger sync (no fixed master/slave roles)"
echo ""
echo "Installation path: $INSTALL_DIR"
echo "Bins version: $BINS_VERSION"
echo "Log file: $LOG_FILE"
echo "======================================"
