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
| `ab-slot-selector` | the three-operation slot protocol (`current-slot`, `arm-candidate`, `commit`) — the seam a secure-boot backend replaces |
| `ab-update-commit` + `.service` | commits a candidate after a sustained health window, or records `fallback` |
| `ab-finalize-layout.sh` | host-side post-image hook: builds the A/B partition layout and installs the engine into the image |
| `ab-make-payload.sh` | host-side generator for the signed `format=2` `.mpupdate` bundle |
| `ab-verify-image.sh` | read-only host-side acceptance check for a built image |
| `ab-release-key.sh` | ed25519 release-key custody (create, sign, verify) |
| `tests/` | five host suites; `tests/run-tests.sh` runs them all |

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
```

`AB_RUNTIME_DIR` is also read by whatever shows progress to a user, so a board
with a UI must keep the two in agreement.

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
