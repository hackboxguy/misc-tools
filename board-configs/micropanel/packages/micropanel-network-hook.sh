#!/bin/bash
# micropanel network defaults - both layouts (hooks.txt and hooks-ab.txt).
#
# What br-wrapper's network-manager-app (the launcher's Network tile) needs
# from the image, from its plan (docs/network-manager-app-plan.md, 5.4); each
# item was written into rig 1's A/B image root by hand and booted before it
# went here:
#
#  1. The system dnsmasq.service disabled and masked. It listens on port 53 on
#     every address, and NetworkManager's shared mode (the app's DHCP-server
#     mode) then fails to start its own dnsmasq ("Address already in use").
#     Nothing in the image needs it running: the OLED menu's own DHCP-server
#     mode unmasks and starts it when asked.
#  2. The no-gateway drop-in for NetworkManager's shared-mode dnsmasq: a port
#     that serves addresses announces no router and no DNS server, so clients
#     keep their own routing (ipv4.never-default alone does not do it).
#  3. WiFi on at boot, country DE (the owner's choice, 2026-10-05): NetworkManager's
#     WirelessEnabled=true, a saved rfkill state 0 for the Pi 4's WiFi radio
#     (it overrides Pi OS's rfkill_default.conf, which soft-blocks every radio
#     at boot), and the regulatory domain as a cfg80211 module option. Saved
#     WiFi networks then reconnect at boot without anyone opening the app.
#     The app reports the image default from the regdom line ("wifiboot=on"),
#     so keep that form.
#  4. The DHCP guard: br-wrapper installs its NetworkManager dispatcher script
#     (share/network-manager-app/90-net-ctl-guard, with the path of its
#     net-ctl.sh filled in); NetworkManager runs dispatcher scripts only from
#     /etc/NetworkManager/dispatcher.d, owned by root and not writable by
#     others, and pre-up ones only through pre-up.d/. A port in the app's
#     DHCP-server mode that comes up then asks the network first, and stops
#     serving if another DHCP server answers - with the app closed too.
#     br-wrapper is installed by an earlier line of the hooks list.
#
# Why both layouts: on the A/B image /etc and /var are rebuilt from the image
# at every boot, so these are the device's settings for good; on the
# single-slot image they are the first-boot defaults (a later radio switch or
# an unmask persists there). The reasons hold for either.
#
# Board-specific: the rfkill state file is named after the Pi 4's WiFi device
# (platform-fe300000.mmcnr); a Pi 5 board needs its own name.
set -euo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

say() { echo "[network] $*"; }
die() { echo "[network] ERROR: $*" >&2; exit 1; }

country=${MICROPANEL_WIFI_COUNTRY:-DE}
dropin=/etc/NetworkManager/dnsmasq-shared.d/90-micropanel-no-gateway.conf
nm_state=/var/lib/NetworkManager/NetworkManager.state
rfkill_state=/var/lib/systemd/rfkill/platform-fe300000.mmcnr:wlan
regdom=/etc/modprobe.d/cfg80211-regdom.conf
guard_src=${MICROPANEL_PREFIX:-/home/pi/micropanel}/share/network-manager-app/90-net-ctl-guard
dispatcher=/etc/NetworkManager/dispatcher.d

# --- 1. The system dnsmasq off ------------------------------------------------
systemctl disable dnsmasq.service 2>/dev/null || true
systemctl mask dnsmasq.service
[ "$(readlink /etc/systemd/system/dnsmasq.service)" = /dev/null ] || die "dnsmasq.service is not masked"
[ ! -e /etc/systemd/system/multi-user.target.wants/dnsmasq.service ] || die "dnsmasq.service is still enabled"
say "dnsmasq.service disabled and masked (it blocks NetworkManager's shared mode)"

# --- 2. Shared mode announces no gateway and no DNS -----------------------------
install -d -m0755 "$(dirname "$dropin")"
cat > "$dropin" <<'EOF'
# network-manager-app: serve addresses only - no router, no DNS server announced
dhcp-option=3
dhcp-option=6
EOF
chmod 0644 "$dropin"
for option in 'dhcp-option=3' 'dhcp-option=6'; do
    grep -qx "$option" "$dropin" || die "drop-in lacks $option: $dropin"
done
say "no-gateway drop-in installed: $dropin"

# --- 3. WiFi on at boot, country $country ------------------------------------------
install -d -m0755 "$(dirname "$nm_state")"
if [ -f "$nm_state" ]; then
    if grep -q '^WirelessEnabled=' "$nm_state"; then
        sed -i 's/^WirelessEnabled=.*/WirelessEnabled=true/' "$nm_state"
    elif grep -q '^\[main\]' "$nm_state"; then
        sed -i '/^\[main\]/a WirelessEnabled=true' "$nm_state"
    else
        printf '[main]\nWirelessEnabled=true\n' >> "$nm_state"
    fi
else
    printf '[main]\nNetworkingEnabled=true\nWirelessEnabled=true\nWWANEnabled=true\n' > "$nm_state"
fi
[ "$(grep -c '^WirelessEnabled=true$' "$nm_state")" = 1 ] || die "WirelessEnabled=true not set once in $nm_state"
install -d -m0755 "$(dirname "$rfkill_state")"
printf '0\n' > "$rfkill_state"
chmod 0644 "$rfkill_state"
install -d -m0755 "$(dirname "$regdom")"
printf '# micropanel: WiFi regulatory domain (network-manager-app plan 5.4)\noptions cfg80211 ieee80211_regdom=%s\n' \
    "$country" > "$regdom"
chmod 0644 "$regdom"
grep -qx "options cfg80211 ieee80211_regdom=$country" "$regdom" || die "regulatory domain not written: $regdom"
say "WiFi on at boot: WirelessEnabled=true, $rfkill_state = 0, cfg80211 regdom $country"

# --- 4. The DHCP guard ------------------------------------------------------------
[ -f "$guard_src" ] || die "br-wrapper's dispatcher script is missing: $guard_src (is br-wrapper installed first?)"
install -d -m0755 "$dispatcher/pre-up.d"
install -o root -g root -m0755 "$guard_src" "$dispatcher/90-net-ctl-guard"
ln -sfn ../90-net-ctl-guard "$dispatcher/pre-up.d/90-net-ctl-guard"
# shellcheck disable=SC2016 # a literal ${NET_CTL:-...} in the pattern
net_ctl=$(sed -n 's/^NET_CTL=\${NET_CTL:-\(.*\)}$/\1/p' "$dispatcher/90-net-ctl-guard")
[ -x "$net_ctl" ] || die "the dispatcher script calls $net_ctl, which is not installed"
[ "$(stat -c '%U %a' "$dispatcher/90-net-ctl-guard")" = "root 755" ] || die "the dispatcher script is not root-owned 0755"
[ "$(readlink "$dispatcher/pre-up.d/90-net-ctl-guard")" = ../90-net-ctl-guard ] || die "pre-up.d link missing"
say "DHCP guard: $dispatcher/90-net-ctl-guard (+ pre-up.d), calls $net_ctl"
