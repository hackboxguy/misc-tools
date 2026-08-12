#!/bin/bash
# Runs inside the target-image chroot during the apps stage.
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

repo=${HOOK_GIT_REPO:?HOOK_GIT_REPO is required}
revision=${HOOK_GIT_TAG:?HOOK_GIT_TAG is required}
destination=${HOOK_INSTALL_DEST:?HOOK_INSTALL_DEST is required}
source_root=/tmp/micropanel-touch-source

case "$destination" in
    /*) ;;
    *) echo "ERROR: install destination must be absolute" >&2; exit 1 ;;
esac

rm -rf "$source_root"
git clone --recursive "$repo" "$source_root"
git -C "$source_root" checkout --detach "$revision"
git -C "$source_root" submodule update --init --recursive

cmake -S "$source_root" -B "$source_root/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$destination" \
    -DINSTALL_SYSTEMD_SERVICE=ON
cmake --build "$source_root/build" -j"$(nproc)"
cmake --install "$source_root/build"

# Install-side account/config fragments intentionally remain below the app
# prefix. Activate the ones systemd and polkit must discover at image boot.
systemd-sysusers "$destination/usr/lib/sysusers.d/micropanel-touch.conf"
install -Dm0644 "$destination/usr/lib/sysctl.d/micropanel-touch-console.conf" \
    /etc/sysctl.d/49-micropanel-touch-console.conf
install -Dm0644 "$destination/share/micropanel-touch/polkit/49-micropanel-touch-network-manager.rules" \
    /etc/polkit-1/rules.d/49-micropanel-touch-network-manager.rules

# This helper owns all PiScreen overlay lines and masks the panel getty. It
# preserves the known-good native portrait mapping and never adds speed=.
"$destination/usr/share/micropanel-touch/tools/enable-piscreen.sh"
cmdline=/boot/firmware/cmdline.txt
if ! grep -Eq '(^|[[:space:]])console=tty1([[:space:]]|$)' "$cmdline"; then
    sed -i '1s/$/ console=tty1/' "$cmdline"
fi
# The panel's known-good boot profile requires tty1, but systemd's progress
# and failure announcements would overwrite the HMI on its shared fb0.
if ! grep -Eq '(^|[[:space:]])systemd\.show_status=false([[:space:]]|$)' "$cmdline"; then
    sed -i '1s/$/ systemd.show_status=false/' "$cmdline"
fi

systemctl enable "$destination/lib/systemd/system/micropanel-touch-privileged.service"
systemctl enable "$destination/lib/systemd/system/micropanel-touch.service"

# The supported Pi OS Lite base keeps cloud-init to create unique SSH host
# keys on first boot. Its `keys_to_console` module bypasses systemd and writes
# those public keys directly to /dev/console, which shares fb0 with PiScreen.
# Suppress only that disclosure: keys are still generated and SSH still works.
install -d /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/90-micropanel-touch-console.cfg <<'EOF'
#cloud-config
ssh:
  emit_keys_to_console: false
EOF

# Cloud-init's stage shims normally use journal+console. Keep their regular
# output in the journal as well, while retaining early appliance UI startup.
for cloud_unit in cloud-init-main.service cloud-init-local.service cloud-init-network.service \
                  cloud-config.service cloud-final.service; do
    install -d "/etc/systemd/system/${cloud_unit}.d"
    cat > "/etc/systemd/system/${cloud_unit}.d/50-micropanel-touch-console.conf" <<'EOF'
[Service]
StandardOutput=journal
StandardError=journal
EOF
done

# NetworkManager, not systemd-networkd, owns this appliance's networking.
# The enabled networkd wait job has no interfaces to observe and otherwise
# adds a two-minute timeout to cloud-init's final stage.
systemctl mask systemd-networkd-wait-online.service

# An overlay-backed root is intentionally neither remountable nor a block
# device that can be grown. Treat these generic root-maintenance jobs as not
# applicable so their expected failures do not cascade into boot warnings.
for root_unit in systemd-remount-fs.service systemd-growfs-root.service; do
    install -d "/etc/systemd/system/${root_unit}.d"
    cat > "/etc/systemd/system/${root_unit}.d/50-micropanel-touch-overlay-root.conf" <<'EOF'
[Unit]
ConditionKernelCommandLine=!overlayroot=tmpfs
EOF
done

# Bake the supported Pi OS overlayfs configuration after all build-time writes
# are complete. The post-image hook supplies /data as the persistent volume.
# On Trixie, do_overlayfs also owns the boot-partition write-protection policy;
# the former do_boot_ro noninteractive action no longer exists.
raspi-config nonint do_overlayfs 0
grep -Eq '(^|[[:space:]])overlayroot=tmpfs([[:space:]]|$)' /boot/firmware/cmdline.txt || {
    echo "ERROR: raspi-config did not enable overlayroot in cmdline.txt" >&2
    exit 1
}

mkdir -p "$destination/share/micropanel-touch"
cat > "$destination/share/micropanel-touch/image-manifest.env" <<EOF
MICROPANEL_TOUCH_REVISION=$revision
LVGL_REVISION=$(git -C "$source_root/external/lvgl" rev-parse HEAD)
EOF

rm -rf "$source_root"
