# micropanel SD-card A/B update — how it works, and how to build images and bundles

For whoever maintains this next, human or a fresh Fable/Opus session. This is
the map; the exact commands live in `board-configs/micropanel/BUILD.md`, the
persistence inventory in `board-configs/micropanel/PERSISTENCE.md`, and the
engine's contract in `packages/pi-ab-update/README.md`. Read those three
after this one. Status as of 2026-09-29 is at the end.

## 1. What the owner gets

A micropanel image flashed to a 16 GB card that can replace its own operating
system from a USB stick (and, later, over the network) without removing the
card. The device writes the new system into a second, inactive slot, boots
it once, and keeps it only if the application comes up and stays up; any
failure (bad payload, power cut mid-write, application not starting) leaves
the device on the system it had. Device state under `/data` is never part of
an update. A factory reset wipes `/data` and reseeds it from the image.

The default single-slot 8 GB image (`01.xx`) is untouched by all of this; A/B
is opt-in with `--layout=ab` and has its own `2.xx` version line.

## 2. The card layout

MBR, six used partitions, labels fixed by the engine (never rename them):

| Partition | Label | Size | Content |
|---|---|---|---|
| p1 | `MP_BOOT_A` | 256 MiB | firmware boot files, slot A's kernel tree under `A/`, slot B's under `B/`; `config.txt` (the selector's), `tryboot.txt`, `micropanel-display.txt` (device-owned) |
| p2 | `MP_BOOT_B` | 256 MiB | reserved (the firmware boots p1 only) |
| p3 | extended | | container |
| p5 | `MP_ROOT_A` | 5120 MiB | root filesystem, slot A |
| p6 | `MP_ROOT_B` | 5120 MiB | root filesystem, slot B (empty on a fresh flash) |
| p7 | `MP_FACTORY` | 2048 MiB | reserved for a factory image (empty today) |
| p8 | `MICROPANEL_DATA` | rest | `/data`, the only durable write target |

Sizes freeze at first flash: a bundle must fit the slot of every card in the
field, so `AB_ROOT_PARTITION_MB` and `AB_BOOT_PARTITION_MB` in `board.conf`
are not to be changed casually. The authored root is about 6.5 GiB, larger
than the slot: the finalizer file-copies it into a fresh ext4 (with the
source's own feature set), which is why `board.conf` carries an image diet
(`IMAGE_SLIM_HOOK_ab`, `slim-remove.txt`, ceiling `SLIM_MAX_ROOT_MB_ab`).
The measured root after slimming is about 3.0 GiB; the boot tree is pruned
to about 53 MiB so three copies fit p1.

## 3. How a boot chooses a slot

The Raspberry Pi firmware reads `config.txt` on p1. Its first line is
`os_prefix=A/` or `os_prefix=B/`, so the kernel, initramfs and overlays come
from that directory, and the kernel command line names the matching root by
label (`root=LABEL=MP_ROOT_A`, with `overlayroot=tmpfs:recurse=0` so the
root is read-only under a tmpfs overlay; the lower root is visible at
`/media/root-ro`). `tryboot.txt` is the same file for the other slot.

The one-shot mechanism is the firmware's `tryboot`: `reboot "0 tryboot"`
boots `tryboot.txt` exactly once; the next reboot or power cut boots
`config.txt` again. So:

- **arm** = write `tryboot.txt` for the candidate slot and reboot with the
  tryboot flag (`ab-slot-selector arm-candidate`);
- **commit** = rewrite `config.txt` to select the running candidate, after
  first rewriting `tryboot.txt` to select the other slot, so a complete
  fallback selector exists at every instant (`ab-slot-selector commit`,
  refused unless the slot named is the one running);
- **fallback** = do nothing: any reboot returns to `config.txt`'s slot.

The device tree exposes whether the current boot is a tryboot
(`/proc/device-tree/chosen/bootloader/tryboot`, 1 on a candidate boot).

The display configuration (`micropanel-display.txt`, chosen by DIP switch at
runtime) is *included* by the selector's `config.txt`, so a commit never
loses it, and micropanel's `pi-config-txt.sh` is redirected to that file
by `/etc/default/micropanel` (`MICROPANEL_BOOT_CONFIG`). `config-base.txt.in`
in the micropanel repo is untouched; the A/B base is derived from it with
`pi-config-txt.sh --emit-base`.

## 4. The update engine on the device (`packages/pi-ab-update/`)

Installed by the finalizer into every image, board-agnostic, configured by
one board file at `/usr/lib/pi-ab-update/ab-update.conf` (authored as
`board-configs/micropanel/ab-update.conf`, strict `KEY=value`).

| On the device | Role |
|---|---|
| `ab-update` (`/usr/local/bin`) | front door, composes and never decides. Commands: `status` (default), `check`, `install usb\|ota\|--file=PATH`, `watch`, `log [N]`. One-line queries: `--active-version`, `--active-slot`, `--active-partition`, `--active-revision`, `--inactive-version` (root), `--inactive-partition`, `--state`/`--update-state`, `--check-state`, `--progress`, `--refused-reason`. Option `--source-config=FILE` (bench OTA source). `install` needs root |
| `ab-system-update` | the installer, sources `usb`, `ota`, `stdin` (`--file=` feeds `stdin`). In order: `validating` (lock, tools, running image); `scanning` (USB: exactly one `.mpupdate` at the top of a FAT32/exFAT/NTFS stick) or `fetching` (OTA: `update-source.conf`); the manifest's ed25519 signature is verified before the manifest is parsed; version (must differ from the running one), board and variant checks; `boot.tar` is staged and its digest checked *before anything is written*; `preparing` (the target's superblock cleared); `writing` (`rootfs.img.xz` streamed into the inactive root, digest computed on the way, dirty page cache bounded to 16/8 MiB); root digest checked; `checking` (e2fsck, then the slot label); `boot-files` (`boot.tar` into the inactive boot directory); `arming`; reboot with the tryboot flag |
| `ab-slot-selector` | `current-slot`, `normal-slot`, `render-normal`, `render-candidate`, `arm-candidate`, `commit` (the `os_prefix` protocol above) |
| `ab-update-commit` + `.service` | on every boot. On a candidate boot: wait up to `AB_COMMIT_WAIT_SECONDS` (120) for the health units (`AB_HEALTH_UNITS`, today `qt-demo-launcher.service`) to be active, then `AB_SETTLE_SECONDS` (30) with none restarted and `/data` writable, then commit. A refusal is logged with its reason, recorded in `update-refusal`, and (since pi-ab-update `27e3e3e`, `AB_ON_REFUSAL=reboot`) the device reboots to the committed slot at once. `Type=exec` so it never holds `multi-user.target` back. On a normal boot: records `fallback` when the durable state says a candidate was armed but another slot is running, or `committed` when the candidate is running as the normal slot (committed out of band) |
| `ab-update-check` | fetches only manifest + signature from the release source, verifies, publishes `checking`, then `available` or `up-to-date` with the version, or the failure (`network`, `clock`, `signature`, `payload`, `compatibility`, `image`, `internal`) |
| `ab-factory-reset`, `ab-factory-reset-boot` + `.service` | marker now, wipe on the next boot before any consumer of `/data`, reseed with the same skeleton the image build used |

Telemetry for a UI: `/run/ab-update/progress` (`phase=`, `progress=`; phases
in order `validating`, `scanning` or `fetching`, `preparing`, `writing`,
`checking`, `boot-files`, `arming`, or `failed-<class>`),
`/run/ab-update/status` (`state=committed|candidate-armed|fallback`,
`version=`, `candidate_slot=`, and `refused_reason=` on a fallback the commit
service refused), `/run/ab-update/check`. Durable, root-only:
`/data/micropanel-system/update-state` (exactly `state`, `candidate_slot`,
`version`, `variant` - never add a key: after a fallback the *older* image's
commit service reads this file, strictly) and `update-refusal` beside it.

Failure classes (`phase=failed-<class>`), none of which arms anything:
`source` (no stick, or none mountable), `payload` (zero or several bundles, a
malformed bundle or manifest), `signature`, `compatibility` (other board or
variant), `version` (already running this version), `integrity` (a digest
mismatch; a corrupt or torn stream), `stall` (the write stopped progressing
for `AB_STALL_SECONDS`), `target`, `selector`, `boot`, `image` (device-side
problems preparing the other slot, or the running image's own manifest),
`internal`, and on the OTA path only `network` and `clock`. System Manager
maps each to a title and a next step (br-wrapper `SystemImageController.cpp`).

The signing: a raw ed25519 signature over the manifest, key pinned in the
image at `/usr/lib/pi-ab-update/update-signing-key.pub`. Private half on the
build host at `/etc/micropanel/release-signing/` (root, 0700; created by the
first A/B build). **Back it up offline** — a lost key means every fielded
device only accepts a reflash. Public key sha256 today: `8366036e…637324`.

## 5. The bundle (`.mpupdate`)

A plain ustar archive, `format=2`, members in this order: `manifest`,
`manifest.sig`, `boot.tar`, `rootfs.img.xz`. Asset names are version-less by
contract (`micropanel-base.mpupdate`, `.manifest`, `.manifest.sig`); the
version is inside the signed manifest:

```
version=2.05
variant=base
boards=pi4
rootfs_sha256=…   rootfs_bytes=5368709120
boot_sha256=…
format=2
```

The engine refuses a bundle whose version equals the running one, and
accepts a lower one (a signed downgrade is a legitimate recovery). Bundles
are ~790 MB.

## 6. What the board adds (`board-configs/micropanel/`)

- `board.conf`, the `A/B` block: sizes, `AB_PRODUCT`, the release key dir,
  `AB_RELEASE_URL_TEMPLATE`, and the `VAR_ab` overrides (`RUNTIME_DEPS_ab`,
  `HOOK_LIST_ab=hooks-ab.txt`, `POST_IMAGE_HOOK_ab` = the finalizer,
  `IMAGE_SLIM_HOOK_ab`). Nothing here changes the single-slot build.
- `hooks-ab.txt` = `hooks.txt` plus `packages/micropanel-appliance-hook.sh`,
  which converts the Pi OS root into an appliance: overlayroot + initramfs
  for the custom kernel (config extracted from the kernel's own
  `configs.ko`), `/data` bind mounts (`micropanel-appliance-hook.d/fstab.binds`),
  machine-id and ssh-host-key restore units, display-driver derive unit and
  autoload blacklist, the debug-journal unit, and the removal of the Pi OS
  first-boot services. Everything in `micropanel-appliance-hook.d/` is copied
  into the chroot as `HOOK_SUPPORT_DIR` and stamped like the hook.
- `micropanel-data-skeleton.sh`: the `/data` layout (installed on the device
  as `/usr/local/sbin/ab-data-skeleton` for the factory reset).
- `ab-update.conf`, `ab-assertions.sh` (build-time checks of the authored
  root), `micropanel-slim.sh` + `slim-remove.txt`, `runtime-deps-ab.txt`.
- `tests/test_ab_layout_static.sh`: the board's static gate (pins every
  decision above; run it before any build).

Pieces in other repos: micropanel `main` carries the split boot
configuration (`pi-config-txt.sh --emit-base/--apply-derived`, GPIO22 as
`gpio=22=ip,pu`, the HPD toggle after a serializer reload) and
`micropanel.service`'s `ExecCondition` (`micropanel-oled-present.sh`: no
SSD1306 means a 983HH head-unit board, the OLED menu stands down until the
next boot). br-wrapper `main` carries the System Manager app's "System
image" section (USB scan, hold-to-install, progress, rolled-back notice,
`--screenshot` and `--auto-install` for unattended checks).

## 7. Building

Everything from `misc-tools/` on the build host, as in `BUILD.md`:

```sh
# gates, every time
sh packages/pi-ab-update/tests/test_ab_layout_static.sh
sh board-configs/micropanel/tests/test_ab_layout_static.sh
sudo packages/pi-ab-update/tests/run-tests.sh
( cd ../micropanel && sh tests/test_pi_config_txt.sh && sh tests/test_micropanel_service.sh )

# image + bundle of one version (about 65 min; the apps stage dominates)
./build-image.sh --board=micropanel --base-profile=qt-bookworm --layout=ab --version=2.xx --skip-kernel --payload --dry-run
sudo ./build-image.sh --board=micropanel --base-profile=qt-bookworm --layout=ab --version=2.xx --skip-kernel --payload
```

Outputs: `~/pi-image-workspace/out/micropanel-ab/<stem>-micropanel-ab-2.xx.img`
(15,000 MiB) and `…/payloads/2.xx/micropanel-base.{mpupdate,manifest,manifest.sig}`.
The build log must show `[slim] result`, `root copy: file copy`, `Created
A/B image layout`, `A/B image layout verified`. `ab-verify-image.sh` runs
inside the build; `BUILD.md` §2 shows how to check a payload by hand.

Rules that bit before:

- **Always `--skip-kernel`**: the sources stage pulls br-wrapper every run
  and any commit there would trigger a 45-minute kernel rebuild.
- **Never reissue a version number.** The engine refuses same-version
  installs, and bench evidence becomes ambiguous. Burned numbers are listed
  in `BUILD.md` §Versions.
- A build that finishes in minutes rebuilt nothing (stamps). The apps stamp
  includes the engine files, the hook support dirs, the release URL and the
  remote revision of every git hook — a push to micropanel or br-wrapper
  re-triggers the apps stage by design.
- Two builds of the same misc-tools commit can carry different br-wrapper
  or micropanel revisions (cloned at build time). The image manifest
  (`/home/pi/micropanel/share/micropanel/image-manifest.env`) records every
  source revision; quote it in release notes.
- The device is bookworm (util-linux 2.38, systemd 252, mawk): a tool flag
  that works on the build host or on the trixie touch board proves nothing.
  `lsblk -o PARTN` and awk on a live pipe both failed this way.

An image + a bundle for the next version is two builds: the image build
(`--payload` gives you its bundle too) for a version people will flash, and
a payload-only version after it so a device has something newer to install.
Today's pair is 2.06 (image + bundle) and 2.07 (bundle), pending their
bench; 2.04/2.05 passed theirs (`BUILD.md` §Versions).

## 8. Flashing, updating, resetting (device side)

`BUILD.md` §4 for `dd` and the read-back. On the device:

```sh
sudo ab-update                       # status
sudo ab-update install usb           # one .mpupdate at the top of a FAT32/exFAT/NTFS stick
sudo ab-update install --file=/path  # a bundle already on the device
sudo ab-update watch                 # progress; the device reboots by itself
ab-update --state; ab-update --active-slot; ab-update --active-version
sudo ab-factory-reset                # asks, then reboots; --yes for scripts
```

Through the UI: System Manager → *System image*: the stick's bundle is
offered with its signature status, *Hold to install*, progress, then the
reboot; after a candidate boot the section says *Running X (committed)*, or
*Update rolled back* with the version that did not pass. Head-unit boards
without a touch panel can be driven the same way over ssh as user `pi`:

```sh
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software XDG_RUNTIME_DIR=/tmp/runtime-root-pi
/home/pi/micropanel/bin/system-manager-app --section image --screenshot /tmp/s.png --window-size 1920x720
/home/pi/micropanel/bin/system-manager-app --section image --auto-install   # installs what a scan offers
```

Timings measured on the bench (2.04/2.05, Pi 4, class-10 card): write
~150 s, reboot to launcher ~15 s, commit at ~48 s after boot.

## 9. Bench

The reference rig is the OTS-OLED head unit (Pi 4 + 983HH adapter, no
SSD1306) at `192.168.1.167` (user `pi`, the image password), on a Tasmota
socket at `192.168.1.41` (`/cm?cmnd=Power%20Off|On`) for power cuts. Set the
marker `/data/micropanel-system/debug/enabled` and the debug-journal unit
mirrors the kernel log, the journal and a 5 s sampler to
`/data/micropanel-system/debug/boot-NNNN-*` (readable after a reset).

An OTA rehearsal without publishing anything uses `ab-serve-release.sh` on
the build host and `ab-update check|install ota --source-config=FILE` on the
device (`BUILD.md` §5). The acceptance records of every bench so far are
`BUILD.md` §7.

Things learned that are not obvious from the code:

- A commit-service unit must never be `After=` its health units (ordering
  cycle) and must not be a oneshot in `multi-user.target` (holds the target
  back from the application). Both were found on hardware.
- A refused candidate (health unit down) used to be logged and left running
  until some later reboot rolled it back (up to 2.05). From pi-ab-update
  `27e3e3e` it reboots to the committed slot at once and the reason is shown
  with the fallback (`ab-update --refused-reason`). The *fallback* slot's
  engine publishes the reason, so an image older than that change shows the
  fallback without it.
- Fixtures reboot nothing: every engine script that reboots takes
  `AB_REBOOT_COMMAND`, and the suites run as root - a new test that reaches a
  reboot path without that seam would reboot the build host.
- The engine is shared: `board-configs/micropanel-touch` uses the same
  `packages/pi-ab-update`, and `packages/pi-ab-update/tests/test_ab_layout_static.sh`
  is touch's board static test. An engine change is a touch change too.
- The system ships USB-only (owner, 2026-09-29): nothing on the device needs
  the network, and `ab-update status` says nothing about a release source until
  a check has run. The handler fixture's FAT32 case runs with a tripwire curl.
- Rig access: key login is not set up; ssh as `pi` with the image password
  (`DEFAULT_PASSWORD` in `base-configs/qt-bookworm/profile.conf`). A reflash
  changes the host key. i2c-tools live in `/usr/sbin`, outside `pi`'s PATH.
- The board reset twice mid-write on 2.03 while PID 1 was busy with the
  OLED unit's restart loop and the dirty cache held ~1 GB; the dirty bound,
  the 60 s runtime watchdog and the standing-down unit closed it (three
  passes on 2.04, none since).
- The tool-output gotcha for whoever automates the bench: a torn log file
  ends in NUL bytes; strip them before printing.

## 10. Working on it with a fresh Fable/Opus session

The effort ran as a loop: a reviewer session writes
`tmp-docs/micropanel-ota-update-prompt-vN.md` (one step, with a hazards
list), an implementer session does it and writes `…-report-vN.md`, the
reviewer checks the report against the code, re-runs the gates, benches on
the rig and writes the next prompt. Eleven rounds so far; the prompts and
reports are the history of every decision, and `CLAUDE.md` holds the
build-system traps. A new session should start with `CLAUDE.md`, this file,
`BUILD.md`, `PERSISTENCE.md`, the engine README, and the last report.

Branch state (2026-09-29): misc-tools A/B work is on `feature/A-B-Update`
(the owner merges to `main` when they decide); micropanel and br-wrapper are
on their `main`. `hooks-ab.txt` and `hooks.txt` both clone micropanel
`main`.

Open items at the time of writing: online updates (deferred by the owner;
see `micropanel-sdcard-online-ab-update.md`); the factory partition p7 is
allocated but unused; merging misc-tools to `main` (the owner's call);
System Manager could name `refused_reason=` on its rolled-back line
(br-wrapper).
