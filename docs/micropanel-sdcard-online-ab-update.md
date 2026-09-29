# micropanel SD-card A/B update — plan for online (over-the-air) updates

The A/B system ships USB-only for now (owner decision, 2026-09-29). This is
the plan for switching on the network path later. Most of it already exists
in the engine and was rehearsed on the bench against a local HTTP server;
what remains is publishing, the UI, and a few operational decisions. Read
`micropanel-sdcard-ab-update.md` first for how the offline system works.

## 1. What already works

- **Release source in the image.** Every A/B image carries
  `/usr/lib/pi-ab-update/update-source.conf` with three URLs derived from
  `AB_RELEASE_URL_TEMPLATE` in `board.conf`, today
  `https://github.com/hackboxguy/micropanel/releases/latest/download/@ASSET@`
  with the version-less asset names `micropanel-base.manifest`,
  `micropanel-base.manifest.sig`, `micropanel-base.mpupdate`. Images 2.04
  and 2.05 already point there. Nothing on a device changes when the first
  release is published.
- **The check.** `sudo ab-update check` downloads the manifest and its
  signature only (a few hundred bytes), verifies the ed25519 signature
  against the pinned key, compares versions, and publishes
  `/run/ab-update/check` (`state=available version=2.05` or `up-to-date`).
  A same-version release is "up to date"; a lower one is offered like any
  other version (`update available: 2.04 (running 2.05)`), because rollback
  is a recovery path — a UI that wants to label it a downgrade compares the
  versions itself. Network failures are classed `failed-network`, with curl's own
  first line in the root-only journal; a TLS failure on a device whose
  clock never synced (no RTC) is named as a clock problem, not a
  certificate problem.
- **The install.** `sudo ab-update install ota` streams the bundle straight
  into the inactive slot (no staging copy, so no free-space requirement on
  `/data`), verifies, arms, reboots; the candidate commits or falls back
  exactly as a USB install does. A truncated or interrupted download ends in
  `failed-integrity`/`failed-network` with nothing armed, and the next
  attempt starts over (there is no resume).
- **Authenticity does not depend on the transport.** The signature over the
  manifest is checked before anything is parsed on every route, so a
  hijacked or plain-HTTP source cannot make a device accept a bundle it
  would otherwise refuse. TLS adds confidentiality and availability only.
- **Rehearsal path.** `ab-serve-release.sh <payload-dir> 8000` on the build
  host plus `--source-config=/data/ab-bundles/bench-source.conf` on the
  device (`BUILD.md` §5). The bench used it for every OTA step of 2.02 →
  2.05: check, install, commit, downgrade, power cut mid-download, corrupt
  payload.

## 2. What is missing

1. **Published releases.** Nothing is on GitHub yet. `latest/download`
   ignores draft and pre-release entries, so releases can be prepared as
   drafts and go live with one click.
2. **A UI path.** System Manager's "System image" section offers only what
   the USB scan finds. It needs a *Check for updates* action (or a
   background check) that reads `/run/ab-update/check`, offers the version
   with the same card and hold-to-install as the USB offer, and runs
   `ab-update install ota` with the existing progress handling. The engine
   side is already there; the app work is small and lives in br-wrapper
   `main` (the app already runs the engine with `sudo -n` and polls
   `/run/ab-update/progress`).
3. **A periodic check.** A systemd timer (`ab-update-check.timer`, daily,
   with a random delay and `Persistent=true`, `After=network-online.target`,
   `ConditionPathExists=` the source config) so the launcher badge can say
   *Update available* without anyone pressing anything. The check is cheap
   and safe to repeat; the install must stay a deliberate action (or an
   explicit opt-in, see §4).
4. **Operational decisions** (§4) and a real-URL acceptance run (§5).

## 3. Publishing (the recipe, to be run for the first time)

Prerequisites: `gh` authenticated as the owner; the release signing key in
`/etc/micropanel/release-signing/` (the bundles are already signed at build
time; publishing signs nothing).

1. **Decide the repository.** The template names the micropanel repo. If
   micropanel's own single-slot releases ever use the same repo, a `latest`
   A/B release would shadow them for `latest/download` consumers; check
   `gh release list --repo hackboxguy/micropanel` before the first publish
   and, if there is a clash, either give A/B its own repo (change
   `AB_RELEASE_URL_TEMPLATE`, which needs a new image because the source
   config is in the image) or make the single-slot releases pre-releases.
2. **Create drafts**, one release per version, tag = version:
   ```sh
   VER=2.04; OUT=~/pi-image-workspace/out/micropanel-ab/payloads/$VER
   gh release create "$VER" --repo hackboxguy/micropanel --draft \
       --title "micropanel $VER (A/B, pi4)" --notes-file notes-$VER.md \
       "$OUT/micropanel-base.mpupdate" "$OUT/micropanel-base.manifest" "$OUT/micropanel-base.manifest.sig"
   ```
   Notes: the source revisions from `image-manifest.env`, the bundle's
   sha256, and what changed. Add `SHA256SUMS`. A release that people will
   flash also carries the image, compressed (`xz -T0`) — check it stays
   under GitHub's 2 GiB per-asset limit; the bundle (~790 MB) is fine.
3. **Publish in version order** (`gh release edit "$VER" --draft=false`),
   so `latest` is always the newest. Then verify the way a device will:
   ```sh
   U=https://github.com/hackboxguy/micropanel/releases/latest/download
   curl -fsSL "$U/micropanel-base.manifest" -o /tmp/m; curl -fsSL "$U/micropanel-base.manifest.sig" -o /tmp/s
   sudo openssl pkeyutl -verify -pubin -inkey /etc/micropanel/release-signing/ed25519-release.key.pub -rawin -in /tmp/m -sigfile /tmp/s
   ```
4. **Withdrawing a release**: delete it (`gh release delete … --cleanup-tag`);
   `latest` moves to the previous one. Devices that already installed it
   are not affected (a downgrade is offered as such on the next check).
   Never re-upload different bytes under the same version.

`BUILD.md` §3 holds the same recipe and should be rewritten from "draft —
not yet run" into what was actually run the first time.

## 4. Decisions to take before switching it on

| Question | Options | Recommendation |
|---|---|---|
| Who triggers the install? | manual only (badge + hold-to-install); automatic at night; automatic with a maintenance window | **Manual only** for the first releases. The device is a display in a vehicle or on a bench; an unattended reboot is worse than a stale version. Automatic later, gated by an owner-set flag on `/data` |
| Staged rollout? | none (`latest` is for everyone); per-device channel file selecting a URL template; separate repos per fleet | **None** until there is a fleet. If needed, the engine's `AB_SOURCE_CONFIG` precedence (environment > config) allows a per-device override file on `/data` chosen by a channel setting, without a new image |
| Bandwidth | ~790 MB per update | Acceptable on Ethernet/WiFi; the check costs nothing. No delta updates: the bundle is a whole root image by design, so a partial update can never leave a mixed system |
| Downgrades over the network | the engine offers a lower version like any other; the UI may label or hide it | Show it, labelled as a downgrade, with the same hold-to-install; a signed older bundle is a legitimate recovery, and the USB path offers it already (the System Manager shows "Update available" for it today) |
| Proxy / captive networks | `AB_NETWORK_TIMEOUT` (30 s connect) and curl's environment | Keep; document that `https_proxy` can be set in the check timer's environment if a site needs it |
| Clock | a factory-reset device boots in 2026-04 until NTP syncs | Already handled: the check names the unsynced clock. The timer should be `After=time-sync.target` when available |
| Key rotation | none today (one pinned key per image line) | Plan a second pinned key before the first key is ever at risk: the engine accepts one key; rotation means shipping an image that pins the new key and signing the next bundles with both for a transition |

## 5. Acceptance before enabling

1. Publish 2.04 and 2.05 (drafts, then live in that order).
2. On a device running 2.04 with no source override: `sudo ab-update check`
   → `update available: 2.05`; `sudo ab-update install ota` → candidate boot
   → automatic commit. Record it in `BUILD.md` §7 as "first real-URL OTA".
3. Repeat with the network cut at 30 % of the download → `failed-network`,
   nothing armed, the same install succeeds afterwards.
4. Timer + badge: after a publish, the badge says *Update available* within
   the timer period without any user action; nothing installs by itself.
5. UI: the online offer card, hold-to-install, progress, reboot, "Running
   2.05 (committed)".

## 6. Work items, in order

1. **App (br-wrapper `main`)**: online offer in the System image section,
   *Check now*, install via `ab-update install ota`, classes `failed-network`
   and the clock case shown in words; the badge reads `/run/ab-update/check`.
2. **Engine/board**: `ab-update-check.timer` + service, shipped by the
   finalizer with the board's `ab-update.conf` deciding whether it is
   enabled (`AB_CHECK_TIMER=daily|off`); a static-test pin.
3. **Publish**: first drafts, the repository decision, `BUILD.md` §3
   rewritten.
4. **Acceptance** (§5) on the bench, then a new image version whose
   `BUILD.md` says online updates are supported from it on.

None of these change the bundle format, the signing, the slot protocol or
the health/commit rules, so every image from 2.04 on will be able to take
online updates once they are published.
