#!/bin/bash
# Runs after micropanel-touch-hook.sh inside the target-image chroot.
# Select the verified Luckfox 3.5-RPi-LCD-CTP boot profile without changing the
# default PiScreen board configuration or requiring an out-of-tree module.
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

app_root=${MICROPANEL_TOUCH_APP_ROOT:-/opt/micropanel-touch}
firmware_source="$app_root/share/micropanel-touch/panels/luckfox-ctp/st7796s.bin"
firmware_destination=${MICROPANEL_TOUCH_FIRMWARE_DESTINATION:-/lib/firmware/st7796s.bin}
firmware_sha256=17204e39cce35fba857ad2dff14243e1d3a958c4dac00283f8df9b7ad5147cc7
profile_tool="$app_root/usr/share/micropanel-touch/tools/enable-luckfox-ctp.sh"
manifest="$app_root/share/micropanel-touch/image-manifest.env"
systemd_root=${MICROPANEL_TOUCH_SYSTEMD_ROOT:-/etc/systemd/system}
backlight_path=/sys/class/backlight/backlight_pwm/brightness

for required in "$firmware_source" "$profile_tool" "$manifest"; do
    [ -f "$required" ] || { echo "ERROR: required Luckfox artifact missing: $required" >&2; exit 1; }
done

actual_sha256=$(sha256sum "$firmware_source" | awk '{print $1}')
[ "$actual_sha256" = "$firmware_sha256" ] || {
    echo "ERROR: Luckfox ST7796S firmware digest mismatch" >&2
    exit 1
}

install -D -m0644 "$firmware_source" "$firmware_destination"
installed_sha256=$(sha256sum "$firmware_destination" | awk '{print $1}')
[ "$installed_sha256" = "$firmware_sha256" ] || {
    echo "ERROR: installed Luckfox ST7796S firmware digest mismatch" >&2
    exit 1
}

"$profile_tool"

# The HMI intentionally has no general root helper for display power. The
# profile's kernel-owned PWM-backlight attribute is the sole grant, and this
# unit exists only on the opt-in Luckfox image. systemd-modules-load creates
# the attribute before this ordered one-shot service runs.
install -d "$systemd_root/micropanel-touch.service.d"
cat > "$systemd_root/micropanel-touch-backlight-permissions.service" <<EOF
[Unit]
Description=Grant MicroPanel Touch access to the Luckfox backlight
ConditionPathExists=$backlight_path
After=systemd-modules-load.service
Before=micropanel-touch.service

[Service]
Type=oneshot
ExecStart=/usr/bin/chown root:micropanel-touch $backlight_path
ExecStart=/usr/bin/chmod 0660 $backlight_path
EOF
cat > "$systemd_root/micropanel-touch.service.d/20-luckfox-backlight.conf" <<'EOF'
[Unit]
Wants=micropanel-touch-backlight-permissions.service
After=micropanel-touch-backlight-permissions.service
EOF

# A normal image build executes this hook once, but make a re-run safe for
# incremental-builder recovery and for deterministic chroot tests.
sed -i \
    -e '/^PANEL_PROFILE=/d' \
    -e '/^PANEL_VARIANT=/d' \
    -e '/^PANEL_FIRMWARE=/d' \
    -e '/^PANEL_FIRMWARE_SHA256=/d' \
    "$manifest"
cat >> "$manifest" <<'EOF'
PANEL_PROFILE=luckfox-ctp-st7796s-gt911-portrait
PANEL_VARIANT=luckfox-ctp
PANEL_FIRMWARE=st7796s.bin
PANEL_FIRMWARE_SHA256=17204e39cce35fba857ad2dff14243e1d3a958c4dac00283f8df9b7ad5147cc7
EOF

echo "Configured Luckfox 3.5-RPi-LCD-CTP (ST7796S/GT911) image variant."
