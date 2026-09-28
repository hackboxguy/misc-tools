# micropanel — build, release and update commands

The exact commands for the micropanel board, single-slot and A/B. The A/B
design and the persistence contract are in `PERSISTENCE.md`; the engine is
`packages/pi-ab-update/` (its README is the board contract).

> **Every real micropanel build uses `--skip-kernel`.** The kernel stamp tracks
> br-wrapper, which the sources stage pulls on every run; without the flag any
> br-wrapper commit triggers a ~45-minute kernel rebuild.

> **Status (2026-09-28):** A/B is opt-in (`--layout=ab`) and lives on the
> `feature/A-B-Update` branch of both misc-tools and micropanel. `hooks-ab.txt`
> clones micropanel `feature/A-B-Update`; flip it back to `main` when the split
> boot configuration lands there. This file is started in Step 6 and completed
> in Step 7.

## Versions

**The bench series 02.00-02.06 is burned: never flash, publish or reuse those
numbers.** 02.00-02.04 carry an updater that cannot resolve its slot on
bookworm (E1: `lsblk -o PARTN`, util-linux 2.40+; pi-ab-update `50dd082`), and
all of 02.00-02.06 carry the commit-service ordering cycle that stops any
candidate from committing or recording a fallback (E2: pi-ab-update `4df206a`).

The **release baseline** starts at `2.00` (image + payload) and `2.01`
(payload), built with the production release URL (no
`--release-url-template`), so the bench-tested image is byte for byte the
shippable one. Pending the bench, `2.00` is the first shippable image and
`2.01` the first bundle; a later fix becomes `2.02`, `2.03`, ... Version numbers
are never reissued: the engine refuses an update whose version equals the
running one, and a reissued number makes bench evidence ambiguous.
(Single-slot keeps its own 01.xx line.)

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

## 7. Acceptance records

Placeholders; Step 7 fills them from the bench reports.

| Item | Result | Date | Image |
| --- | --- | --- | --- |
| S1 overlay + initramfs + drivers | pass (reviewer, live) | 2026-09-28 | 02.00 |
| S2 `include` under `os_prefix` | pass (reviewer, live) | 2026-09-28 | 02.00 |
| S3 derive unit; B1 single probe, panel up unaided | pass | 2026-09-28 | 02.01 |
| E1 first install attempt | refused: `lsblk: unknown column: PARTN` (fixed in 02.05) | 2026-09-28 | 02.01 |
| USB install 02.05 -> 02.06 | written, armed, booted B; commit never ran (E2, fixed in 2.00) | 2026-09-28 | 02.05 |
| Fallback (health window not met) | | | |
| USB update + commit | | | |
| OTA update + commit | | | |
| Downgrade | | | |
| Power cut mid-write | | | |
| Integrity refusal | | | |
| Factory reset + reseed | | | |
