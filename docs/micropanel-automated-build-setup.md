# micropanel automated SD-card and bundle builds — proposed setup

Plan agreed with the owner on 2026-09-29, to be implemented by a fresh
session. Nothing described here exists yet. Read
`micropanel-sdcard-ab-update.md` first for how the A/B build works.

## 1. Decisions already taken

- **Triggers:** on demand (a button or a command with a version), and a
  nightly at **01:00 Europe/Berlin** that builds **only if an input changed**
  since the last build; otherwise it exits in a minute and reports "nothing
  changed".
- **Orchestrator: GitHub Actions with one self-hosted runner** on the Arch
  Linux build machine (the one that already runs `build-image.sh`, the
  CC-RH, Vivado and Diamond makefile builds). No Jenkins, no Windows.
- **The firmware and FPGA legs are separate jobs** that watch the rh850 C
  code and the Verilog and, on a change, run their makefiles and push the
  produced binaries to `sp6bins`. The SD-card build does not know about
  them: it only sees "sp6bins changed".
- **Outputs stay on the build machine** (images are 15 GB each). GitHub
  holds the logs and the status, not the artifacts.

## 2. Does the free GitHub tier allow this?

Yes, because the runner is self-hosted:

| GitHub limit | Applies to self-hosted? | Consequence here |
|---|---|---|
| Actions minutes (2,000/month free for private repos) | **No** — only GitHub-hosted runners consume minutes | A 2 × 65 min build costs nothing. Only the tiny dispatcher workflow in `sp6bins` (§5) runs on GitHub's runners, about one minute per push |
| Job time limit | 6 h default, raisable with `timeout-minutes` (up to 5 days on self-hosted) | Set `timeout-minutes: 240` on the build job |
| Storage for workflow artifacts and packages (500 MB free on the free plan) | Yes, if artifacts are uploaded | **Never upload an image or bundle as a workflow artifact.** They stay in the workspace on the build machine; the job uploads only a small text report (hashes, manifest, log tail) |
| Release assets | 2 GiB per file, no published total cap | Optional later, for the online-update plan; not part of this setup |
| Log retention | 90 days | Enough; the machine keeps its own copies (§7) |
| Self-hosted runners on public repositories | Allowed but discouraged by GitHub | Solved by §3: the runner is attached to one private repo only |

The machine, not GitHub, is the constraint: a build pair needs ~16 GB of
output and the workspace already holds 21 GB of base images and 5 GB of
kernel trees. Keep at least 60 GB free on the workspace disk and apply the
retention rule in §7 before the first nightly.

## 3. Topology

```
 hackboxguy/micropanel-ci  (NEW, private)   <- all workflows, the only repo the runner serves
        |  self-hosted runner "micropanel-build" on the Arch machine
        |  checks out misc-tools at the configured branch and runs build-image.sh
        |
 hackboxguy/sp6bins (private)  --repository_dispatch "sp6bins-updated"-->  micropanel-ci
 rh850, pixelpipe-fpga (source repos) -> their own jobs (§5), whose result is a sp6bins push
 misc-tools, micropanel, br-wrapper, als-dimmer, ... (public): NO workflows, NO runner;
        the nightly detects their changes by `git ls-remote`
```

Why a separate private repo: a self-hosted runner attached to a public
repository executes whatever a workflow in that repository says, and every
runner secret (the `gh` login that reads the private repos) lives on that
machine. Keeping the workflows in a private repo that nobody else can push
to removes the whole problem, and it means the public repos stay clean of
CI files. It also gives one place for the run history of everything.

## 4. The SD-card build workflow (`micropanel-ci/.github/workflows/sdcard.yml`)

Triggers:

```yaml
on:
  schedule:
    - cron: '0 23 * * *'     # 01:00 CEST; 00:00 UTC in winter (adjust twice a year, or accept 00:00/01:00)
  repository_dispatch:
    types: [sp6bins-updated]
  workflow_dispatch:
    inputs:
      kind:     { type: choice, options: [nightly, release], default: nightly }
      version:  { description: 'release only: 2.xx (never reissued)', required: false }
      payload_only: { type: boolean, default: false }   # bundle without a new image (a 2.xx+1)
      force:    { type: boolean, default: false }       # build even if nothing changed
```

Jobs, all `runs-on: [self-hosted, micropanel-build]`, all sequential:

1. **detect** — writes `inputs.lock`: one line per input with its current
   revision, from `git ls-remote` (no clone), for
   - misc-tools (`feature/A-B-Update` until the merge, then `main`),
   - every git hook line of `board-configs/micropanel/hooks-ab.txt`
     (micropanel `main`, br-wrapper `main`, als-dimmer, disp-report-card,
     kodi-custom-addons, streamdeck-ctrl `display-control`, xc3sprog,
     openFPGALoader `v1.0.0`),
   - every `SOURCES` entry of `board.conf` (br-wrapper, sp6bins,
     rh850-flash-tools, space6-architecture, media-files),
   - the vanilla image filename from the base profile.
   Compares with `last-built.lock` in the workspace. Equal and not
   `force` → the workflow ends with the summary "no input changed since
   <date>, build skipped". (The builder's own stamps are a second, finer
   layer: an input that changed in a way no stage consumes still finishes
   in minutes.)
2. **build** — `git clone`/`fetch` misc-tools into the runner's work dir,
   then, exactly as in `BUILD.md`:
   ```sh
   ./build-image.sh --board=micropanel --base-profile=qt-bookworm --layout=ab --version=$VER --skip-kernel --payload --dry-run
   sudo ./build-image.sh --board=micropanel --base-profile=qt-bookworm --layout=ab --version=$VER --skip-kernel --payload
   ```
   with `AB_RELEASE_KEY_DIR` pointing at the **nightly key** for
   `kind=nightly` (§6). `--skip-kernel` always: a kernel rebuild is a
   deliberate, manual act. The log goes to `ci-logs/<run>.log` on the
   machine and its tail into the job summary. Required log lines, checked
   by the job: `[slim] result`, `root copy: file copy`, `Created A/B image
   layout`, `A/B image layout verified`.
3. **verify** — on the outputs: sha256 of image and bundle,
   `tar -tf` member order, `ab-release-key.sh verify` on the manifest with
   the key that signed it, the image manifest's revision lines
   (`IMAGE_VERSION`, `MICROPANEL_REVISION`, `BR_WRAPPER_REVISION`, …) —
   all written to `report.txt` and uploaded as the only workflow artifact
   (kilobytes).
4. **publish-local** — moves the outputs to `out/micropanel-ab/nightly/<VER>/`
   (release builds stay where `BUILD.md` expects them), compresses the
   image with `xz -T0` after verification (a 15 GB image of mostly zeros
   becomes ~1.5 GB), writes `nightly/latest` (the version) and applies
   retention (§7), then writes `last-built.lock`.
5. **smoke-test** (nightly only, optional at first) — the bench rig over
   ssh, exactly the sequence used for acceptance by hand:
   `ab-serve-release.sh nightly/<VER> 8000` on the machine,
   `sudo ab-update install ota --source-config=/data/ab-bundles/bench-source.conf`
   on the rig, wait for the reboot, poll `/run/ab-update/status` until
   `state=committed` (fail after 5 min), read the debug sampler's last lines
   into the summary. The rig must be flashed with a **nightly-key** image
   for this to work (§6), so this job is a separate device from any
   release-key device. Skip when the rig does not answer.
6. **notify** — one message per run (email, ntfy, Telegram — owner's
   choice): built / skipped / failed, the version, the hashes, the
   smoke-test verdict.

On-demand release: `gh workflow run sdcard.yml -f kind=release -f version=2.06`
(image + bundle), then `-f version=2.07 -f payload_only=true` for the next
bundle. Release builds use the release key and never run the smoke test
against a nightly-keyed rig.

## 5. The artifact legs (rh850, pixelpipe-fpga → sp6bins)

Owner-provided, outside the SD-card workflow, but they must obey four rules
so the chain stays sane:

1. **Idempotent commits.** Build, compare the produced binaries byte for
   byte with what `sp6bins` holds, commit only on a difference. A rebuild
   from the same source must not produce a new sp6bins commit.
2. **Provenance in the commit.** Message `artifacts: rh850 <short-sha>` /
   `artifacts: pixelpipe-fpga <short-sha>`, and a `<artifact>.source` file
   next to each binary with the source repo, SHA, tool version and date.
   The image manifest then records `SP6BINS_REVISION`, so every bundle can
   be traced to the firmware source.
3. **One direction only.** `sp6bins` carries a five-line workflow that, on
   push to `main`, sends `repository_dispatch: sp6bins-updated` to
   `micropanel-ci` (runs on a GitHub-hosted runner, about a minute of free
   quota). Nothing ever dispatches *from* the SD-card build back to the
   firmware or FPGA jobs, so no loop is possible.
4. **Same runner, serialised.** The firmware and FPGA jobs can run on the
   same self-hosted runner (they already run on that machine); give the
   SD-card workflow `concurrency: sdcard-build` so two image builds never
   overlap (they share the workspace and the stamps).

Where those jobs live is the owner's choice: in `micropanel-ci` (one place)
or in the source repos if they are private. Large binaries (bitstreams,
media) go through git-lfs as `media-files` already does; the runner must
keep its clones and fetch incrementally (the free LFS bandwidth is 1 GB per
month and a fresh clone of media-files alone is 86 MB).

## 6. Versions and signing keys

- **Nightly versions:** `N.<YYYYMMDD>`, with `.2`, `.3` appended for a
  second build the same day. Unique (the engine refuses same-version
  installs) and unmistakable next to the `2.xx` release line. The builder
  accepts any version string.
- **Nightly signing key:** its own key at `/etc/micropanel/nightly-signing/`
  (created once with `ab-release-key.sh`, root 0700), selected by exporting
  `AB_RELEASE_KEY_DIR` for nightly runs — the builder honours the
  environment over the board's `AB_RELEASE_KEY_DIR` (verify this on the
  first run; `build-image.sh` exports it at line ~498). An image pins the
  public half of the key that built it, so **nightly bundles install only
  on devices flashed with a nightly image, and release bundles only on
  release images.** This is the safety line that keeps an experimental
  build off a fielded device that happens to have a USB stick plugged in.
  The bench rig used for the smoke test is flashed once with a nightly
  image.
- **Release builds** use the release key in `/etc/micropanel/release-signing/`
  and a `2.xx` version that has never been used; the job refuses a version
  that already has an output directory or a tag.

## 7. Runner machine setup

- A dedicated user `ci` for the runner service (`actions-runner` as a
  systemd service, labels `self-hosted, micropanel-build`), with a sudoers
  entry limited to the build:
  `ci ALL=(root) NOPASSWD: /home/ci/work/misc-tools/build-image.sh`
  (plus `ab-release-key.sh verify` and the retention script). Nothing else
  needs root.
- `gh auth login` as `ci` with a fine-grained token that can read
  `sp6bins`, `media-files`, `space6-architecture`, `rh850-flash-tools`
  (the private sources) and can *write* nothing — the SD-card build never
  pushes. `git lfs install`. `git config --global credential.helper` via
  `gh auth setup-git`.
- Workspace `WORKSPACE=/home/ci/pi-image-workspace` on the large disk
  (never `/tmp`), warmed once by a manual build so the base and kernel
  caches exist; the first CI build then takes the normal ~65 min per image.
- Retention (run by publish-local): keep the newest 5 nightly bundles and
  the newest 2 nightly images (compressed); release outputs are never
  deleted by CI. `ci-logs/` keeps 30 days.
- The signing keys are owned by root, 0700; the build runs under `sudo`,
  so `ci` never reads them directly.
- Time: the machine's clock must be NTP-synced (the runner and the
  nightly version string both depend on it).

## 8. Failure behaviour

- A failed build leaves no half-written output in `out/` (the builder
  works in its workspace `tmp/` and moves the image at the end); the next
  run redoes only the failed stage because the stamps of the earlier
  stages hold.
- `detect` failing (a repo unreachable) is a failure, not a skip: the
  summary says which URL, and the nightly retries the next night.
- The smoke test failing marks the run failed but keeps the outputs; the
  rig is left on its committed slot by the engine's own design, so it is
  ready for the next night without intervention.
- Two triggers close together (a sp6bins push during the nightly) queue on
  the `concurrency` group; the second run's `detect` sees the new
  `last-built.lock` and builds only if something changed after it.

## 9. Implementation checklist for the next session

1. Create `hackboxguy/micropanel-ci` (private); register the self-hosted
   runner on the Arch machine as user `ci` with the sudoers line; warm the
   workspace with one manual build.
2. Create the nightly key; flash the bench rig with a nightly-keyed image.
3. Write `sdcard.yml` with the six jobs of §4; run it with
   `workflow_dispatch` + `force` once, then let a night pass and confirm
   the "skipped" path.
4. Add the `sp6bins` dispatcher workflow; push a no-op artifact change and
   confirm the chain.
5. Add the notification and the retention script.
6. Then the rh850 and pixelpipe-fpga jobs under the rules of §5 (owner).
7. Document the on-demand release command in `BUILD.md` §1/§2 next to the
   manual ones.

## 10. Open points for the owner

- Notification channel (email / ntfy / Telegram / a GitHub issue comment).
- Whether the smoke-test rig is the OTS-OLED head unit or a second device
  kept on the nightly key.
- Which repository the rh850 and pixelpipe-fpga jobs live in.
- The misc-tools branch the nightly follows until `feature/A-B-Update` is
  merged to `main`.
