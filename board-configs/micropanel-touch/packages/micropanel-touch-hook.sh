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

systemctl enable "$destination/lib/systemd/system/micropanel-touch-privileged.service"
systemctl enable "$destination/lib/systemd/system/micropanel-touch.service"

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
