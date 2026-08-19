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
| `ab-system-update` | the root-only installer: USB discovery, single-pass bundle reader, streaming write, hash-before-arm, selector arm, reboot |
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
| `tests/` | host suites (bundle reader, handler policy, commit policy and status, factory reset, and two root-only loopback fixtures); `tests/run-tests.sh` runs them all |

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

The build side additionally passes `AB_MANIFEST_PATH`, `AB_LIB_DIR`,
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

## Format and layout constants

`MP_BOOT_A`/`MP_BOOT_B`/`MP_ROOT_A`/`MP_ROOT_B`/`MP_FACTORY`/`MICROPANEL_DATA`
labels, the p1/p2/p5/p6/p7/p8 layout, and the `@MICROPANEL_SLOT@` cmdline
placeholder are fixed cross-board constants. Their names are historical; they
are deliberately not renamed, because a rename buys nothing and would force a
reflash and invalidate every already-published bundle.
