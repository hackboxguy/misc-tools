#!/bin/bash
set -e

# The chroot hook environment may not export /usr/sbin (where dkms, i2cdetect,
# depmod live), which surfaces as "dkms: command not found" even when installed.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# pi5-gmsl-vd56g4 setup hook - runs inside the ARM64 chroot (apps stage).
#
# Bakes the VD56G4 GMSL camera (AD-GMSL716MIPI-EVK / MAX96716A) into a vanilla
# Pi OS Lite trixie image so a Pi 5 boots straight into a live HDMI feed:
#   1. DKMS-install the out-of-tree vb56g4a driver (DESER=max96716a) against the
#      image's stock kernel headers - no custom kernel, survives apt upgrades.
#   2. Install the gmsl-camera sensor firmware blobs.
#   3. Build + install the CSI-2 overlays (csi1 = Channel A, csi0 = Channel B).
#   4. config.txt (Channel A default) + modprobe.d (udc variant).
#   5. Install the gst->kmssink launcher + a channel-select helper.
#   6. systemd: auto-play Channel A on boot; Channel-B bring-up unit shipped
#      disabled (the helper toggles between them).
#
# Source: the private gmsl-vd56g4 repo, copied into the chroot by the imager
# (HOOK_LOCAL_SOURCE). See board.conf SOURCES + hooks.txt file:// reference.

SRC="${HOOK_LOCAL_SOURCE:-}"
echo "======================================"
echo "  pi5-gmsl-vd56g4 Setup Hook"
echo "======================================"
[ -z "$SRC" ] && { echo "ERROR: HOOK_LOCAL_SOURCE unset (gmsl-vd56g4 must be a file:// local source)"; exit 1; }
[ -d "$SRC" ] || { echo "ERROR: source not found at $SRC"; exit 1; }
echo "Source: $SRC"

# Fail loudly if the private repo lacks the Pi 5 bring-up artifacts (must be
# pushed to gmsl-vd56g4 'main': tools/ launcher + cam0 overlay from the
# PI5-EVK bring-up commit).
for f in dkms.conf driver/vb56g4a.c dts/vd56g4-max96716a-rpi5.dts \
         tools/vd56g4-hdmi-rpi5.sh tools/vd56g4-chanB-setup.sh; do
	[ -e "$SRC/$f" ] || { echo "ERROR: $SRC/$f missing - push the gmsl-vd56g4 Pi 5 bring-up commit"; exit 1; }
done
ls "$SRC"/firmware/harman_vb56g4a_*.bin >/dev/null 2>&1 || { echo "ERROR: firmware blobs missing under $SRC/firmware/"; exit 1; }

#------------------------------------------------------------------------------
# 1. DKMS install the driver (DESER=max96716a for the AD-GMSL716 EVK)
#------------------------------------------------------------------------------
echo "[1/6] DKMS install vb56g4a driver ..."
# Hooks run BEFORE the apps-stage runtime-dep (re)install, and the vanilla Lite
# image ships kernel headers but not dkms, so ensure our build prerequisites
# here (they also persist in the final image via runtime-deps.txt). This mirrors
# the generic-package-hook, which apt-installs its own HOOK_DEP_LIST.
export DEBIAN_FRONTEND=noninteractive
if ! command -v dkms >/dev/null 2>&1; then
	echo "  installing dkms (+ toolchain) in chroot ..."
	apt-get update -qq
	apt-get install -y dkms
fi

PKG=gmsl-vd56g4 ; VER=0.1.0
DKMS_SRC="/usr/src/${PKG}-${VER}"
rm -rf "$DKMS_SRC"
cp -a "$SRC" "$DKMS_SRC"
rm -rf "$DKMS_SRC/.git"

# The repo dkms.conf builds board=generic (defaults to the MAX9296A deser). This
# board is the MAX96716A EVK, so append DESER=max96716a to the DKMS make line.
sed -i 's|\(MAKE\[0\]=.*board=generic\)|\1 DESER=max96716a|' "$DKMS_SRC/dkms.conf"
echo "  dkms make line: $(grep -m1 'MAKE\[0\]' "$DKMS_SRC/dkms.conf")"

# Target kernel = the Pi 5 (2712) kernel whose headers runtime-deps installed.
KVER="$(ls -1 /lib/modules 2>/dev/null | grep -- '-rpi-2712' | sort -V | tail -1)"
[ -z "$KVER" ] && KVER="$(ls -1 /lib/modules | sort -V | tail -1)"
if [ ! -d "/lib/modules/$KVER/build" ]; then
	echo "  installing kernel headers ..."
	apt-get install -y linux-headers-rpi-2712 || apt-get install -y "linux-headers-${KVER}" || true
	KVER="$(ls -1 /lib/modules 2>/dev/null | grep -- '-rpi-2712' | sort -V | tail -1)"
fi
[ -d "/lib/modules/$KVER/build" ] || { echo "ERROR: no kernel build tree for $KVER (linux-headers-rpi-2712 not installed?)"; exit 1; }
echo "  building for kernel $KVER"

dkms add    -m "$PKG" -v "$VER" 2>&1 | tail -2 || true
dkms build  -m "$PKG" -v "$VER" -k "$KVER"
dkms install -m "$PKG" -v "$VER" -k "$KVER" --force
echo "  installed modules:"; find /lib/modules/"$KVER" -name 'vb56g4a.ko*' -o -name 'generic_adapter.ko*' 2>/dev/null | sed 's/^/    /'

#------------------------------------------------------------------------------
# 2. Firmware blobs (driver request_firmware()s these from /lib/firmware/harman)
#------------------------------------------------------------------------------
echo "[2/6] Installing gmsl-camera firmware blobs ..."
mkdir -p /lib/firmware/harman
cp "$SRC"/firmware/harman_vb56g4a_*.bin /lib/firmware/harman/
echo "  $(ls /lib/firmware/harman/ | wc -l) blobs in /lib/firmware/harman/"

#------------------------------------------------------------------------------
# 3. Device-tree overlays (csi1 = Channel A; csi0 = Channel B if present)
#------------------------------------------------------------------------------
echo "[3/6] Building + installing overlays ..."
mkdir -p /boot/firmware/overlays
dtc -@ -I dts -O dtb -o /boot/firmware/overlays/vd56g4-max96716a-rpi5.dtbo \
	"$SRC/dts/vd56g4-max96716a-rpi5.dts" 2>/dev/null
echo "  installed vd56g4-max96716a-rpi5.dtbo (Channel A / csi1)"
if [ -e "$SRC/dts/vd56g4-max96716a-rpi5-cam0.dts" ]; then
	dtc -@ -I dts -O dtb -o /boot/firmware/overlays/vd56g4-max96716a-rpi5-cam0.dtbo \
		"$SRC/dts/vd56g4-max96716a-rpi5-cam0.dts" 2>/dev/null
	echo "  installed vd56g4-max96716a-rpi5-cam0.dtbo (Channel B / csi0)"
fi

#------------------------------------------------------------------------------
# 4. config.txt (Channel A default) + modprobe.d (udc variant)
#    NB: Pi config.txt has NO inline comments - a comment on a dtoverlay= line
#    makes the firmware treat it as part of the overlay spec and silently fail.
#------------------------------------------------------------------------------
echo "[4/6] Configuring config.txt + modprobe.d ..."
CFG=/boot/firmware/config.txt
add_cfg() { grep -qxF "$1" "$CFG" 2>/dev/null || echo "$1" >> "$CFG"; }
{
	echo ""
	echo "# --- vd56g4 GMSL camera (AD-GMSL716 EVK / MAX96716A) - Channel A ---"
} >> "$CFG"
add_cfg "camera_auto_detect=0"
add_cfg "dtparam=i2c_csi_dsi0=on"
add_cfg "dtparam=i2c_csi_dsi1=on"
add_cfg "dtparam=cam0_reg=off"
add_cfg "dtparam=cam1_reg=off"
add_cfg "dtoverlay=vd56g4-max96716a-rpi5"

# UDC-B0 IR variant: required for the EVK camera head.
echo 'options vb56g4a vb56g4a_opt=udc' > /etc/modprobe.d/vb56g4a.conf
echo "  config.txt + /etc/modprobe.d/vb56g4a.conf written"

#------------------------------------------------------------------------------
# 5. Launcher + channel-select helper (/usr/local/bin)
#------------------------------------------------------------------------------
echo "[5/6] Installing launcher + helper ..."
install -m0755 "$SRC/tools/vd56g4-hdmi-rpi5.sh"    /usr/local/bin/vd56g4-hdmi.sh
install -m0755 "$SRC/tools/vd56g4-chanB-setup.sh"  /usr/local/bin/vd56g4-chanB-setup.sh

cat > /usr/local/bin/vd56g4-select-channel.sh <<'SEL'
#!/bin/bash
# Switch the VD56G4 image between Channel A (camera on FAKRA J1 / csi1) and
# Channel B (camera on J2 / csi0). Reconfigure, then reboot. They cannot run
# at once (single deser; driver link/mode state is module-global).
set -e
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }
CFG=/boot/firmware/config.txt
case "$1" in
  a|A)
    sed -i 's|^#\?dtoverlay=vd56g4-max96716a-rpi5$|dtoverlay=vd56g4-max96716a-rpi5|' "$CFG"
    sed -i 's|^dtoverlay=vd56g4-max96716a-rpi5-cam0$|#dtoverlay=vd56g4-max96716a-rpi5-cam0|' "$CFG"
    echo 'options vb56g4a vb56g4a_opt=udc' > /etc/modprobe.d/vb56g4a.conf
    systemctl disable vd56g4-chanB-setup.service 2>/dev/null || true
    echo "Channel A selected (camera on J1). Reboot to apply." ;;
  b|B)
    sed -i 's|^dtoverlay=vd56g4-max96716a-rpi5$|#dtoverlay=vd56g4-max96716a-rpi5|' "$CFG"
    echo 'options vb56g4a vb56g4a_opt="udc,link=b"' > /etc/modprobe.d/vb56g4a.conf
    systemctl enable vd56g4-chanB-setup.service 2>/dev/null || true
    echo "Channel B selected (camera on J2). Reboot to apply." ;;
  *) echo "usage: $0 a|b"; exit 1 ;;
esac
SEL
chmod 0755 /usr/local/bin/vd56g4-select-channel.sh
# the Channel-B runtime helper drives GPIO46 + applies the cam0 overlay; point it
# at the installed overlay name (already correct) - nothing else to patch.
echo "  /usr/local/bin/{vd56g4-hdmi,vd56g4-chanB-setup,vd56g4-select-channel}.sh"

#------------------------------------------------------------------------------
# 6. systemd: auto-play Channel A on boot; Channel-B setup unit (disabled)
#------------------------------------------------------------------------------
echo "[6/6] Installing + enabling systemd units ..."
cat > /etc/systemd/system/vd56g4-camview.service <<'UNIT'
[Unit]
Description=VD56G4 GMSL live camera -> HDMI (kmssink)
After=multi-user.target
Wants=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/vd56g4-hdmi.sh
Restart=on-failure
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/vd56g4-chanB-setup.service <<'UNIT'
[Unit]
Description=VD56G4 Channel-B (link B / csi0) runtime bring-up
After=multi-user.target
Before=vd56g4-camview.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/vd56g4-chanB-setup.sh

[Install]
WantedBy=multi-user.target
UNIT

# enable auto-play (Channel A); Channel-B setup stays disabled until selected.
# (systemctl enable works in a chroot - it just creates the wants/ symlink.)
systemctl enable vd56g4-camview.service
echo "  vd56g4-camview.service enabled (Channel A auto-play)"

echo "======================================"
echo "  pi5-gmsl-vd56g4 hook complete"
echo "======================================"
