# MicroPanel Touch image build

From the `misc-tools` checkout, build the first Sprint 2.5 appliance slice
with:

```sh
sudo ./build-image.sh --board=micropanel-touch --version=00.10
```

## A/B Stage 1 layout

The normal command above deliberately remains the established single-slot
image during the transition.  Build the in-system-update foundation with the
explicit A/B option instead:

```sh
sudo ./build-image.sh --board=micropanel-touch --variant=luckfox-ctp \
  --layout=ab --version=00.13
```

The A/B artifact is fixed at 15,000 MiB, so flash it only to a nominal 16 GB
or larger card.  It has an MBR table with `MP_BOOT_A` (p1), reserved empty
`MP_BOOT_B` (p2), an extended p3, roots `MP_ROOT_A` (p5) and `MP_ROOT_B`
(p6), empty `MP_FACTORY` (p7), and the remaining `MICROPANEL_DATA` p8.
The apps-stage source has only boot and root partitions. The finalizer creates
p8 through the shared durable-state skeleton and seeds shipped NetworkManager
profiles from the authored root; it must never leave p8 as a bare empty ext4
filesystem.

Before flashing an A/B artifact, run the read-only host check as root:

```sh
sudo board-configs/micropanel-touch/packages/verify-ab-image-layout.sh \
  /path/to/micropanel-touch-luckfox-ctp-ab-00.13.img
```

The A/B build uses a separate `out/micropanel-touch-luckfox-ctp-ab/`
directory and an `-ab-` filename infix. This prevents it being mistaken for,
or overwriting, a same-version single-slot artifact.

### Stage 2 payload output

Add `--payload` to derive the unsigned, slot-neutral update artifacts from
the same completed A/B image. The root filesystem is compressed only while it
is read and is never materialized as a second uncompressed host file.

```sh
sudo ./build-image.sh --board=micropanel-touch --variant=luckfox-ctp \
  --layout=ab --payload --payload-dir=/srv/micropanel-release/00.15 \
  --version=00.15
```

This writes one matching `.rootfs.img.xz`, `.boot.tar`, and `.manifest` under
the chosen payload directory. Copy all three, without renaming them, to the
root of one FAT32 USB filesystem labelled `MP_UPDATE`. FAT32 labels are limited
to eleven characters; this label is deliberately within that limit. The Stage
2 UI mounts only that labelled filesystem read-only; it rejects a missing,
extra, renamed, wrong-variant, wrong-board, malformed, or hash-mismatched
payload before it can arm tryboot.

An update streams directly into the inactive root partition, then reboots into
that candidate once. Do not remove power while the display says it is writing.
After candidate boot, the appliance waits for its HMI, broker, `/data`, and a
rendered first frame to remain healthy for 30 seconds before committing. If a
candidate does not return within three minutes, remove and reapply power: the
one-shot candidate is abandoned and the previously committed slot returns.
Every published payload must first complete a Pi 4 + Luckfox CTP bench boot
acceptance.

The static A/B contract check runs automatically during an A/B build's
preflight. The finalizer/verifier integration fixture remains a manual
pre-flash check and uses only a temporary loopback image:

```sh
board-configs/micropanel-touch/tests/test_ab_layout_static.sh
sudo board-configs/micropanel-touch/tests/test_ab_layout_integration.sh
```

On a freshly flashed A/B image only slot A is populated.  `MP_ROOT_B` and
`MP_FACTORY` are intentionally empty reserves; do not `tryboot` B until a
payload or the Stage 1 manual-population acceptance procedure has filled it.
The normal and one-shot selectors are complete files: normal `config.txt`
uses `os_prefix=A/` and `tryboot.txt` uses `os_prefix=B/` on first flash,
rather than a `[tryboot]` section embedded in `config.txt`. Normal
`os_prefix=A/` was accepted on the Pi 4 + Luckfox CTP card with the real p8
data skeleton, including an A-only cmdline marker proof. A subsequent update
therefore writes only the target slot's `A/` or `B/` boot tree; flat p1 boot
files are not a committed path.

Those flat p1 files are a factory-version snapshot only. After any slot
update they can be stale and must never be selected by removing `os_prefix`.
Recover a selector by rendering it from the running slot's selector template;
if a slot boot tree itself is damaged, reflash rather than attempting to pair
a flat factory kernel with a later root filesystem.

### Manual slot-B population and Stage 1 selector acceptance

Run this only on a disposable bench card while a person is present. Keep the
known-good recovery card available: a candidate that fails before PID 1 is
currently recovered by one manual power-cycle. It is the manual analogue of
the future updater's stream → hash → `e2label` → arm sequence.

The commands assume the freshly flashed card is running slot A from its SD
device (`/dev/mmcblk0`), p6 is unmounted, and B is still empty. Do **not**
reboot between `dd` and `e2label`: copying p5 initially clones the
`MP_ROOT_A` ext4 label and creates an unsafe duplicate-label state.

```sh
# On the Pi, while running A. p5 is the read-only lower root; p6 must be idle.
if findmnt -rn -S /dev/mmcblk0p6 >/dev/null; then
  echo 'MP_ROOT_B is mounted'
  exit 1
fi
sudo dd if=/dev/mmcblk0p5 of=/dev/mmcblk0p6 bs=8M status=progress conv=fsync
sudo e2label /dev/mmcblk0p6 MP_ROOT_B
sudo e2fsck -pf /dev/mmcblk0p6
sudo blkid /dev/mmcblk0p5 /dev/mmcblk0p6

# Arm only the inactive B slot, then boot it exactly once.
selector=/usr/local/sbin/micropanel-touch-slot-selector
sudo "$selector" current-slot                 # must print A
sudo "$selector" arm-candidate B
sudo reboot "0 tryboot"
```

After SSH returns, confirm `current-slot` prints B, the HMI, broker,
machine-ID service and `/data` are healthy, then commit **from B**. The
selector intentionally rejects `commit B` while A is running.

```sh
selector=/usr/local/sbin/micropanel-touch-slot-selector
sudo "$selector" current-slot                 # must print B
systemctl is-active micropanel-touch.service micropanel-touch-privileged.service \
  micropanel-touch-machine-id.service
findmnt -no TARGET,SOURCE,OPTIONS /data
sudo "$selector" commit B
sudo reboot
```

The next normal boot must remain on B. Finally arm A from B, use
`reboot "0 tryboot"` to prove a healthy one-shot A boot, do **not** commit A,
then use an ordinary reboot and confirm normal boot returns to B. This proves
the selector guards and the one-shot path without hand-editing generated
`config.txt` or `tryboot.txt`.

On A/B images, `config.txt` and `tryboot.txt` are selector-managed generated
files. Persistent image-level configuration changes belong in
`/usr/lib/micropanel-touch/boot-selector-config.base` before the image is
built; an ad-hoc edit to p1 is overwritten by the next selector commit.
Because `config.txt` itself is shared by both slots, a template change is a
special release: it must be called out in the release notes and the fallback
slot must be re-tested. The accepted Luckfox CTP A/B manifest currently names
**Pi 4 only**. Do not use it on Pi 5 until the RP1-specific panel overlay has
separate hardware acceptance.

The command above remains the verified PiScreen ILI9486/ADS7846 image. For
the separately verified Luckfox **3.5-RPi-LCD-CTP** (ST7796S display and GT911
touch) build the opt-in variant instead:

```sh
sudo ./build-image.sh --board=micropanel-touch --variant=luckfox-ctp --version=00.10
```

The default PiScreen profile has a fixed-on backlight. A three-second
libgpiod low drive of GPIO 22 on the accepted bench panel caused no visible
change; GPIO 22 belongs to the panel overlay's pin group. It therefore leaves
**Display → Standby** and **Display → Brightness** unavailable, and no
overlay may claim GPIO 22 again.

The variant installs the pinned ST7796S MIPI-DBI command firmware, enables
SPI0/I²C1, writes a variant-only `panel_mipi_dbi` module-load rule, and
replaces the PiScreen managed overlay block with the GT911 `0x5d` profile.
It also enables the MIPI-DBI PWM backlight on GPIO 18, explicitly disables
analogue audio and blacklists its competing `snd_bcm2835` module, and installs
a Luckfox-only udev rule that grants the HMI
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

Before flashing a normal single-slot image, inspect the result with a loop
device or `fdisk -l`: it must have boot (`p1`), authored root (`p2`), and the
`MICROPANEL_DATA` ext4 data partition (`p3`). The image must not carry an
`expand-root` first-boot action. Use the A/B verifier above for an A/B image.

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
journalctl -b -u micropanel-touch.service --no-pager -n 5
systemctl --failed --no-pager
```

Hardware acceptance confirms the overlay-backed root, two active appliance
services, no failed units, a `0600` broker socket owned by
`micropanel-touch`, `/data` as the direct label-backed data `ext4` partition
(p3 on a single-slot image; p8 on an A/B image), and a data-backed
NetworkManager profile directory. Its root command line contains
`overlayroot=tmpfs:recurse=0`. `/boot/firmware` must be mounted read-only;
`/proc/swaps` must show only its header and `dphys-swapfile` must be disabled.
(`swapon` is not installed on the current Lite image.) These last three checks
guard against `recurse=0` unintentionally making non-root mounts writable or
creating RAM-backed swap through either `dphys-swapfile` or Pi OS's current
`rpi-swap` zram generator.

The `journalctl` command must show current-boot HMI entries. The early
machine-ID service restarts journald before the journal-flush phase after it
restores the durable ID, so the running journal directory matches the ID that
`journalctl` uses for its lookup.

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
cancellation-flag defect: the profile was saved to the persistent data
partition and activated, but the
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
