# pi-ab-update

In-system A/B update engine for Raspberry Pi appliance images: the device
writes a new OS image into its inactive slot, boots it once via the firmware's
`tryboot` mechanism, and commits only after the new system proves healthy. A
failed update falls back automatically. `/data` is never part of an update.

The engine is board-agnostic. It was built inside `micropanel-touch` and
extracted once it was hardware-accepted; that board is now its reference
profile and, so far, its only adopter.

## What is here

| File | Role |
|---|---|
| `ab-system-update` | the root-only installer: USB discovery (FAT32, exFAT or NTFS; NTFS through the kernel's ntfs3 first, then ntfs-3g), single-pass bundle reader, streaming write, hash-before-arm, selector arm, reboot |
| `ab-update` | the front door: `status`, `check`, `install ota\|usb\|--file=`, `watch`, `log`, plus single-value queries for scripts. Composes and delegates; contains no policy of its own |
| `ab-update-check` | asks the release server what it offers: fetches the manifest and its signature only, verifies, and publishes `available` / `up-to-date` |
| `ab-slot-selector` | the three-operation slot protocol (`current-slot`, `arm-candidate`, `commit`) — the seam a secure-boot backend replaces |
| `ab-update-commit` + `.service` | commits a candidate after a sustained health window, or records `fallback` |
| `ab-factory-reset` | root-only request: writes one durable marker and schedules a reboot. It erases nothing itself |
| `ab-factory-reset-boot` + `.service` | performs the wipe early on the next boot, before anything reads the durable state |
| `ab-finalize-layout.sh` | host-side post-image hook: builds the A/B partition layout and installs the engine into the image |
| `ab-make-payload.sh` | host-side generator for the signed `format=2` `.mpupdate` bundle |
| `ab-verify-image.sh` | read-only host-side acceptance check for a built image |
| `ab-release-key.sh` | ed25519 release-key custody (create, sign, verify) |
| `ab-serve-release.sh` | host-side bench helper: serves a payload directory over HTTP so an over-the-air update can be rehearsed before publishing |
| `tests/` | host suites (bundle reader, handler policy, commit policy and status, the update check, the front-end CLI, factory reset, and three root-only loopback fixtures); `tests/run-tests.sh` runs them all |

## The board contract

Everything product-specific comes from one board-authored file, installed
read-only at `/usr/lib/pi-ab-update/ab-update.conf`. The engine *parses* it
strictly — it never sources it as shell. Precedence throughout is
environment (test seams) > config > built-in default.

```
AB_PRODUCT=micropanel-touch                     # published asset name prefix
AB_MANIFEST=/opt/…/image-manifest.env           # the image's own manifest
AB_VARIANT_KEY=PANEL_VARIANT                    # which manifest key binds the variant
AB_STATE_DIR=/data/…-system                     # durable update state
AB_RUNTIME_DIR=/run/…                           # progress/status telemetry
AB_HEALTH_UNITS=a.service b.service             # all active, none restarted
AB_HEALTH_HOOK=/usr/lib/…/update-health         # optional extra predicate, exit 0
AB_SETTLE_SECONDS=30
AB_COMMIT_WAIT_SECONDS=120                      # readiness wait before the settle window
AB_ON_REFUSAL=reboot                            # reboot|stay: what a refused candidate does

# Updates: authenticity, and where releases come from
AB_SIGNING_KEY=/usr/lib/pi-ab-update/update-signing-key.pub   # pinned, root-owned
AB_SOURCE_CONFIG=/usr/lib/pi-ab-update/update-source.conf     # MANIFEST_URL, MANIFEST_SIG_URL, BUNDLE_URL
AB_NETWORK_TIMEOUT=30                           # connect timeout, seconds
AB_CURL=curl                                    # test seam

# Factory reset
AB_DATA_MOUNT=/data                             # wiped; refused unless its own rw mount
AB_APP_ACCOUNT=micropanel-touch                 # passed to the skeleton script
AB_RESET_BEFORE=a.service b.service             # units the wipe must precede
AB_RESET_SEED=/src/dir:relative/dest            # optional, space-separated pairs
AB_REBOOT_DELAY_SECONDS=2                       # 0 reboots synchronously
```

`AB_RUNTIME_DIR` is also read by whatever shows progress to a user, so a board
with a UI must keep the two in agreement.

**If you are looking for the status file and it is not there, you are probably
looking in the default.** `AB_RUNTIME_DIR` defaults to `/run/ab-update`, but a
board may point it elsewhere and micropanel-touch does — at
`/run/micropanel-touch-update`, kept at its historical path because the HMI
reads progress from it. An absent `/run/ab-update/status` on such a board is
the board config working, not a publish regression. `ab-update status` resolves
the configured location for you, which is the reason the front end exists;
reach for it before reaching for a path. This has now cost two readers the same
detour, which is why it is written down.

### About the front end

`ab-update` exists because operating this engine otherwise means remembering
four file paths and three script names. It follows one rule: **it composes, it
never decides.** It reads state the engine publishes and hands work to the
engine; it holds no version comparison, no compatibility rule and no health
judgement. A second copy of that policy would drift from the engine, and the
copy people actually run would be the one no fixture covers - so a static test
forbids it.

`ab-update --inactive-version` is the one thing it can do that nothing else
could: it mounts the other slot read-only to report what a rollback would land
on. It takes the engine's own lock first, because mounting a slot that is
mid-write is a real hazard.

### About update authenticity

Every release is authenticated by a **raw ed25519 signature over its manifest**,
checked against a public key pinned in the image. There is no certificate
anywhere in that path — no X.509, no validity window — which is deliberate: a
device with no RTC and no network still verifies a signed release correctly,
so a permanently offline unit stays updatable from a USB stick forever. The
signature is a mandatory bundle member and is verified *before* any manifest
field is parsed, on every route.

That is also why the transport is not a trust boundary here. `BUNDLE_URL` may
be plain HTTP — as it is when rehearsing against `ab-serve-release.sh` — without
weakening what a device will accept; TLS buys confidentiality and availability,
not authenticity. A shipping image should still use https.

An adopting board that overrides `AB_CURL` should point it at a single process:
the engine stops a download by signalling that process, and a wrapper script
that lingers as a parent can leave a child holding the engine's lock.

### About the factory reset

The split into request and boot-time wipe is what makes the reset safe to
interrupt: every step is idempotent and the marker is cleared *last*, so a
power cut at any point costs one boot rather than leaving half a device. The
wipe re-runs the *same* skeleton script the image build runs, so a reset device
and a freshly flashed one cannot drift; `AB_RESET_SEED` restores what the
skeleton cannot know about (files the image seeded into the durable partition
whose pristine copies live in the read-only root). `lost+found` is the
filesystem's, not the product's, and is left alone.

**Seeding durable state from the image.** `AB_RESET_SEED` restores flat,
root-owned files only (NetworkManager keyfiles). Anything richer - a directory
tree owned by the app account, say - is the skeleton's job, because the
skeleton runs on both paths: the skeleton may copy pristine seeds from
`$AB_SEED_ROOT` (finalizer) or `/media/root-ro` (reset); it must copy only into
an empty destination and must preserve ownership. The finalizer exports
`AB_SEED_ROOT` as the mounted authored root; the reset exports nothing, so a
skeleton defaults to `/media/root-ro`.

`AB_RESET_BEFORE` becomes a generated `Before=` drop-in, so the shared unit
names no product. List every unit that reads the durable state — including any
that restores machine identity, which must not run before the wipe.

The wipe refuses a data mount that is not a mount point of its own, is not
mounted read-write, or does not hold the configured state directory. That is
not typo paranoia: it is what a failed durable-partition mount looks like, and
wiping through it would destroy the running root.

**A reset device boots with a stale clock.** The wipe removes saved clock state
along with everything else, so an RTC-less board comes up in the past until NTP
syncs. Harmless in itself, but anything doing TLS early — an update check, for
instance — should expect and name that case rather than reporting a confusing
certificate failure.

The build side additionally passes `AB_MANIFEST_PATH`,
`AB_APP_ACCOUNT`, `AB_APP_REVISION_KEY`/`AB_APP_REVISION`,
`DATA_SKELETON_SCRIPT`, `AB_UPDATE_CONF` and `AB_ASSERTIONS` — see
`board-configs/micropanel-touch/board.conf` for a worked example.

## What an adopting board still owes

Extraction makes the software reusable; A/B remains an appliance discipline a
board adopts, not a flag it flips:

1. **A read-only overlayroot root with `/data` persistence.** The structural
   slot resolution reads the lower-root mount, the health check needs `/data`
   rw, and the rollback model assumes slots are immutable. This is the real
   per-board cost.
2. **A 16 GB card and the partition budget**, with slot sizes that fit the
   board's root. Slot sizes freeze at first flash.
3. **A durable-state skeleton script** and an image manifest carrying the
   layout, variant and board keys.
4. **Its own hardware acceptance.** Another board's records do not transfer.

## Device tool baseline

The engine runs on the device, so every tool invocation in it has to work with
the oldest distribution an adopting board ships - today Debian 12 (bookworm,
micropanel): util-linux 2.38, coreutils 9.1, xz 5.4, curl 7.88, OpenSSL 3.0,
tar 1.34, systemd 252. micropanel-touch is trixie, and the build host is newer
still, so a flag that works there is not evidence. The slot resolution learned
this the hard way: `lsblk -o PARTN` exists only from util-linux 2.40, and on
bookworm the updater refused every install ("unknown column: PARTN"); the
partition number now comes from `/sys/class/block/<dev>/partition`. Check any
new device-side flag against that baseline; the handler loopback fixture's
`lsblk` refuses `PARTN` the way bookworm does.

## System settings the engine changes

- **Runtime watchdog, 60 s** (`/etc/systemd/system.conf.d/90-pi-ab-update-watchdog.conf`,
  written by the finalizer, required by the verifier). It resets a candidate
  whose PID 1 has hung, so the tryboot falls back. It was 20 s until a bench
  board reset in the middle of a slot write with PID 1 stalled on a saturated
  SD card; the reasoning is in the file.
- **Dirty page cache, while an install runs**: `vm.dirty_bytes` 16 MiB and
  `vm.dirty_background_bytes` 8 MiB from just before the slot is first
  written until the handler exits; the kernel's own values (bytes or ratio,
  whichever was in force) are restored on every exit, and kept in
  `/run/ab-update/private/dirty-limits.saved` so a killed run's successor
  restores them too. Without it the stream builds up about a gigabyte of dirty
  pages and flushes them in bursts that stall every other writer. Measured on
  a loop device with one cache layer (as the device has): no throughput cost -
  544 MiB/s uncapped, 23.9 MiB/s against a 25 MiB/s write cap, the same as
  `oflag=direct` (23.7) - with peak dirty memory 8-10 MiB instead of ~950.

## A refused candidate

When the commit service refuses a tryboot candidate (not healthy within
`AB_COMMIT_WAIT_SECONDS`, health lost in the settle window, a health unit
restarted), it logs the reason, records it in `<AB_STATE_DIR>/update-refusal`
(root-only: `version=`, `candidate_slot=`, `refused_reason=`) and, with
`AB_ON_REFUSAL=reboot` (the default), reboots. The tryboot flag is one-shot, so
the committed slot boots; its commit service records `state=fallback` and
publishes `refused_reason=` in the public status beside it (`ab-update
--refused-reason`). `stay` keeps the refused candidate up for inspection; it
still falls back at the next reboot. The reason is deliberately not a key of
`update-state`: the slot that boots after a refusal is the older image, and its
commit service parses `update-state` strictly. Installing a new candidate
clears the record.

## Format and layout constants

`MP_BOOT_A`/`MP_BOOT_B`/`MP_ROOT_A`/`MP_ROOT_B`/`MP_FACTORY`/`MICROPANEL_DATA`
labels, the p1/p2/p5/p6/p7/p8 layout, and the `@MICROPANEL_SLOT@` cmdline
placeholder are fixed cross-board constants. Their names are historical; they
are deliberately not renamed, because a rename buys nothing and would force a
reflash and invalidate every already-published bundle.
