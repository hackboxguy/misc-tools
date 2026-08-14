#!/bin/sh
set -eu

hook=$1
app_source=$2
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

app_root=$temporary_directory/opt/micropanel-touch
firmware=$temporary_directory/lib/firmware/st7796s.bin
modules_load=$temporary_directory/etc/modules-load.d/micropanel-touch-luckfox-ctp.conf
systemd_root=$temporary_directory/etc/systemd/system
config=$temporary_directory/config.txt
cmdline=$temporary_directory/cmdline.txt
manifest=$app_root/share/micropanel-touch/image-manifest.env

install -D -m0644 "$app_source/assets/panels/luckfox-ctp/st7796s.bin" \
    "$app_root/share/micropanel-touch/panels/luckfox-ctp/st7796s.bin"
install -D -m0755 "$app_source/tools/enable-luckfox-ctp.sh" \
    "$app_root/usr/share/micropanel-touch/tools/enable-luckfox-ctp.sh"
printf '%s\n' 'MICROPANEL_TOUCH_REVISION=test' > "$manifest"
printf '%s\n' '[all]' 'dtoverlay=piscreen,drm=1,rotate=90,xohms=100,swapxy=1' > "$config"
printf '%s\n' 'console=tty1 root=LABEL=writable rootwait' > "$cmdline"

run_hook() {
    MICROPANEL_TOUCH_APP_ROOT="$app_root" \
    MICROPANEL_TOUCH_FIRMWARE_DESTINATION="$firmware" \
    MICROPANEL_TOUCH_MODULES_LOAD_PATH="$modules_load" \
    MICROPANEL_TOUCH_SYSTEMD_ROOT="$systemd_root" \
    MICROPANEL_TOUCH_ALLOW_UNPRIVILEGED_TEST=1 \
    MICROPANEL_TOUCH_CONFIG_PATH="$config" \
    MICROPANEL_TOUCH_CMDLINE_PATH="$cmdline" \
    MICROPANEL_TOUCH_SYSTEMCTL_COMMAND=/bin/true \
    /bin/bash "$hook"
}

run_hook
sha256sum "$firmware" | grep -q '^17204e39cce35fba857ad2dff14243e1d3a958c4dac00283f8df9b7ad5147cc7 '
grep -Fqx 'panel_mipi_dbi' "$modules_load"
grep -Fqx 'ConditionPathExists=/sys/class/backlight/backlight_gpio/brightness' \
    "$systemd_root/micropanel-touch-backlight-permissions.service"
grep -Fqx 'ExecStart=/usr/bin/chown root:micropanel-touch /sys/class/backlight/backlight_gpio/brightness' \
    "$systemd_root/micropanel-touch-backlight-permissions.service"
grep -Fqx 'ExecStart=/usr/bin/chmod 0660 /sys/class/backlight/backlight_gpio/brightness' \
    "$systemd_root/micropanel-touch-backlight-permissions.service"
grep -Fqx 'Wants=micropanel-touch-backlight-permissions.service' \
    "$systemd_root/micropanel-touch.service.d/20-luckfox-backlight.conf"
! grep -q '^[[:space:]]*dtoverlay=piscreen\(,\|$\)' "$config"
grep -Fqx 'dtoverlay=mipi-dbi-spi,spi0-0,speed=48000000' "$config"
grep -Fqx 'dtoverlay=goodix,addr=0x5d,interrupt=4,reset=17' "$config"
grep -Fqx 'PANEL_PROFILE=luckfox-ctp-st7796s-gt911-portrait' "$manifest"
grep -Fqx 'PANEL_VARIANT=luckfox-ctp' "$manifest"
grep -Fqx 'PANEL_FIRMWARE=st7796s.bin' "$manifest"
grep -Fqx 'PANEL_FIRMWARE_SHA256=17204e39cce35fba857ad2dff14243e1d3a958c4dac00283f8df9b7ad5147cc7' \
    "$manifest"
cp "$config" "$temporary_directory/first-config.txt"
cp "$manifest" "$temporary_directory/first-manifest.txt"
cp "$modules_load" "$temporary_directory/first-modules-load.txt"
cp "$systemd_root/micropanel-touch-backlight-permissions.service" \
    "$temporary_directory/first-backlight-service.txt"
cp "$systemd_root/micropanel-touch.service.d/20-luckfox-backlight.conf" \
    "$temporary_directory/first-backlight-dropin.txt"

run_hook
cmp "$temporary_directory/first-config.txt" "$config"
cmp "$temporary_directory/first-manifest.txt" "$manifest"
cmp "$temporary_directory/first-modules-load.txt" "$modules_load"
cmp "$temporary_directory/first-backlight-service.txt" \
    "$systemd_root/micropanel-touch-backlight-permissions.service"
cmp "$temporary_directory/first-backlight-dropin.txt" \
    "$systemd_root/micropanel-touch.service.d/20-luckfox-backlight.conf"
