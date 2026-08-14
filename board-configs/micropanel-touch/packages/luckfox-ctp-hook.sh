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
