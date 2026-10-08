#!/bin/bash
# micropanel appliance conversion - A/B images only (last line of hooks-ab.txt).
#
# Runs inside the target-image chroot after every application hook and turns
# the authored micropanel image into what the pi-ab-update engine requires: a
# read-only overlayroot root (with an initramfs for this board's custom
# kernel, which boots without one otherwise), durable state bound in from
# /data, a device identity that survives updates, no services that write
# below an overlay root, and a complete image manifest. The single-slot image
# never runs this hook.
#
# Support files (restore tools, units, fstab binds) are in
# micropanel-appliance-hook.d/, which the imager copies in as HOOK_SUPPORT_DIR.
# PERSISTENCE.md is the prose version of what this hook binds and why.
#
# Every step says what it did; every failed check stops the build with a
# one-line reason, because the alternative is finding out on the bench.
set -euo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

say() { echo "[appliance] $*"; }
die() { echo "[appliance] ERROR: $*" >&2; exit 1; }

support=${HOOK_SUPPORT_DIR:-}
[ -n "$support" ] && [ -d "$support" ] || die "HOOK_SUPPORT_DIR is not set; the imager must copy micropanel-appliance-hook.d"
manifest=${AB_MANIFEST_PATH:-}
[ -n "$manifest" ] || die "AB_MANIFEST_PATH is not set; this hook runs only in --layout=ab builds"

boot=/boot/firmware
cmdline=$boot/cmdline.txt
config=$boot/config.txt
[ -f "$cmdline" ] && [ -f "$config" ] || die "boot partition is not mounted at $boot"

unit_enabled() { # $1=unit; true when any *.wants link names it
    ls /etc/systemd/system/*.wants/"$1" >/dev/null 2>&1
}

# --- 1. Identity and host keys ------------------------------------------------
# Never ship the build chroot's identity into every flashed device, and never
# regenerate host keys on every boot: both live on /data and are restored early.
install -Dm0755 "$support/micropanel-restore-machine-id" /usr/local/sbin/micropanel-restore-machine-id
install -Dm0755 "$support/micropanel-restore-ssh-host-keys" /usr/local/sbin/micropanel-restore-ssh-host-keys
install -Dm0644 "$support/micropanel-machine-id.service" /etc/systemd/system/micropanel-machine-id.service
install -Dm0644 "$support/micropanel-ssh-host-keys.service" /etc/systemd/system/micropanel-ssh-host-keys.service
systemctl enable micropanel-machine-id.service micropanel-ssh-host-keys.service
: > /etc/machine-id
chmod 0444 /etc/machine-id
install -d /var/lib/dbus
rm -f /var/lib/dbus/machine-id
: > /var/lib/dbus/machine-id
chmod 0444 /var/lib/dbus/machine-id
systemctl disable regenerate_ssh_host_keys.service 2>/dev/null || true
systemctl mask regenerate_ssh_host_keys.service sshd-keygen.service
# Bench forensics for spontaneous reboots: enabled, but inert unless the
# cmdline carries micropanel.debug-journal=1 or /data/micropanel-system/debug/enabled
# exists (see the script's header).
install -Dm0755 "$support/micropanel-debug-journal" /usr/local/sbin/micropanel-debug-journal
install -Dm0644 "$support/micropanel-debug-journal.service" /etc/systemd/system/micropanel-debug-journal.service
systemctl enable micropanel-debug-journal.service

# The data skeleton at every boot (PERSISTENCE.md): a device updated in place
# gets the /data paths a newer image adds; the binds in fstab.binds wait for it
install -Dm0644 "$support/micropanel-data-skeleton.service" /etc/systemd/system/micropanel-data-skeleton.service
systemctl enable micropanel-data-skeleton.service
say "identity: machine-id emptied; micropanel-machine-id and micropanel-ssh-host-keys enabled; regenerate_ssh_host_keys and sshd-keygen masked"

# --- 2. Services that must not run on an overlay root ----------------------------
# Swap on an overlay root is a swap file in RAM.
systemctl disable dphys-swapfile.service 2>/dev/null || true
rm -f /var/swap
say "services: dphys-swapfile disabled, /var/swap removed"
# EEPROM updates are outside the A/B chain (the package goes with the slim step).
systemctl disable rpi-eeprom-update.service 2>/dev/null || true
say "services: rpi-eeprom-update disabled"
# sdm's first-boot pass can only disable itself in RAM here, so it would run on
# every boot. Keep a guard against it being re-enabled.
systemctl disable sdm-firstboot.service 2>/dev/null || true
install -d /etc/systemd/system/sdm-firstboot.service.d
cat > /etc/systemd/system/sdm-firstboot.service.d/50-micropanel-disable.conf <<'EOF'
[Unit]
# Opt in only when debugging an image-builder first-boot pass.
ConditionKernelCommandLine=micropanel.sdm-firstboot=1
EOF
say "services: sdm-firstboot disabled and guarded"
# NetworkManager owns networking; networkd's wait job has nothing to wait for.
systemctl mask systemd-networkd-wait-online.service
say "services: systemd-networkd-wait-online masked"
# An overlay root is neither remountable nor growable.
for root_unit in systemd-remount-fs.service systemd-growfs-root.service; do
    install -d "/etc/systemd/system/${root_unit}.d"
    cat > "/etc/systemd/system/${root_unit}.d/50-micropanel-overlay-root.conf" <<'EOF'
[Unit]
ConditionKernelCommandLine=!overlayroot=tmpfs
ConditionKernelCommandLine=!overlayroot=tmpfs:recurse=0
EOF
done
say "services: remount-fs and growfs-root skipped on an overlay root"
# Pi OS's one-shot resize2fs_once (a SysV script the base's first-boot root
# expansion leaves behind) would run - and fail - on every boot of an overlay
# root, where it can never remove itself.
if [ -e /etc/init.d/resize2fs_once ]; then
    update-rc.d -f resize2fs_once remove >/dev/null 2>&1 || true
    rm -f /etc/init.d/resize2fs_once
fi
find /etc/rc?.d /etc/systemd/system -name '*resize2fs_once*' -exec rm -f {} + 2>/dev/null || true
[ ! -e /etc/init.d/resize2fs_once ] && [ -z "$(find /etc/rc?.d -name '*resize2fs_once*' 2>/dev/null)" ] || \
    die "resize2fs_once is still installed"
say "services: resize2fs_once removed"
# First-boot helpers that write to the console. Measured on 01.33: no
# cloud-init; userconfig.service present but not enabled.
if [ -d /etc/cloud ] || command -v cloud-init >/dev/null 2>&1; then
    install -d /etc/cloud/cloud.cfg.d
    cat > /etc/cloud/cloud.cfg.d/90-micropanel-console.cfg <<'EOF'
#cloud-config
ssh:
  emit_keys_to_console: false
ssh_deletekeys: false
ssh_genkeytypes: []
EOF
    say "services: cloud-init present - key console output and key regeneration disabled"
else
    say "services: cloud-init not present"
fi
if unit_enabled userconfig.service; then
    systemctl disable userconfig.service
    say "services: userconfig.service was enabled - disabled"
else
    say "services: userconfig.service not enabled"
fi

# --- 3. Persistence bindings ------------------------------------------------------
# Mount points in the lower root; the fstab lines bind /data over them.
install -d -m0755 /var/lib/micropanel /var/lib/disp-settings
install -d -m0755 -o 1000 -g 1000 /home/pi/.kodi
install -d -m0755 -o 1000 -g 1000 /home/pi/micropanel/share/disptool/display-test-framework/results
install -d -m0755 -o 1000 -g 1000 /home/pi/test-reports
install -d -m0755 -o 1000 -g 1000 /home/pi/system-settings
install -d -m0755 /home/pi/als-dimmer/etc/als-dimmer/calibrations
bind_lines=$(grep -Ev '^[[:space:]]*(#|$)' "$support/fstab.binds")
while IFS= read -r line; do
    target=$(printf '%s\n' "$line" | awk '{print $2}')
    [ -d "$target" ] || die "bind target missing in the lower root: $target"
    # Idempotent: drop any earlier line for the same mount point.
    awk -v target="$target" '$2 != target' /etc/fstab > /etc/fstab.appliance
    mv /etc/fstab.appliance /etc/fstab
done <<< "$bind_lines"
{
    printf '\n'
    cat "$support/fstab.binds"
} >> /etc/fstab
say "persistence: $(printf '%s\n' "$bind_lines" | wc -l) bind mounts appended to /etc/fstab"

# settings.json: micropanel saves it by writing settings.json.tmp beside it and
# renaming over it. A symlink at the old path would be replaced by that rename
# with a regular file in the tmpfs upper layer (settings lost at reboot), and a
# file bind mount refuses the rename (EBUSY). So the daemon's configured path
# moves to /data itself; the old path stays a symlink for anything that reads it.
mp_config=/home/pi/micropanel/etc/micropanel/config.json
old_settings=/home/pi/micropanel/settings.json
new_settings=/data/micropanel/settings.json
[ -f "$mp_config" ] || die "micropanel config missing: $mp_config"
[ "$(grep -Fc "\"file_path\": \"$old_settings\"" "$mp_config")" -eq 1 ] || \
    [ "$(grep -Fc "\"file_path\": \"$new_settings\"" "$mp_config")" -eq 1 ] || \
    die "micropanel config does not name $old_settings exactly once as persistent_data.file_path"
sed -i "s#\"file_path\": \"$old_settings\"#\"file_path\": \"$new_settings\"#" "$mp_config"
grep -Fq "\"file_path\": \"$new_settings\"" "$mp_config" || die "unable to redirect persistent_data.file_path"
if [ -f "$old_settings" ] && [ ! -L "$old_settings" ]; then
    # Keep an authored settings file as the seed the data skeleton copies.
    install -d /home/pi/micropanel/share/micropanel
    mv "$old_settings" /home/pi/micropanel/share/micropanel/settings.json.default
    say "persistence: authored settings.json kept as share/micropanel/settings.json.default"
fi
ln -sfn "$new_settings" "$old_settings"
chown -h 1000:1000 "$old_settings"
say "persistence: persistent_data.file_path -> $new_settings; $old_settings -> symlink"

# als-dimmer: its state file (AUTO/MANUAL mode, manual brightness, offset) is
# named by control.state_file in each config, and the shipped configs say /tmp or
# /home/pi - both volatile here, so every power cycle fell back to AUTO. Point
# every installed config into /data/als-dimmer (keeping each file name, so the
# secondary PWM instance keeps its own file). Which config runs is decided at
# boot by the display type, so all of them are rewritten, not just the default.
als_etc=/home/pi/als-dimmer/etc/als-dimmer
if [ -d "$als_etc" ]; then
    als_count=0
    for cfg in "$als_etc"/*.json; do
        [ -f "$cfg" ] && [ ! -L "$cfg" ] || continue
        grep -q '"state_file"' "$cfg" || continue
        sed -i -E 's#("state_file"[[:space:]]*:[[:space:]]*")[^"]*/([^/"]+)"#\1/data/als-dimmer/\2"#' "$cfg"
        grep -Eq '"state_file"[[:space:]]*:[[:space:]]*"/data/als-dimmer/[^/"]+"' "$cfg" || \
            die "unable to redirect state_file in $cfg"
        als_count=$((als_count + 1))
    done
    say "persistence: als-dimmer state_file -> /data/als-dimmer/ in $als_count configs"
else
    say "persistence: no als-dimmer installed ($als_etc missing), nothing to redirect"
fi

# --- 4. Overlayroot and an initramfs for the custom kernel ----------------------
# Incremental builds install runtime deps only after the hooks, so install here.
if ! dpkg -s overlayroot >/dev/null 2>&1; then
    apt-get install -y overlayroot || { apt-get update -qq && apt-get install -y overlayroot; }
fi
dpkg -s overlayroot >/dev/null 2>&1 || die "overlayroot is not installed"
raspi-config nonint do_overlayfs 0
overlayroot_token='overlayroot=tmpfs:recurse=0'
if grep -Eq "(^|[[:space:]])${overlayroot_token}([[:space:]]|$)" "$cmdline"; then
    :
elif grep -Eq '(^|[[:space:]])overlayroot=tmpfs([[:space:]]|$)' "$cmdline"; then
    # recurse=0: overlay the root only, never the /data mount below it.
    sed -i -E 's/(^|[[:space:]])overlayroot=tmpfs([[:space:]]|$)/\1overlayroot=tmpfs:recurse=0\2/' "$cmdline"
else
    die "raspi-config did not enable overlayroot in cmdline.txt"
fi
# The base was built with root expansion; its first-boot resize must never run
# in a slot. (The A/B finalizer strips it too; this keeps the authored image
# honest and lets the assertion below hold.)
sed -i -E \
    -e 's#(^|[[:space:]])init=/usr/lib/(raspberrypi-sys-mods/firstboot|raspi-config/init_resize\.sh)([[:space:]]|$)#\1#g' \
    -e 's/[[:space:]]+$//' "$cmdline"
say "overlayroot: installed and enabled; cmdline: $(cat "$cmdline")"

# The kernel's own release string, not a directory listing: the kernel builder
# also leaves a '<release>+' symlink, which a '-v8+$' pattern matches too.
release=$(grep -a -o -m1 'Linux version [^ ]*' "$boot/Image" | awk '{print $3}')
[ -n "$release" ] || die "cannot read the kernel release from $boot/Image"
[ -d "/lib/modules/$release" ] && [ ! -L "/lib/modules/$release" ] || \
    die "no module directory for the custom kernel release $release"
ls "/lib/modules/$release/extra/"hh983-serializer.ko* >/dev/null 2>&1 || \
    die "/lib/modules/$release has no hh983-serializer module; is it the custom kernel?"
custom_dirs=$(find /lib/modules -mindepth 1 -maxdepth 1 -type d -name '*-v8+' -printf '%f\n')
[ "$custom_dirs" = "$release" ] || die "expected exactly one custom module directory ($release), found: $custom_dirs"
# MODULES=list: ext4, MMC and devtmpfs are built into this kernel; the one
# module the early boot needs is overlay (CONFIG_OVERLAY_FS=m), listed
# explicitly rather than trusting another package's hook to add it. The
# default MODULES=dep inspects the running system, which inside a build chroot
# is the build host.
install -d /etc/initramfs-tools/conf.d
printf '%s\n' '# micropanel A/B: see micropanel-appliance-hook.sh' 'MODULES=list' \
    > /etc/initramfs-tools/conf.d/micropanel-appliance.conf
grep -Eqx 'overlay' /etc/initramfs-tools/modules 2>/dev/null || echo overlay >> /etc/initramfs-tools/modules
# mkinitramfs decides which compressors the kernel can unpack from
# /boot/config-<release>, and refuses every one when the file is missing. The
# custom kernel install does not provide it, but the kernel carries its own
# build config (CONFIG_IKCONFIG=m, in configs.ko): extract that, the real one.
kernel_config="/boot/config-$release"
if [ ! -s "$kernel_config" ]; then
    configs_ko=$(find "/lib/modules/$release/kernel/kernel" -name 'configs.ko*' | head -n 1)
    [ -n "$configs_ko" ] || die "no $kernel_config and no configs.ko to extract it from"
    configs_raw=$(mktemp)
    case "$configs_ko" in
        *.xz) xz -dc "$configs_ko" > "$configs_raw" ;;
        *.zst) zstd -qdc "$configs_ko" > "$configs_raw" ;;
        *) cp "$configs_ko" "$configs_raw" ;;
    esac
    marker=$(grep -abo IKCFG_ST "$configs_raw" | head -n 1 | cut -d: -f1)
    [ -n "$marker" ] || die "configs.ko carries no IKCFG_ST config blob"
    # gunzip reports the module's trailing bytes as garbage; the content check
    # below is what decides whether the extraction worked.
    tail -c +"$((marker + 9))" "$configs_raw" | gunzip -c > "$kernel_config" 2>/dev/null || true
    rm -f "$configs_raw"
    grep -q "^CONFIG_LOCALVERSION=" "$kernel_config" || die "unable to extract the kernel config from $configs_ko"
    say "initramfs: extracted the kernel's own config to $kernel_config"
fi
grep -q '^CONFIG_BLK_DEV_INITRD=y' "$kernel_config" || die "the custom kernel has no initramfs support"
rm -f "/boot/initrd.img-$release"
update-initramfs -c -k "$release"
initrd="/boot/initrd.img-$release"
[ -s "$initrd" ] || die "update-initramfs produced no $initrd"
initrd_contents=$(lsinitramfs "$initrd")
grep -Eq '/overlay\.ko(\.xz|\.zst)?$' <<< "$initrd_contents" || \
    die "the initramfs has no overlay module; overlayroot would be silently ignored"
grep -Eq 'scripts/init-bottom/overlayroot$' <<< "$initrd_contents" || \
    die "the initramfs has no overlayroot init-bottom script"
# A version-free name, so neither the selector template nor a slot's boot tree
# carries a kernel version; os_prefix makes the firmware load A/ or B/'s copy.
cp "$initrd" "$boot/initramfs-custom"
rm -f "$initrd"
say "initramfs: built for $release ($(du -k "$boot/initramfs-custom" | cut -f1) KiB) -> $boot/initramfs-custom"

# --- 5. The config.txt include split --------------------------------------------
# config.txt becomes the slot selector's template: release-owned, and rewritten
# by the selector on every arm and commit. The display configuration (timings,
# touch overlay, type marker) moves to micropanel-display.txt at the root of the
# boot partition - device-owned, shared by both slots, surviving updates - which
# config.txt includes. /etc/default/micropanel is what tells pi-config-txt.sh (and
# so every caller that passes --input=/boot/firmware/config.txt) to use it.
pi_config=/home/pi/micropanel/usr/bin/pi-config-txt.sh
pi_configs=/home/pi/micropanel/usr/share/micropanel/configs/
display_file=$boot/micropanel-display.txt
[ -x "$pi_config" ] || die "$pi_config is missing"
grep -q -- '--emit-base' "$pi_config" || \
    die "$pi_config predates the split boot configuration: push the micropanel commit that adds --emit-base, then rebuild"
# The type the authored config.txt encodes, asked before the switch exists.
display_type=$(MICROPANEL_DEFAULTS=/nonexistent "$pi_config" --configspath="$pi_configs" \
    --input="$config" --query-config 2>/dev/null || true)
if [ -z "$display_type" ] || [ "$display_type" = unknown ]; then
    # micropanel's shipped configs/config.txt is a hand-kept copy of the edid
    # rendering that has drifted from the template (the GPIO22 line), so it
    # queries as unknown. edid is what it is; the DIP-switch service moves the
    # device to its switch setting on first boot either way.
    display_type=edid
    say "config.txt: the authored config.txt matches no display type exactly; splitting as edid"
fi
printf '%s\n' '# micropanel A/B image: the display configuration lives in its own file on the' \
    '# boot partition, included by the slot-selected config.txt (pi-config-txt.sh).' \
    "MICROPANEL_BOOT_CONFIG=$display_file" > /etc/default/micropanel
chmod 0644 /etc/default/micropanel
MICROPANEL_NO_REBOOT=1 "$pi_config" --configspath="$pi_configs" --input=/boot/firmware/config.txt \
    --type="$display_type" --no-reboot
"$pi_config" --configspath="$pi_configs" --emit-base="$config"
grep -q "^# micropanel-display-type: $display_type\$" "$display_file" || die "micropanel-display.txt lacks its type marker"
if grep -q '^hdmi_timings=' "$config"; then die "config.txt still carries hdmi_timings after the split"; fi
if grep -q '^dtoverlay=himax-touch' "$config"; then die "config.txt still carries the touch overlay after the split"; fi
[ "$(grep -c '^include ' "$config")" -eq 1 ] && grep -qx 'include micropanel-display.txt' "$config" || \
    die "config.txt must include micropanel-display.txt exactly once"
if grep -Eq '^[[:space:]]*os_prefix=' "$config"; then die "config.txt selects an os_prefix"; fi
rm -f "$display_file.bak"
say "config.txt: split for display type $display_type; micropanel-display.txt is device-owned"

# The module configuration the type implies is regenerated every boot by the
# derive unit, which also loads the drivers; no static list loads them first.
install -Dm0644 "$support/micropanel-display-derive.service" /etc/systemd/system/micropanel-display-derive.service
systemctl enable micropanel-display-derive.service
rm -f /etc/modules-load.d/custom-drivers.conf
# ...and nothing autoloads them by alias before it has run: a serializer loaded
# early with the default options would have to be reloaded, and after a reload
# the DP source does not retrain (the 02.00 bench: a black panel). An explicit
# modprobe - the derive unit's, the DIP-switch service's - ignores the blacklist.
install -Dm0644 "$support/micropanel-no-autoload.conf" /etc/modprobe.d/micropanel-no-autoload.conf

# udisks2 leaves the boot medium's own partitions alone (Kodi mounted the
# inactive slot and the factory partition read-write under /media/pi)
install -Dm0644 "$support/90-micropanel-udisks-ignore.rules" /etc/udev/rules.d/90-micropanel-udisks-ignore.rules
say "display: micropanel-display-derive enabled; static custom-drivers.conf removed; driver autoload blacklisted"
modprobe_config=$(modprobe -c -S "$release" 2>/dev/null || true)
for module in hh983_serializer himax_mmi himax_oled; do
    grep -Fqx "blacklist $module" <<< "$modprobe_config" || \
        die "modprobe does not see the autoload blacklist for $module"
done

# Load the initramfs with the custom kernel. It belongs to this image layout,
# not to micropanel's template, which single-slot images and buildroot share.
grep -Eq '^[[:space:]]*kernel=Image[[:space:]]*$' "$config" || die "config.txt does not select kernel=Image"
sed -i -E '/^[[:space:]]*initramfs[[:space:]]/d' "$config"
sed -i -E '0,/^[[:space:]]*kernel=Image[[:space:]]*$/s//&\ninitramfs initramfs-custom followkernel/' "$config"
[ "$(grep -Ec '^[[:space:]]*initramfs[[:space:]]' "$config")" -eq 1 ] || die "config.txt must have exactly one initramfs line"
grep -Fqx 'initramfs initramfs-custom followkernel' "$config" || die "config.txt initramfs line is wrong"
grep -Eq '^[[:space:]]*kernel=Image[[:space:]]*$' "$config" || die "config.txt lost kernel=Image"
say "config.txt: 'initramfs initramfs-custom followkernel' added after kernel=Image"

grep -Eq "(^|[[:space:]])${overlayroot_token}([[:space:]]|$)" "$cmdline" || die "cmdline.txt lacks $overlayroot_token"
if grep -Eq '(^|[[:space:]])init=' "$cmdline"; then die "cmdline.txt still carries an init= token"; fi

# --- 6. Image manifest ------------------------------------------------------------
# micropanel-hook.sh recorded the revision it built (it deletes its clone).
[ -f "$manifest" ] || die "image manifest missing: $manifest (micropanel-hook.sh records it)"
revision=$(awk -F= '$1 == "MICROPANEL_REVISION" { print $2; exit }' "$manifest")
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die "manifest has no valid MICROPANEL_REVISION"
grep -vE '^(AB_APP_REVISION|IMAGE_VARIANT)=' "$manifest" > "$manifest.appliance" || true
printf 'AB_APP_REVISION=%s\nIMAGE_VARIANT=base\n' "$revision" >> "$manifest.appliance"
mv "$manifest.appliance" "$manifest"
chmod 0644 "$manifest"
say "manifest: $(tr '\n' ' ' < "$manifest")"

# --- 7. What the update engine runs on the device -------------------------------
for tool in xz curl openssl lsblk e2label e2fsck mkfs.vfat; do
    command -v "$tool" >/dev/null 2>&1 || die "runtime tool missing: $tool"
done
say "runtime tools present: xz curl openssl lsblk e2label e2fsck mkfs.vfat"
