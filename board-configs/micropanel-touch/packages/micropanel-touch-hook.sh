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
if ! git -C "$source_root" checkout --detach "$revision"; then
    # A shallow or branch-limited remote may omit an older pinned commit from
    # the initial clone. Fetch that exact object once before treating the pin
    # as unavailable.
    git -C "$source_root" fetch origin "$revision"
    git -C "$source_root" checkout --detach "$revision"
fi
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
# dnsmasq is retained only for the broker-controlled, eth0-bound appliance
# unit.  The distro-wide service must never become an independent DHCP
# authority through package defaults or a future preset.
systemctl mask dnsmasq.service
systemctl enable "$destination/lib/systemd/system/micropanel-touch-dhcp-server.service"

# Never carry the build chroot's identity into every flashed appliance. On a
# first boot systemd supplies a random transient ID; this unit records it in
# /data, then restores it before D-Bus starts on later boots. PID 1 necessarily
# starts before /data, but no network-visible service receives the shared,
# lower-image identity. Journald starts still earlier, so once the durable ID
# is in place restart it before the journal-flush phase: otherwise it retains
# a directory named after the transient identity and journalctl cannot find
# the current boot under the restored ID.
install -d /usr/local/sbin /etc/systemd/system
install -Dm0755 "$destination/usr/share/micropanel-touch/tools/micropanel-touch-restore-machine-id" \
    /usr/local/sbin/micropanel-touch-restore-machine-id
cat > /etc/systemd/system/micropanel-touch-machine-id.service <<'EOF'
[Unit]
Description=Restore persistent MicroPanel Touch machine identity
DefaultDependencies=no
Wants=data.mount
After=data.mount
Before=systemd-machine-id-commit.service dbus.service dbus.socket systemd-journal-flush.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/micropanel-touch-restore-machine-id
# Keep boot viable if a future systemd layout does not permit the restart; the
# image acceptance checks below deliberately verify that the HMI journal is
# still queryable after the first boot.
ExecStartPost=-/usr/bin/systemctl try-restart systemd-journald.service
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF
systemctl enable micropanel-touch-machine-id.service
: > /etc/machine-id
chmod 0444 /etc/machine-id
install -d /var/lib/dbus
: > /var/lib/dbus/machine-id
chmod 0444 /var/lib/dbus/machine-id

# Root-overlay images run the stock first-boot key generators on every boot:
# their writes disappear with the tmpfs upper layer. This unit instead seeds
# one set of host keys on /data, then copies that set into the temporary root
# before sshd starts. If /data cannot mount, the stock lower-image keys remain
# a recovery fallback rather than preventing SSH from starting.
cat > /usr/local/sbin/micropanel-touch-restore-ssh-host-keys <<'EOF'
#!/bin/sh
set -eu

persistent_dir=/data/micropanel-touch/ssh-host-keys
system_dir=/etc/ssh

[ -d "$persistent_dir" ] && [ -d "$system_dir" ] || exit 0
[ -w "$persistent_dir" ] || exit 0

umask 077
for key_type in rsa ecdsa ed25519; do
    persistent_key="$persistent_dir/ssh_host_${key_type}_key"
    persistent_public_key="${persistent_key}.pub"
    system_key="$system_dir/ssh_host_${key_type}_key"
    system_public_key="${system_key}.pub"

    if ! /usr/bin/ssh-keygen -lf "$persistent_key" >/dev/null 2>&1; then
        rm -f "$persistent_key" "$persistent_public_key"
        /usr/bin/ssh-keygen -q -N '' -t "$key_type" -f "$persistent_key"
    fi
    if [ ! -s "$persistent_public_key" ]; then
        /usr/bin/ssh-keygen -y -f "$persistent_key" > "$persistent_public_key"
    fi
    chmod 0600 "$persistent_key"
    chmod 0644 "$persistent_public_key"
    install -m0600 "$persistent_key" "$system_key"
    install -m0644 "$persistent_public_key" "$system_public_key"
done
EOF
chmod 0755 /usr/local/sbin/micropanel-touch-restore-ssh-host-keys
cat > /etc/systemd/system/micropanel-touch-ssh-host-keys.service <<'EOF'
[Unit]
Description=Restore persistent MicroPanel Touch SSH host keys
Wants=data.mount
After=data.mount
Before=ssh.service sshd.service
After=cloud-init-network.service cloud-config.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/micropanel-touch-restore-ssh-host-keys

[Install]
WantedBy=ssh.service
EOF
# Pi OS ships regenerate_ssh_host_keys.service; Debian does not normally ship
# sshd-keygen.service, but masking the optional compatibility name is harmless.
systemctl mask regenerate_ssh_host_keys.service sshd-keygen.service
systemctl enable micropanel-touch-ssh-host-keys.service

# sdm's first-boot pass has no remaining actions after this image pipeline has
# applied its user and board configuration. On an overlay-root appliance it can
# only disable itself in transient RAM, so it returns on every boot and writes
# a final status message directly to tty1. Remove it from multi-user.target in
# the immutable image and retain a condition guard against future re-enabling.
systemctl disable sdm-firstboot.service
install -d /etc/systemd/system/sdm-firstboot.service.d
cat > /etc/systemd/system/sdm-firstboot.service.d/50-micropanel-touch-disable.conf <<'EOF'
[Unit]
# Explicitly opt in only when debugging an image-builder first-boot pass.
ConditionKernelCommandLine=micropanel-touch.sdm-firstboot=1
EOF

# Pi OS cloud-init can emit SSH public-key material directly to /dev/console,
# which shares fb0 with PiScreen. Suppress that disclosure independently of
# the persistent-key service above; this must not restore console output.
install -d /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/90-micropanel-touch-console.cfg <<'EOF'
#cloud-config
ssh:
  emit_keys_to_console: false
# The persistent-key service above is the sole host-key owner. Cloud-init's
# first-boot state is volatile under overlayroot, so it must not replace those
# device-specific keys again on every boot.
ssh_deletekeys: false
ssh_genkeytypes: []
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

# `recurse=0` leaves non-root fstab mounts alone. Pi OS's rpi-swap generator
# otherwise enables a zram device, consuming RAM for swap on an appliance
# whose writable root is already tmpfs. Disable every rpi-swap mechanism at
# its source; this also prevents a future zram+file mode from writing below
# the overlay root.
install -d /etc/rpi/swap.conf.d
cat > /etc/rpi/swap.conf.d/90-micropanel-touch.conf <<'EOF'
[Main]
Mechanism=none
EOF

# An overlay-backed root is intentionally neither remountable nor a block
# device that can be grown. Treat these generic root-maintenance jobs as not
# applicable so their expected failures do not cascade into boot warnings.
# These are exact whole-token conditions, so list both the legacy token and
# this board's non-recursive form deliberately.
for root_unit in systemd-remount-fs.service systemd-growfs-root.service; do
    install -d "/etc/systemd/system/${root_unit}.d"
    cat > "/etc/systemd/system/${root_unit}.d/50-micropanel-touch-overlay-root.conf" <<'EOF'
[Unit]
ConditionKernelCommandLine=!overlayroot=tmpfs
ConditionKernelCommandLine=!overlayroot=tmpfs:recurse=0
EOF
done

# Bake the supported Pi OS overlayfs configuration after all build-time writes
# are complete. The post-image hook supplies /data as the persistent volume.
# On Trixie, do_overlayfs also owns the boot-partition write-protection policy;
# the former do_boot_ro noninteractive action no longer exists.
raspi-config nonint do_overlayfs 0
overlayroot_token='overlayroot=tmpfs:recurse=0'
if grep -Eq "(^|[[:space:]])${overlayroot_token}([[:space:]]|$)" /boot/firmware/cmdline.txt; then
    :
elif grep -Eq '(^|[[:space:]])overlayroot=tmpfs([[:space:]]|$)' /boot/firmware/cmdline.txt; then
    # overlayroot's default recurse=1 overlays every fstab mount below /,
    # including /data. The appliance root is volatile, but p3 must stay ext4.
    sed -i -E 's/(^|[[:space:]])overlayroot=tmpfs([[:space:]]|$)/\1overlayroot=tmpfs:recurse=0\2/' \
        /boot/firmware/cmdline.txt
else
    echo "ERROR: raspi-config did not enable overlayroot in cmdline.txt" >&2
    exit 1
fi
grep -Eq "(^|[[:space:]])${overlayroot_token}([[:space:]]|$)" /boot/firmware/cmdline.txt || {
    echo "ERROR: unable to configure non-recursive overlayroot" >&2
    exit 1
}

mkdir -p "$destination/share/micropanel-touch"
cat > "$destination/share/micropanel-touch/image-manifest.env" <<EOF
MICROPANEL_TOUCH_REVISION=$revision
LVGL_REVISION=$(git -C "$source_root/external/lvgl" rev-parse HEAD)
EOF

rm -rf "$source_root"
