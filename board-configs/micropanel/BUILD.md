# micropanel — build, release and update commands

The exact commands for the micropanel board, single-slot and A/B. The A/B
design and the persistence contract are in `PERSISTENCE.md`; the engine is
`packages/pi-ab-update/` (its README is the board contract).

> **Every real micropanel build uses `--skip-kernel`.** The kernel stamp tracks
> br-wrapper, which the sources stage pulls on every run; without the flag any
> br-wrapper commit triggers a ~45-minute kernel rebuild.

> **Status (2026-09-29):** A/B is opt-in (`--layout=ab`) and is on misc-tools
> `main` since 2026-09-29 (`feature/A-B-Update` fast-forwarded into it at
> `00a7bea`; the feature branch is kept for history only). Every repo it builds
> from is on its default branch: micropanel's A/B work (split boot
> configuration, HPD toggle, the no-SSD1306 ExecCondition) is on micropanel
> `main`, `hooks-ab.txt` clones `main` as `hooks.txt` does, and the System
> Manager app is on br-wrapper `main`. The system ships USB-only.

## Versions

**The shippable line starts at `2.00`, built from misc-tools `main` at or
after `00a7bea`** (the commit `main` was fast-forwarded to when the A/B work
was merged, 2026-09-29): **`2.00` (image + payload) is the first release and
`2.01` (payload) its first update.** Record the misc-tools SHA each release
was built from next to its version (§7); the image manifest records every
other source revision (`BR_WRAPPER_REVISION`, `MICROPANEL_REVISION`, ...).

**Everything built before the merge is retired**: the bench series
`02.00`-`02.06` and `2.00`-`2.07` as built from `feature/A-B-Update`. They
were bench builds only: none was published, every card that carried one has
been overwritten, and the artifacts are deleted. What they proved is in §7,
labelled with those (pre-merge) numbers; the defects they carried are in the
history of this section and in `tmp-docs/` (E1 `lsblk -o PARTN`, E2 the
commit-service ordering cycle, E3 the oneshot commit service, the
`fetch_terminated` diagnostic, the 20 s watchdog, E4 the reset during
writes, the refused candidate that stayed up).

**Why restarting at `2.00` is safe, once.** The engine's only version rule is
equality: it refuses a bundle whose version equals the running one and
offers any other, lower included. A reused number is therefore a problem
only on a device that runs the *old* build of that number, and there is none
known. The one real consequence: a device still running a pre-merge `2.00`
(or `2.01`) would refuse the new `2.00` (or `2.01`) as "already running this
version" and must be reflashed or given the next number. A device running a
pre-merge `2.02`-`2.07` would be offered `2.00`/`2.01` like any other
version.

**After this restart, never reissue a number** (`2.00`, `2.01`, `2.02`, ...):
a reissued number makes a same-version refusal of a different build
possible, and bench evidence ambiguous. (Single-slot keeps its own 01.xx
line.)

## Device tool baseline

The update engine runs on the device - here Debian 12 (bookworm): util-linux
2.38, coreutils 9.1, xz 5.4, curl 7.88, OpenSSL 3.0, tar 1.34, systemd 252.
micropanel-touch is trixie and the build host is newer still, so a tool flag
that works there proves nothing for this board. Any new device-side flag in
`packages/pi-ab-update/` or in this board's hooks is checked against that
list (the engine README, "Device tool baseline").

## 0. Test gates (before any build)

```sh
cd misc-tools
sh packages/pi-ab-update/tests/test_ab_layout_static.sh
sh board-configs/micropanel/tests/test_ab_layout_static.sh
sudo packages/pi-ab-update/tests/run-tests.sh          # all suites, loop fixtures as root
( cd ../micropanel && sh tests/test_pi_config_txt.sh )  # split boot configuration
```

## 1. Images

```sh
# Single-slot product (8 GB card), unchanged by A/B
sudo ./build-image.sh --board=micropanel --base-profile=qt-bookworm --version=01.xx --skip-kernel

# A/B image (16 GB card): 15,000 MiB, slot A populated, B and factory empty
./build-image.sh --board=micropanel --base-profile=qt-bookworm --layout=ab --version=02.xx --skip-kernel --dry-run
sudo ./build-image.sh --board=micropanel --base-profile=qt-bookworm --layout=ab --version=02.xx --skip-kernel
```

An A/B build takes about 63 minutes (the apps stage dominates). Its log must
show, in order: the `[appliance]` lines, `[slim] result: … (x3 = … MiB …)`,
`root copy: file copy (…)`, `Created A/B image layout …`, `A/B image layout
verified`. Output: `~/pi-image-workspace/out/micropanel-ab/<stem>-micropanel-ab-<ver>.img`.

The first A/B build creates the release signing key at
`/etc/micropanel/release-signing/` (root, 0700). **Back it up offline**; every
A/B image pins its public half and accepts nothing signed by another key:

```sh
sudo tar -C /etc -czf ~/micropanel-release-signing-$(date +%F).tgz micropanel/release-signing
sudo sha256sum /etc/micropanel/release-signing/ed25519-release.key.pub
```

## 2. Update payloads

`--payload` adds the signed bundle beside the image, in
`out/micropanel-ab/payloads/<ver>/`: `micropanel-base.mpupdate`,
`micropanel-base.manifest`, `micropanel-base.manifest.sig` (version-less names;
the version is inside the signed manifest).

```sh
sudo ./build-image.sh --board=micropanel --base-profile=qt-bookworm --layout=ab --version=02.xx --skip-kernel --payload

# Check a payload before shipping it
D=~/pi-image-workspace/out/micropanel-ab/payloads/02.xx
cat $D/micropanel-base.manifest
sudo packages/pi-ab-update/ab-release-key.sh verify $D/micropanel-base.manifest $D/micropanel-base.manifest.sig
tar -tf $D/micropanel-base.mpupdate                 # manifest manifest.sig boot.tar rootfs.img.xz
stat -c %s $D/micropanel-base.mpupdate              # < 2147483648 (GitHub per-asset ceiling)
```

(`ab-release-key.sh` finds the key through `AB_RELEASE_KEY_DIR`; run it as
`sudo AB_RELEASE_KEY_DIR=/etc/micropanel/release-signing …` when not invoked
by the builder.)

## 3. Publishing a release on GitHub (draft — not yet run)

The system ships USB-only for now; this recipe is part of the deferred online
path, planned in `docs/micropanel-sdcard-online-ab-update.md`.

The device fetches from `releases/latest/download/`, which skips drafts and
pre-releases: publish a normal release.

```sh
VER=02.xx
OUT=~/pi-image-workspace/out/micropanel-ab/payloads/$VER

gh release create "$VER" \
    --repo hackboxguy/micropanel \
    --title "micropanel $VER (A/B, pi4)" \
    --notes "A/B update payload for the Raspberry Pi 4 micropanel image." \
    "$OUT/micropanel-base.mpupdate" \
    "$OUT/micropanel-base.manifest" \
    "$OUT/micropanel-base.manifest.sig"
```

Verify it resolves the way a device will:

```sh
U=https://github.com/hackboxguy/micropanel/releases/latest/download
gh release view "$VER" --repo hackboxguy/micropanel \
    --json isDraft,isPrerelease,assets \
    --jq '{draft:.isDraft, prerelease:.isPrerelease, assets:[.assets[].name]}'
curl -fsSL "$U/micropanel-base.manifest"     -o /tmp/gh.manifest
curl -fsSL "$U/micropanel-base.manifest.sig" -o /tmp/gh.manifest.sig
sudo openssl pkeyutl -verify -pubin \
    -inkey /etc/micropanel/release-signing/ed25519-release.key.pub \
    -rawin -in /tmp/gh.manifest -sigfile /tmp/gh.manifest.sig
```

Expect `draft:false`, three assets, `Signature Verified Successfully`.
Removing one: `gh release delete "$VER" --repo hackboxguy/micropanel --yes --cleanup-tag`.

(The micropanel repo's GitHub releases are the release location by owner
decision; if micropanel's own single-slot releases ever use that repo too, a
`latest` A/B release would shadow them - decide before the first publish.)

## 4. Writing an image to an SD card

```sh
IMG=~/pi-image-workspace/out/micropanel-ab/<image>.img
sha256sum "$IMG"                                   # compare with the report / release notes
lsblk -dnp -o NAME,MODEL,SIZE,TRAN; DEV=/dev/sdX   # set it; never a system disk
[ "$(sudo blockdev --getsize64 $DEV)" -ge 15728640000 ] || echo 'card too small (A/B needs 16 GB)'
lsblk -np -o NAME,MOUNTPOINTS $DEV; sudo umount ${DEV}?* 2>/dev/null
sudo dd if="$IMG" of=$DEV bs=4M conv=fsync status=progress
sudo partprobe $DEV; lsblk -o NAME,LABEL,SIZE $DEV # MP_BOOT_A MP_BOOT_B MP_ROOT_A MP_ROOT_B MP_FACTORY MICROPANEL_DATA
sudo mount -o ro ${DEV}5 /mnt && grep -E 'IMAGE_VERSION|MICROPANEL_REVISION' /mnt/home/pi/micropanel/share/micropanel/image-manifest.env; sudo umount /mnt
```

Read back by partition number: another card on the build host may carry the
same labels.

## 5. Over-the-air rehearsal (without publishing)

The image keeps its production release URL; the device's front end takes a
bench override for one command (`--source-config`, a root-owned regular file,
never a symlink):

```sh
# On the build host (192.168.1.80 on the bench LAN), from misc-tools/
packages/pi-ab-update/ab-serve-release.sh ~/pi-image-workspace/out/micropanel-ab/payloads/<ver> 8000
for a in micropanel-base.manifest micropanel-base.manifest.sig micropanel-base.mpupdate; do
    curl -fsI "http://192.168.1.80:8000/$a" | head -1        # 200 each
done

# On the device (it must reach 192.168.1.80:8000; open the port on the host firewall)
sudo install -d -m0700 /data/ab-bundles
printf '%s\n' \
    'MANIFEST_URL=http://192.168.1.80:8000/micropanel-base.manifest' \
    'MANIFEST_SIG_URL=http://192.168.1.80:8000/micropanel-base.manifest.sig' \
    'BUNDLE_URL=http://192.168.1.80:8000/micropanel-base.mpupdate' \
    | sudo tee /data/ab-bundles/bench-source.conf >/dev/null
sudo ab-update check --source-config=/data/ab-bundles/bench-source.conf
sudo ab-update install ota --source-config=/data/ab-bundles/bench-source.conf
```

`ab-update` exports the file as `AB_SOURCE_CONFIG`; `ab-update-check` and
`ab-system-update` both read it through `ab_setting`, where the environment
wins. The alternative is an image built to ask the bench host
(`--release-url-template=http://192.168.1.80:8000/@ASSET@`; the verifier prints
a plain-http NOTICE for it) - but then the tested image is not the shipped one.

Authenticity comes from the pinned key, not the transport, so plain http is a
faithful rehearsal. A shipping image points at https (the board default).

## 6. On the device

```sh
sudo ab-update                    # status: version, slot, inactive slot, state, health units
sudo ab-update check              # ask the release source (manifest + signature only)
sudo ab-update install ota        # from the configured release source
sudo ab-update install usb        # exactly one .mpupdate on a FAT32, exFAT or NTFS stick
sudo ab-update watch              # progress until it settles
sudo ab-update log 60             # engine + commit journal
ab-update --state; ab-update --active-slot; ab-update --active-version
sudo ab-factory-reset             # wipes /data, reseeds, reboots (asks at a terminal)
```

After an install the device reboots once into the other slot (`tryboot`).
`ab-update-commit` commits it when every health unit (`AB_HEALTH_UNITS` in
`/usr/lib/pi-ab-update/ab-update.conf`, today `qt-demo-launcher.service`) stays
active with no restarts for 30 s. Otherwise the next reboot or power-cycle
returns to the committed slot and the state reads `fallback`.

The display type (`/boot/firmware/micropanel-display.txt`) is device-owned
and survives updates and factory resets.

`micropanel.service` **inactive** is expected on a head-unit board (no SSD1306
on i2c-3, no USB dongle): its `ExecCondition=` skips it for that boot
(`systemctl status micropanel` says "Skipped due to 'exec-condition'"). It is
not a fault, and not a health unit. See PERSISTENCE.md, "Update health".

## 7. Acceptance records

From the bench reports (reviewer on the OTS-OLED head-unit rig, over SSH;
power cuts by a Tasmota plug). Every version in the rows up to the 2.06/2.07
bench is a **pre-merge** bench build (§Versions); rows for the release line
say "post-merge" and the misc-tools SHA. Commits are by `ab-update-commit` alone, times
after boot; each logged
`[SUCCESS] committed candidate slot <X> after 30 seconds of health`.

| Item | Result | Date | Image |
| --- | --- | --- | --- |
| S1 overlay + initramfs + drivers | pass (reviewer, live) | 2026-09-28 | 02.00 |
| S2 `include` under `os_prefix` | pass (reviewer, live) | 2026-09-28 | 02.00 |
| S3 derive unit; B1 single probe, panel up unaided | pass | 2026-09-28 | 02.01 |
| E1 first install attempt | refused: `lsblk: unknown column: PARTN` (fixed in 02.05) | 2026-09-28 | 02.01 |
| USB install 02.05 -> 02.06 | written, armed, booted B; commit never ran (E2, fixed in 2.00) | 2026-09-28 | 02.05 |
| USB install 02.06 -> 2.00, OTA 2.00 -> 2.01 (`--source-config`) | written, armed, booted; commit service ran (E2 fixed) but gave up after 120 s (E3); manual commit worked | 2026-09-28 | 2.00, 2.01 |
| Fallback (health window not met) | OTA 2.05 -> candidate B; `systemctl stop qt-demo-launcher` at 34 s: the service refused at 25.9 s of its window, `not committing candidate slot B: health lost in the settle window: health unit qt-demo-launcher.service is not active`, exit 0 - and the device **stayed up on the candidate** (`candidate-armed`, 7 min) until a manual reboot (fixed in pi-ab-update `27e3e3e`: a refused candidate reboots). After the reboot: back on A/2.04, tryboot flag 0, `state=fallback version=2.05 candidate_slot=B` (the `normal-slot` rule), badge *Update rolled back*; System Manager opened on the image tab wrote `acknowledged-fallback` (`version=2.05`), badge then *Update available* | 2026-09-29 | 2.04 -> 2.05 |
| USB update + commit | 2.01 -> 2.02 from an NTFS stick (`ntfs3`), B -> A: written in ~3 min, armed; committed at 49.9 s | 2026-09-29 | 2.01 -> 2.02 |
| OTA update + commit | 2.02 -> 2.03 from the bench server (`--source-config`), A -> B: committed at 48.0 s | 2026-09-29 | 2.02 -> 2.03 |
| Downgrade | signed 2.02 from USB on 2.03, B -> A: committed at 50.0 s | 2026-09-29 | 2.03 -> 2.02 |
| Power cut mid-write | cut at `writing 40 %` of OTA 2.03: back on committed A/2.02 unattended, tryboot flag 0, `state=committed`, `get_rsts=1000` (power-on reset), no lock, `/run/ab-update` clean, torn B untouched by the selector; the same install then committed on B at 48.0 s | 2026-09-29 | 2.02 -> 2.03 |
| Integrity refusal | byte flipped in `rootfs.img.xz`: `xz: Compressed data is corrupt` -> `[ERROR] root filesystem stream failed`, `failed-integrity`, nothing armed, rc 1. In `boot.tar`: `payload boot archive digest does not match its manifest` in 1 s, `failed-integrity`, nothing armed. (Both also printed the `line 187` diagnostic, fixed in 2.04.) | 2026-09-29 | 2.02 |
| System Manager offer + install (offscreen) | offer card correct (running 2.03 on B committed; 2.02 on `/dev/sda1`, signed with this device's key); lock held by the PID, lock and mounts gone after the reboot | 2026-09-29 | 2.03 |
| System Manager `--auto-install`, twice | **board reset at ~50 % written both times** (66 s, 81 s into `writing`; `get_rsts=0x20`), back on committed B/2.03, nothing armed - E4; closed in 2.04 (three passes, row "System Manager `--auto-install` 2.04, three passes") | 2026-09-29 | 2.03 -> 2.02 |
| OTA update + commit on 2.04 | 2.03/B -> 2.04/A: committed at 47.9 s. `micropanel.service` inactive, `Result=exec-condition`, `NRestarts=0`, one "standing down" line; `vm.dirty_ratio` back to 20 after the install; `RuntimeWatchdogUSec=1min`; debug mirrors current (`.dmesg` to the second, `.sample` every 5 s, `.late` at 96 s) | 2026-09-29 | 2.03 -> 2.04 |
| Integrity refusal on 2.04 | byte flipped in `boot.tar`: `failed-integrity`, rc 1, **no shell diagnostic** (the `line 187` one is gone), dirty limits restored, saved-limits file removed | 2026-09-29 | 2.04 |
| OTA 2.05 | 2.04/A -> 2.05/B: committed at 50.0 s; `dirty_kb` <= 15 MB through the ~150 s write | 2026-09-29 | 2.04 -> 2.05 |
| System Manager `--auto-install` 2.04, three passes | from the NTFS stick, with OTA 2.05 return trips between them: **all three committed** at 47.8 / 47.9 / 48.0 s, **no reset** (the same operation reset the board twice on 2.03); return trips committed at 47.8 / 48.0 s | 2026-09-29 | 2.05 -> 2.04 |
| Factory reset + reseed | fresh 2.04 card, `ab-factory-reset --yes`: reset requested, reboot, the early service wiped and reseeded `/data` (marker gone, skeleton back, NetworkManager profile reseeded), display type kept, machine-id regenerated, no failed unit, back up unaided | 2026-09-29 | 2.04 (fresh card) |
| Fresh card: OTA, then System Manager USB | OTA 2.05 -> B committed at 48.0 s; System Manager USB 2.04 -> A committed at 49.8 s; the app's run log carries the 10 % milestones (br-wrapper `0f73290`) | 2026-09-29 | 2.04 -> 2.05 -> 2.04 |
| Refusal reboot on hardware | old card on A/2.04, OTA 2.06 -> candidate B, `systemctl stop qt-demo-launcher` at 25 s: the 2.06 commit service refused (`health lost in the settle window: ... not active`) and **rebooted by itself**; back on A/2.04 within 30 s, tryboot flag 0, `state=fallback version=2.06 candidate_slot=B`, `update-refusal` written with the reason (`--refused-reason` unknown to the 2.04 slot, as expected: the fallback slot's engine publishes it) | 2026-09-29 | 2.04 -> 2.06 |
| Refusal record cleared by a 2.06+ arm | OTA 2.06 again (armed by the 2.04 installer): committed on B at 47.9 s, the record stayed; OTA 2.07 (armed by the 2.06 installer): committed on A at 47.0 s and **the arm removed `update-refusal`**; `dirty_ratio` 20 afterwards | 2026-09-29 | 2.04 -> 2.06 -> 2.07 |
| System Manager `--auto-install`, three passes on the 2.07 engine | 2.04 on the stick, OTA 2.07 return trips: committed at 50.0 / 48.0 / 48.0 s, return trips 47.9 / 47.9 s; no reset, no lock left | 2026-09-29 | 2.07 -> 2.04 -> 2.07 |
| ssh host keys across slot switches | identical fingerprint before and after a reboot that also switched slots (restore unit before sshd, regenerators masked); keys change only on a fresh flash or a factory reset | 2026-09-29 | 2.06/2.07 |
| Fresh 2.06 card | `sudo ab-update` shows **no check section**; the app offers the stick's 2.07 with the signature line and *Hold to install*; badge *Image update on USB*; `ab-factory-reset --yes` wiped and reseeded `/data` (marker gone), display type kept, back up unaided | 2026-09-29 | 2.06 (fresh card) |
| **Hand-held install on the panel, Ethernet unplugged** (owner) | *Hold to install* -> 2.07 written, verified, armed, rebooted; **committed on B at 48.8 s**; app log complete (`exit 0`), no lock, no mount; the section reads *Running 2.07 (committed)* and the stick *Already running this version* | 2026-09-29 | 2.06 -> 2.07 |
