# MicroPanel Touch image build

From the `misc-tools` checkout, build the first Sprint 2.5 appliance slice
with:

```sh
sudo ./build-image.sh --board=micropanel-touch --version=00.10 \
  --app-ref=main
```

Every MicroPanel Touch build requires exactly one application source. Use
`--app-ref=main` for the latest pushed main branch: the builder resolves it
once to a full commit before preflight, then checks out, records, and verifies
that immutable result during post-layout and payload checks. The build output
and image manifest retain the resolved commit for traceability. For an exact
rebuild, use `--app-revision=<full lowercase SHA>` instead. A build cannot
silently reuse an old hook pin after an application change.

## A/B Stage 1 layout

The normal command above deliberately remains the established single-slot
image during the transition.  Build the in-system-update foundation with the
explicit A/B option instead:

```sh
sudo ./build-image.sh --board=micropanel-touch --variant=luckfox-ctp \
  --layout=ab --version=00.13 --app-ref=main
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
sudo AB_MANIFEST_PATH=/opt/micropanel-touch/share/micropanel-touch/image-manifest.env \
  AB_ASSERTIONS=board-configs/micropanel-touch/ab-assertions.sh \
  packages/pi-ab-update/ab-verify-image.sh \
  /path/to/micropanel-touch-luckfox-ctp-ab-00.13.img
```

The A/B build uses a separate `out/micropanel-touch-luckfox-ctp-ab/`
directory and an `-ab-` filename infix. This prevents it being mistaken for,
or overwriting, a same-version single-slot artifact.

### Stage 2b update bundle output

Add `--payload` to derive the signed, slot-neutral update bundle from the same
completed A/B image. The root filesystem is compressed only while it is read
and is never materialized as a second uncompressed host file.

```sh
sudo ./build-image.sh --board=micropanel-touch --variant=luckfox-ctp \
  --layout=ab --payload --payload-dir=/srv/micropanel-release/00.25 \
  --version=00.25 --app-ref=main
```

This writes exactly **two** files into the chosen payload directory:

```
micropanel-touch-<variant>.mpupdate    the update bundle
micropanel-touch-<variant>.manifest    a standalone copy of its manifest
```

Both names are deliberately **version-less**: the release version lives inside
the manifest, so the Stage 4 `releases/latest/download/` URLs are stable and a
stick never carries two competing names. Rerunning `--payload` for the same
payload directory replaces both files atomically; wait for the successful
`Created update payload` message before copying anything.

**The complete end-user instruction is one sentence:** *copy the
`micropanel-touch-<variant>.mpupdate` file onto a USB stick, plug it into the
panel, and tap System → Software Update → Check USB stick.* No formatting, no
volume label, no partitioning, and no second file. The panel accepts any
USB-transport FAT32 or exFAT filesystem — including the exFAT that Windows
gives sticks larger than 32 GB — and requires exactly one `*.mpupdate` file
across all attached USB media. It refuses zero bundles and refuses two.

The bundle is an uncompressed **ustar** archive whose members appear in one
fixed order, which is what lets the device read it in a single pass from a file
or a pipe:

| # | Member | Purpose |
|---|---|---|
| 1 | `manifest` | `SettingsFile` grammar, `format=2`; first so a wrong variant, unsupported board, or already-installed version aborts after a few kilobytes |
| 2 | `manifest.sig` | ed25519 signature over member 1. Present in every published bundle from the first `format=2` release; the device accepts and ignores it until Stage 4 turns verification on |
| 3 | `boot.tar` | `os_prefix` tree plus the slot-neutral `cmdline.txt.template`; staged root-only and hash-checked before use |
| 4 | `rootfs.img.xz` | last, so the multi-gigabyte tail streams straight into the inactive slot |

The former `format=1` triplet (`.rootfs.img.xz`, `.boot.tar`, `.manifest` on a
FAT32 stick labelled `MP_UPDATE`) is **retired**. It is now a build
intermediate only and the device-side reader rejects `format=1`. This is a
deliberate prototype-phase break: an `MP_UPDATE` stick prepared for an earlier
release will not be recognized by a Stage 2b image.

The generated root filesystem deliberately has no ext4 volume label, so it is
safe to write to either inactive slot. The generator clears that label with
`e2label` (preserving ext4 metadata checksums), streams the artifact, then
restores `MP_ROOT_A` on the source image before it publishes the bundle.

### The image diet — measured, 2026-08-20

The bundle used to be **1.46 GiB against two independent 2 GiB ceilings**: the
GitHub release-asset limit and the reserved `MP_FACTORY` partition. 73 % of
both, which is uncomfortable for a Pi OS Lite appliance and would have been hit
without warning as the rootfs grew.

Two changes, in order of how much they returned:

**1. The payload carried the slot's freed blocks.** `ab-make-payload.sh`
streams the whole 5 GiB slot partition through `xz`, so every block the build
had written and then deleted — purged build dependencies, apt caches, the
application's own build tree — travelled into the release compressing like the
data it used to be. `ab-finalize-layout.sh` now fills the slot's free space
with zeros before the image is sealed, and hands the blocks back with `fstrim`
so the authored `.img` stays sparse on the build host. This removes nothing
from the running system.

**2. Stock Raspberry Pi OS Lite, declined in part.** The measurement that
motivated the trim is worth stating, because it is not what one would guess: a
*pristine* Lite rootfs is 1860 MiB and this appliance's was 1958 MiB. Almost
none of the weight was ours. `slim-remove.txt` carries the per-entry reasoning;
the shape of it is the C toolchain and kernel headers that stock Lite ships,
a second kernel flavour for a board this image refuses to install on, the
superseded kernel the base stage's `apt upgrade` leaves behind, firmware for
radios this board cannot have, and — genuinely — `mkvtoolnix`, which drags in
Qt and ICU on an image whose PRD rejects Qt. Documentation, translations and
apt's package indexes go with them, since a read-only root cannot apt and
nothing on the device reads a man page.

Measured on the same source tree, `00.39` before and `00.40` after:

| | rootfs used | boot | `rootfs.img.xz` | bundle | of a 2 GiB ceiling |
|---|---|---|---|---|---|
| `00.39` | 1958 MiB | 67 MiB | 1,501,804,636 B | **1,571,543,040 B** (1.46 GiB) | **73.2 %** |
| free-space zeroing only | 1958 MiB | 67 MiB | 561,675,028 B | ~631 MB (0.59 GiB) | ~29 % |
| `00.40` (both) | **764 MiB** | **46 MiB** | — | **229,580,800 B** (0.21 GiB) | **10.7 %** |

A 6.8× reduction, and about 40 % of it is the free-space pass alone — the
change that removes nothing.

**What was measured but not taken.** The Python 3 stack is a further ~180 MiB,
but removing it takes `cloud-init`, `netplan.io` and `rpicam-apps` with it.
That is a different kind of risk from removing a compiler, and it belongs in
its own slice with its own bench boot rather than riding along with this one.

**The gate is the size, not the list.** `SLIM_MAX_ROOT_MB` in `board.conf`
fails the build if the trimmed rootfs exceeds it. That matters because a
base-image bump can silently stop matching a pinned kernel version in
`slim-remove.txt`; a missed removal then shows up as a build failure rather
than as a quietly fatter release.

### Does the 2 GiB `MP_FACTORY` reservation still stand? Yes — 2026-08-20

`pi-in-system-update-plan.md` §7 left this open. The measured answer:

The factory payload is the same signed bundle artifact, so the reservation has
to hold one bundle: **0.21 GiB today, against 2 GiB reserved** — about 9× the
payload, where it used to be 1.4×.

Keep the 2 GiB. The reasoning is asymmetry, not headroom. Partition sizes are
frozen at flash time, so an oversized factory payload cannot be fixed on units
already in the field, while an over-generous reservation costs only `/data`
space on a card that has ~2.1 GiB of it and no growth plan. Recovering 1.8 GiB
of that would be worth doing if `/data` were under pressure. It is not.

The number that would reopen this is a Tier-2 pack stack: the fpga/mcu-flash
and camera/gstreamer flavours (PRD §6.7) add toolchains and bitstreams to the
rootfs, and each flavour's payload has to fit the same 2 GiB. With the base at
0.21 GiB there is room for a pack an order of magnitude larger than the base
system before either ceiling is in view — which is exactly the headroom this
diet was for.

### The Wi-Fi radio's baked default — bench finding, 2026-08-20

Stock Raspberry Pi OS Lite ships `/var/lib/NetworkManager/NetworkManager.state`
containing `WirelessEnabled=false`. On this image that file is in the
**read-only lower root**, so `nmcli radio wifi on` writes to the tmpfs upper
layer and is forgotten at the next boot. `phy0` comes up soft-blocked every
time.

The visible effect on the panel is that Network → Wi-Fi reports the radio state
rather than a list of networks, on every boot, **with no on-screen way out of
it** — the join feature is simply unreachable. Nothing in the test suite could
have caught this: the file is stock content the build never touched, and the
only way to see it is to boot the image and look.

The app hook now bakes `WirelessEnabled=true` into the image, and
`test_ab_layout_static.sh` asserts it so a hook edit cannot quietly drop it. An
operator can still turn the radio off at runtime; that choice is deliberately
volatile, because the baked default is what keeps the feature reachable after a
reflash or a factory reset.

Confirmed on the bench: with the radio enabled, `nmcli device wifi list` on the
panel returns eight access points, so the scan screen has real rows to render.

### The Wi-Fi regulatory domain is unset — known, not fixed

Related to the above, and worth knowing before anyone spends time on a failing
join: the panel's regulatory domain is **`00` (world)**, because no Wi-Fi
country has ever been set on this image.

`cat /sys/module/cfg80211/parameters/ieee80211_regdom` returns `00` on the
bench, and `iw` is not installed to say more. Under the world domain the 5 GHz
channels are conventionally passive-scan-only, so an access point on them is
*visible but not joinable*; 2.4 GHz channels 1–11 are unrestricted. **This has
not been verified by attempting a join** — it is stated here as the likely
explanation if a 5 GHz join fails, and as a reason to test with a 2.4 GHz
network first. The bench scan sees both: `ADAV_FRITZ_BOX_7390` and
`ADAV_Guest1` are 2.4 GHz; `Turmberg` and `ADAV_ASUS_RT_AC_66U_5GHZ` are 5 GHz.

It is deliberately **not** fixed the way the radio default was. Which country
this panel transmits under is a deployment and regulatory decision, not
something an image build should guess — Raspberry Pi OS leaves it to the user
for exactly that reason. The options, when the owner wants to decide: a
`board.conf` default baked per image flavour, or a country selector on the
Wi-Fi screen. The second is the better product answer and the more work.

What *is* confirmed is that the join path's dependencies survived the diet:
`wpasupplicant` 2:2.10-24 is installed and `wpa_supplicant` is on the image, so
WPA association has everything it needs.

### Release signing key custody

Stage 2b signs on the build side even though the device does not yet verify.
That ordering is the point: when Stage 4 enables device-side verification,
every release published since Stage 2b is already signed, so no migration
release is needed — and the §11 CM4 secure-boot path requires that a signing
process exist and be exercised long before any OTP fuse is burned.

The keypair lives **outside every git checkout**, by default at:

```
/etc/micropanel-touch/release-signing/ed25519-release.key      root, 0600
/etc/micropanel-touch/release-signing/ed25519-release.key.pub  root, 0644
```

`build-image.sh` creates it on first use and prints a custody notice;
`--signing-key=FILE` selects a different location. The public half is baked
into every A/B image at `/usr/lib/pi-ab-update/update-signing-key.pub`, so:

- **back the private key up offline before publishing anything with it.**
  Losing it means no already-flashed device will accept a future signed
  release, and recovery is a reflash;
- **changing the key changes the image contract.** Devices flashed with an
  older public key will reject the new key's releases once Stage 4 lands.

`packages/pi-ab-update/ab-release-key.sh` is the helper behind all of this (`ensure`, `key-path`, `public-path`, `sign`,
`verify`) and can be used directly to verify a published manifest.

### Where releases come from (OTA)

Every A/B image ships a root-owned
`/usr/lib/pi-ab-update/update-source.conf` holding the version-less
`MANIFEST_URL`, `MANIFEST_SIG_URL` and `BUNDLE_URL` for this variant, beside the
pinned release public key. It is rendered from
`MICROPANEL_TOUCH_RELEASE_URL_TEMPLATE` in `board.conf`, which is also the one
place that names the application/release repository — the builder resolves
`--app-ref` against it and both hook lists expand it. There is no second copy of
the repository URL anywhere.

`--release-url-template=URL` overrides it per build, with `@ASSET@` standing in
for the asset name. That is how an over-the-air update is rehearsed on the bench
before anything is published:

```sh
# 1. On the build host, serve a payload directory built with --payload:
packages/pi-ab-update/ab-serve-release.sh \
    ~/pi-image-workspace/out/micropanel-touch-luckfox-ctp-ab/payloads/<version> 8000

# 2. Build the *device* image so it asks this host instead of GitHub:
sudo ./build-image.sh --board=micropanel-touch --variant=luckfox-ctp \
    --version=<version> --layout=ab --app-ref=main \
    --release-url-template=http://<build-host-ip>:8000/@ASSET@
```

Plain HTTP is correct for a rehearsal and does not weaken the test: a release is
authenticated by a **raw ed25519 signature over its manifest**, verified against
the key pinned in the image, before any manifest field is parsed. The transport
is not a trust boundary, so an unauthenticated server cannot make a device accept
anything it would otherwise refuse. `ab-verify-image.sh` accepts an http source
but prints a notice; shipping images use the https default.

The same property is what makes the **offline deployment** work: there is no
certificate and no validity window in the signature path, so a panel that has
never reached an NTP server — and believes it is years in the past — still
verifies and installs a signed release from a USB stick. Only the *network*
route needs a roughly correct clock, and when TLS fails on a panel whose clock
was never set, the failure is reported as a clock problem rather than a network
one, because that is what an operator has to fix.

Signed **downgrades are permitted**: only an identical version is refused, so an
older signed release stays installable and rollback remains available.

An update streams directly into the inactive root partition, then reboots into
that candidate once. Do not remove power while the display says it is writing.
After candidate boot, the appliance waits for its HMI, broker, `/data`, and a
rendered first frame to remain healthy without an HMI restart for 30 seconds
before committing. If a candidate does not return, remove and reapply power: the
one-shot candidate is abandoned and the previously committed slot returns.
Every published payload must first complete a Pi 4 + Luckfox CTP bench boot
acceptance.

**Stream-stall policy (decision, 2026-08-18).** The rootfs write is the only
phase with no natural upper bound, so it detects its own stall: if the target
device has accepted no new bytes for `MICROPANEL_UPDATE_STALL_SECONDS`
(default 300) the handler aborts with `failed-stall` before anything is armed.
Every other phase remains covered by the existing 30-minute broker ceiling and
the systemd service-stop backstop; no second timer was added for them.

The static A/B contract check runs automatically during an A/B build's
preflight. The finalizer/verifier integration fixture remains a manual
pre-flash check and uses only a temporary loopback image:

```sh
packages/pi-ab-update/tests/test_ab_layout_static.sh
sudo packages/pi-ab-update/tests/test_ab_layout_integration.sh
```

The A/B engine and every one of its suites now live in
`packages/pi-ab-update/`. One command runs them all; the two loopback fixtures
need root and skip themselves without it:

```sh
sudo packages/pi-ab-update/tests/run-tests.sh
```

#### Stage 2b bench evidence — complete, 2026-08-19

A `00.25` A/B card accepted the published `00.26`
`micropanel-touch-luckfox-ctp.mpupdate` as the only file on an **unlabelled**
232.9 GB stick, in both **FAT32** and **exFAT**, in both directions, each time
committing after the 30-second candidate health window and surviving a physical
power-cycle. The app revision was `86dafcadd7b82d02072251d2ba3a8ef4b7451e2c`
and the bundle's ed25519 signature verified against the public key baked into
the running image.

All four refusal classes were exercised and stayed distinct: no media
(`failed-source`), media without a bundle and two bundles (`failed-payload`,
refusing rather than choosing), an already-installed version (`failed-version`,
decided after ~234 bytes of a 1.67 GB file), and a bundle with one changed
decompressed byte (`failed-integrity` after the full 5 GiB write, before
`e2label`, boot files, arm or reboot). Both power cuts passed: mid-write left
the target dirty and **unlabelled** and returned unattended to the committed
slot, and a cut after arm but before commit recorded `state=fallback`.

Two bench notes. The fixture's USB device reports `RM=0 HOTPLUG=0`, which is
why discovery keys on USB transport rather than the removable flag. And the
privileged broker's `PrivateTmp=yes` puts the handler's source mount in a
private mount namespace, so an SSH-side `mountpoint` check on
`/run/micropanel-touch-update/source` is meaningless — read
`/proc/<handler-pid>/mounts` instead.

#### Fix-forward re-check — complete, 2026-08-19

`00.27`/`00.28` (app revision `7c15e30780fb9c07ff00b36a992198f220063e42`) added
explicit failure classes to the two previously unguarded mounts on the USB
discovery path, and mirrored handler diagnostics into the root-only journal.
On the bench: no media reported `failed-source`, a stick without a bundle
reported `failed-payload`, and a normal `00.27`→`00.28` update from an
unlabelled exFAT stick committed as usual. The updater's diagnostics reach the
root-only journal under the tag `ab-system-update[micropanel-touch]` (the
engine tags itself with `AB_PRODUCT`), naming the cause of a refusal and
staying silent on a successful update:

```sh
sudo journalctl -t 'ab-system-update[micropanel-touch]' -b
```

Reading the updater back out of a built image and comparing it to the source is
a cheap check worth keeping. Since Stage 2c the updater is the shared engine,
so both paths changed:

```sh
sudo losetup --find --show --partscan --read-only <image>   # then mount p5 ro
sha256sum <mount>/usr/local/sbin/ab-system-update
sha256sum packages/pi-ab-update/ab-system-update            # must match
```

#### Latest Stage 2 bench evidence — complete, 2026-08-18

`misc-tools` commit `bde05af` generated the checksum-safe Luckfox CTP
payloads used for the Pi 4 bench acceptance. A `00.20` A/B card on A first
survived a power cut at approximately 35% of the `00.21` write, returning to A
without arming B. A fresh retry verified the full decompressed SHA-256,
completed device-side `e2fsck` plus relabel, booted and committed `00.21` on
B, and remained on B through a physical power-cycle. The committed B system
then updated and committed `00.22` on A, which also survived a physical
power-cycle.

The final negative-path tests used `00.22`. A valid-XZ rootfs with a changed
decompressed byte, while leaving the matching manifest and boot archive
unchanged, was refused as `failed-integrity` before selector arm or reboot;
normal A and one-shot B selectors remained intact. After restoring the valid
rootfs, B booted once as a candidate and power was cut after its first UI frame
but before the 30-second commit window. Ten seconds later the Pi booted A with
durable `state=fallback` for B, proving attended fallback recovery. HMI and
broker were active with no failed units. This completes Stage 2 hardware
acceptance for Pi 4 + Luckfox CTP; every published payload still requires a
bench boot test before release.

An independent post-acceptance revalidation performed two more committed
same-version `00.22` transitions (A→B and B→A). It rechecked the neutral-label
target mid-write in both directions and ended on committed A with candidate A;
this supersedes the earlier `fallback` snapshot as the live bench state while
retaining that snapshot as evidence for the deliberate power-cut case.

#### V4-hardened regression — normal update and power-cycle passed, 2026-08-18

A freshly flashed `00.23` card was built through `--app-ref=main`, which
resolved to `micropanel-touch` `07b261e645ef0f9498b9e2362c83eed1b2f5b034` and
was recorded in the installed manifest. The matching `00.24` USB payload
updated A→B, committed after the 30-second candidate health interval, and
remained committed on B through a physical power-cycle. The Pi verified the
V4 explicit failure-class handler, updater lock, and zero-HMI-restart commit
policy in the installed image, with HMI/broker active and no failed units.

This validates the V4 normal hardware path. The earlier Stage 2 negative and
recovery acceptance remains valid evidence; rerun its mid-write interruption,
corrupt-rootfs refusal, and post-arm/pre-commit fallback smoke cases on a new
version pair before claiming those V4 changes are fully hardware revalidated.
The `00.23`/`00.24` identifiers were reissued bench artifacts after the old
hook pin was discovered; do not reuse those version numbers again.

No extra runtime package is needed for `blkid`: it is already installed at
`/usr/sbin/blkid` (with `e2fsck` and `e2label`) and the root updater explicitly
adds `/usr/sbin` to `PATH`. An unprivileged interactive shell may not include
that directory, so use `sudo blkid` or `/usr/sbin/blkid` for manual diagnosis.

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
selector=/usr/local/sbin/ab-slot-selector
sudo "$selector" current-slot                 # must print A
sudo "$selector" arm-candidate B
sudo reboot "0 tryboot"
```

After SSH returns, confirm `current-slot` prints B, the HMI, broker,
machine-ID service and `/data` are healthy, then commit **from B**. The
selector intentionally rejects `commit B` while A is running.

```sh
selector=/usr/local/sbin/ab-slot-selector
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
`/usr/lib/pi-ab-update/boot-selector-config.base` before the image is built; an ad-hoc edit to p1 is overwritten by the next selector commit.
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
