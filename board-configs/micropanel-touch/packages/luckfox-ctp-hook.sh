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
udev_rules_root=${MICROPANEL_TOUCH_UDEV_RULES_ROOT:-/etc/udev/rules.d}
modprobe_root=${MICROPANEL_TOUCH_MODPROBE_ROOT:-/etc/modprobe.d}

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

# The HMI intentionally has no general root helper for display power. Apply
# the least-privilege grant when udev creates the PWM-backlight node; unlike a
# one-shot unit this has no panel-probe timing race. Backlights have no devnode
# (their writable brightness file is sysfs), so fixed RUN commands target only
# that attribute rather than relying on a devnode MODE rule. This is installed
# only by the opt-in Luckfox image hook.
install -d "$udev_rules_root"
cat > "$udev_rules_root/70-micropanel-touch-luckfox-backlight.rules" <<'EOF'
ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="backlight_pwm", RUN+="/usr/bin/chown root:micropanel-touch /sys/class/backlight/%k/brightness", RUN+="/usr/bin/chmod 0660 /sys/class/backlight/%k/brightness"
EOF

# The managed PWM backlight uses a resource that the legacy BCM analogue-audio
# driver can also claim. The profile already disables the DT audio route; keep
# the module from being loaded later by an alias or manual request as well.
install -d "$modprobe_root"
cat > "$modprobe_root/90-micropanel-touch-luckfox-audio.conf" <<'EOF'
# Luckfox CTP backlight PWM is reserved for the appliance display.
blacklist snd_bcm2835
EOF

# A builder can resume after a previous hook revision. Remove only the two
# obsolete generated files so an incremental image cannot retain the old,
# timing-sensitive one-shot permission path.
rm -f "$systemd_root/micropanel-touch-backlight-permissions.service" \
    "$systemd_root/micropanel-touch.service.d/20-luckfox-backlight.conf"

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
