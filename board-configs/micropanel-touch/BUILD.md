# MicroPanel Touch image build

From the `misc-tools` checkout, build the first Sprint 2.5 appliance slice
with:

```sh
sudo ./build-image.sh --board=micropanel-touch --version=00.10
```

The command above remains the verified PiScreen ILI9486/ADS7846 image. For
the separately verified Luckfox **3.5-RPi-LCD-CTP** (ST7796S display and GT911
touch) build the opt-in variant instead:

```sh
sudo ./build-image.sh --board=micropanel-touch --variant=luckfox-ctp --version=00.10
```

The variant installs the pinned ST7796S MIPI-DBI command firmware, enables
SPI0/I²C1, writes a variant-only `panel_mipi_dbi` module-load rule, and
replaces the PiScreen managed overlay block with the GT911 `0x5d` profile.
It also enables the MIPI-DBI PWM backlight on GPIO 18, explicitly disables
analogue audio, and installs a Luckfox-only udev rule that grants the HMI
account read/write access to exactly
`/sys/class/backlight/backlight_pwm/brightness` when that node is created; no
raw GPIO access or general-purpose privileged display helper is added. The app
blanks this kernel-owned backlight after 60 seconds by default, restores the
selected 5–100% brightness after wake, and consumes the complete wake touch.
Set
`"power": {"display_sleep_sec": 0}` in the starter config to disable sleep
for an acceptance session.
The explicit module rule is required on the modular Debian kernel: `st7796s`
must remain the first compatible string so the MIPI-DBI driver selects
`st7796s.bin`, but it does not match the driver's autoload alias. Do not use a
PiScreen and Luckfox panel together: they have mutually exclusive SPI0/GPIO
claims. After flashing the Luckfox image, retain SSH access for initial
acceptance and check `--probe`, the service journal, portrait geometry, touch
navigation, and a clean power-cycle before treating the panel as released.

The board config pins both the Raspberry Pi OS Lite artifact and the
`micropanel-touch` commit named in `hooks.txt`. That commit must be available
from its Git remote before starting the build; the dedicated hook clones it
with its LVGL submodule recursively.

The development image uses the build system's standard Pi-user password when
`--password` is omitted. Supply `--password=PASS` to override it. When only
the password or an apps hook changed, retain the completed base image and
rebuild just apps with `--skip-base`.

Before flashing, inspect the result with a loop device or `fdisk -l`: it must
have boot (`p1`), authored root (`p2`), and the `MICROPANEL_DATA` ext4 data
partition (`p3`). The image must not carry an `expand-root` first-boot action.

On the first hardware boot, verify:

```sh
findmnt -no TARGET,OPTIONS /
findmnt -no TARGET,OPTIONS /boot/firmware
findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /data
findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /etc/NetworkManager/system-connections
cat /proc/swaps
systemctl is-enabled dphys-swapfile
systemctl is-active micropanel-touch.service micropanel-touch-privileged.service
systemctl is-active micropanel-touch-machine-id.service
systemctl is-enabled micropanel-touch-dhcp-server.service
systemctl is-enabled dnsmasq.service
stat -c '%U %a %n' /run/micropanel-touch/broker.sock
sudo stat -c '%U:%G %a %n' /data/micropanel-touch-system /data/micropanel-touch-system/machine-id
printf 'persistent='; sudo cat /data/micropanel-touch-system/machine-id
printf 'etc='; cat /etc/machine-id
printf 'dbus='; cat /var/lib/dbus/machine-id
systemctl --failed --no-pager
```

Hardware acceptance confirms the overlay-backed root, two active appliance
services, no failed units, a `0600` broker socket owned by
`micropanel-touch`, `/data` as direct p3 `ext4`, and a data-backed
NetworkManager profile directory. Its root command line contains
`overlayroot=tmpfs:recurse=0`. `/boot/firmware` must be mounted read-only;
`/proc/swaps` must show only its header and `dphys-swapfile` must be disabled.
(`swapon` is not installed on the current Lite image.) These last three checks
guard against `recurse=0` unintentionally making non-root mounts writable or
creating RAM-backed swap through either `dphys-swapfile` or Pi OS's current
`rpi-swap` zram generator.

Before treating the image as persistence-ready, perform this harmless
application-data check, then repeat the read after a normal reboot and an
unplug/reapply-power boot:

```sh
sudo sh -c 'printf "%s\\n" persistence-check > /data/micropanel-touch/.persistence-check'
sync
sudo cat /data/micropanel-touch/.persistence-check
sudo sha256sum /etc/ssh/ssh_host_*_key.pub | sort
machine_id=$(cat /etc/machine-id)
test "$machine_id" = "$(cat /var/lib/dbus/machine-id)"
test "$machine_id" = "$(sudo cat /data/micropanel-touch-system/machine-id)"
```

After each boot, repeat the three identity reads and compare them with the
recorded `machine_id`. The marker, SSH public-key hashes, and machine ID must
remain stable through normal reboot and physical power-cycle. A fresh image
must report a non-empty, non-zero ID and it must differ from a separately
flashed card. Keep this check as a regression acceptance test. A
broker-applied NetworkManager change still needs its own post-reboot test.

The NetworkManager polkit rule intentionally requires the non-root `pi` account
to use `sudo` for direct mutation; the appliance's intended mutation route is
the typed broker. A first approved static-IP test on `eth0` found a broker
cancellation-flag defect: the profile was saved to p3 and activated, but the
broker falsely returned `cancelled`; DHCP was restored directly. The pinned
follow-up fixes that flag. Flash it, then use the broker to apply static IPv4
matching the current address, reboot and verify the `manual` profile, apply
DHCP through the broker, and reboot again to verify the `auto` profile. Record
the profile and live address after each step.

## DHCP-server acceptance

DHCP Server is intentionally an **isolated eth0 provisioning mode**, not a
normal-LAN option. Do not enable it on the production LAN: applying it changes
the panel address, ends the existing SSH session, and a second DHCP authority
would be unsafe. Use a directly connected client or a dedicated isolated
switch/VLAN with no other DHCP server.

On the fresh image, `micropanel-touch-dhcp-server.service` must be enabled but
inactive while the UI is in DHCP-Client or Static-Address mode, and
`dnsmasq.service` must be masked. In IP Settings select DHCP-Server and use
the default `192.168.50.1/24` / `.100`–`.200` pool (or a valid private
alternative), then complete the second confirmation. From the isolated client,
verify it receives a lease in the selected range, can reach the panel server
address, and receives neither a default route nor a DNS server from it. Reboot
the panel and repeat the lease check: the lease database is intentionally
volatile, so the client may rediscover rather than retain its previous lease.
The server uses dnsmasq dynamic binding to tolerate NetworkManager applying
the saved manual address during boot; it should not emit an address-bind retry
failure. Finally select DHCP-Client on the panel, verify the dedicated server
unit stops and remains inactive after reboot.
