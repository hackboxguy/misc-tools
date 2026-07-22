# misc-tools - AI assistant knowledge base

Single-command builder for customized Raspberry Pi 4 SD-card images.
Entry point: `build-image.sh` (orchestrator). Engines it drives:
`custom-pi-imager/custom-pi-imager.sh` (sdm + QEMU-chroot image
customization, modes `base`/`incremental`) and
`custom-pi-kernel-builder/scripts/00-build-all.sh` (host-side kernel +
out-of-tree driver cross-build). Read `README.md` first for the user-facing
workflow; this file holds the design decisions and gotchas.

## Architecture: stages and cached artifacts

sources → base → kernel → apps. Workspace (default `~/pi-image-workspace`):

- `downloads/` - vanilla img.xz cache. Downloaded only when the base stage
  will actually run (`base_will_run()`).
- `sources/` - repos from board.conf `SOURCES` (`name|url|branch`), cloned
  as the *invoking user* (their git credentials), pulled every run.
  `${REPOBINS}` in hook lists resolves here (or `--repobins=DIR`).
- `base/profile-<name>/` (shared via `BASE_PROFILE`) or `base/<board>/` -
  extended vanilla + apt runtime+build deps + optional profile hooks.
- `kernel/<board>/` - copy of base + that board's kernel drivers. Stage 2
  never mutates the base image (works on a copy) - this keeps profile bases
  shareable across boards.
- `out/<board>/` - final images, named `<vanilla-stem>-<board>[-variant]-<version>.img`.

## Stamp system (the heart of the caching)

Each stage writes `.stamp` = sha256 over its inputs; unchanged → skipped.
`--force-*` / `--skip-*` override in either direction.

- base stamp: profile name, vanilla image *filename* (not path/URL - keep
  filenames canonical), extend size, password, deps file contents, profile
  hook list + scripts + local-dir revs + git-hook remote revs. `--version`
  is deliberately EXCLUDED (version bumps must not rebuild base/kernel).
- kernel stamp: base stamp + kernel branch + config file content + driver
  source dir rev (git HEAD + porcelain hash of `sources/br-wrapper`).
- apps stamp: input-image stamp + version + hook list + hook script
  contents + `file://` source dir revs + `git ls-remote` revision of every
  git-source hook (so pushing to e.g. qt-cluster-demo or br-wrapper
  auto-triggers the apps stage). Probes run via `git_probe()` (as invoking
  user, `GIT_TERMINAL_PROMPT=0`); `--offline` falls back to literal refs.

Known trap this design fixed twice: anything an image build consumes must
be in the stamp, or pushed changes silently don't reach the image.

Userspace-only iteration: `--skip-kernel` recommended even though stamps
would usually skip kernel anyway - the sources stage pulls br-wrapper each
run and any new commit there (qt apps live in the same repo as drivers)
would otherwise trigger a ~45 min kernel rebuild.

## Base profiles

`BASE_PROFILE=<name>` in board.conf → `base-configs/<name>/{profile.conf,
runtime-deps.txt,build-deps.txt,hooks.txt}`. CLI `--base-profile=NAME`
overrides per-invocation (`none` disables); `--base-profile` without
`--board` builds ONLY the profile base.

- Profile owns base-stage parameters: apt lists, `EXTEND_SIZE_MB`,
  `DEFAULT_PASSWORD`, and (optionally) `IMAGE_URL` pinning the matching OS
  release. Precedence: CLI `--image-url` > profile > board.conf. Never let
  boards diverge on these - the shared stamp would ping-pong.
- With a profile, the apps-stage build-dep purge uses the PROFILE build-dep
  list (superset), and the board's `BUILD_DEPS` is ignored. Board
  `RUNTIME_DEPS` stays board-level: the imager re-installs it after the
  purge (protects against apt autoremove cascade - e.g. boost runtime libs
  must be pinned in runtime deps because vsomeip's .so is not a dpkg
  package).
- Profiles: `qt-bookworm` (micropanel, pi4-touch-demo, qt-cluster-demo) and
  `qt-trixie` (same recipe, boost 1.83 pins, trixie vanilla; no board uses
  it by default). Profile deps are OS-release-specific - a new release
  means a new profile, not an edit.
- Profile hooks (imager now runs setup hooks in base mode, after package
  install) bake heavy rarely-changing components into the shared base:
  qt profiles compile COVESA vsomeip 3.5.11 to
  `/home/pi/.codex-deps/prefix/vsomeip-3.5.11` (the prefix qt-cluster-demo's
  build script defaults to and its systemd unit hardcodes in
  LD_LIBRARY_PATH). Under QEMU this compile takes 30-60 min, once per base
  rebuild. vsomeip's cmake warnings about missing Doxygen/vsomeip3(examples)/
  benchmark(tests) are benign.

## Hook system (custom-pi-imager)

Hook list line: `HOOK|GIT_REPO|TAG|DEST|DEPS|POST_CMDS|CMAKE_ARGS`.
`${VAR}` env refs are expanded at load (braced form only; unset var =
fatal). Hooks run inside the ARM64 chroot; git-source hooks clone from
GitHub in-chroot (re-downloaded every apps run, nothing on host);
`file://${REPOBINS}/...` local sources are copied in from the host (for
private/large/LFS repos needing host credentials). generic-package-hook.sh
purges its per-hook DEPS after install. Chroot limits: `systemctl enable`
works (creates symlinks); `daemon-reload`/`restart`/`status` fail - hooks
must not call them. `make` output is redirected to /dev/null → long silent
phases under QEMU are normal, not hangs.

## External repos

- `br-wrapper` (public): kernel drivers under `package/` AND qt userspace
  apps - one repo, two stages consume it.
- `sp6bins` (PRIVATE): prebuilt firmware/bitstreams. Cmake option
  `SP6BINS_MICROPANEL_COMPAT=ON` installs the micropanel-compat layout
  (`fpga/bitbin`, `fpga/bin`) that replaced the retired `fpga-bins` local
  package; micropanel's `config-pios.json` hardcodes those paths. Preflight
  fails if a checkout lacks the option (cmake silently ignores unknown -D).
- `archsp6` = `space6-architecture.git`, default branch `master` (not main).
- `media-files` (PRIVATE, git-lfs): 86MB `ref-video.mp4` as a standard
  cmake-installable package → `share/sp6bins/config/`. Requires `git lfs
  install` on the host (preflight checks). GitHub free LFS bandwidth is
  1GB/month; fallback plan if exceeded: release asset + download step.
- `qt-cluster-demo` (PRIVATE → must be a file:// local source, cloned
  host-side via SOURCES; an in-chroot git clone of a private repo prompts
  for credentials and hangs unattended builds - learned the hard way). Its
  hook copies the source to /home/pi/qt-cluster-demo, runs the repo's own
  `build-and-deploy.sh --mode=demo --dms=enable --skip-tests --skip-deploy`,
  then writes the service env itself (STATIC copy of what that script's
  deploy step generates for demo+dms - keep the hook in sync if upstream
  argument scheme changes) and `systemctl enable`s the unit.
  RULE: private repos are always SOURCES + file://${REPOBINS}/...; only
  public repos may be in-chroot git-source hooks.

Network policy pattern (qt-cluster-demo, reusable for other boards):
DHCP-with-static-fallback is done declaratively with NetworkManager's
two-profile autoconnect-priority mechanism (bookworm/trixie default to NM) -
see `board-configs/qt-cluster-demo/packages/network-fallback-hook.sh`.
High-priority DHCP profile (dhcp-timeout=5, autoconnect-retries=1) +
low-priority static profile (192.168.10.3/24, no gateway/DNS). ~5-7s to
fallback after carrier (fast pairing with a direct-cabled static Jetson at
192.168.10.2); no auto-switch back if DHCP appears mid-session. A DHCP
*server* on the Pi was considered and rejected: the static peer never
requests a lease (no speedup) and it would act as a rogue DHCP server on
shared LANs.
NM requires connection files root-owned mode 600; fixed UUIDs keep builds
deterministic. Never solve this with dhcpcd or polling scripts.

Private repos: sources clone as the invoking user → `gh auth setup-git`
credentials apply even under sudo. One-shot alternative:
`sudo GIT_USERNAME=x GIT_TOKEN=<PAT> ./build-image.sh ...` (0600 temp
credential store; env vars by design, never CLI flags).

## Gotchas learned the hard way

- Vanilla image URLs rot: bookworm moved to `raspios_oldstable_lite_arm64/`
  (old `raspios_oldstable_arm64/` path 404s). Verify with `curl -I` when a
  download fails.
- `/tmp` is tmpfs on the dev machine - never put the workspace there
  (images are ~5GB of RAM); `--sources-dir`/`--output-dir`/`--workspace`
  relocate pieces individually.
- `--baseimage=~/path` doesn't tilde-expand (bash quirk); use `$HOME`.
- Stamps key the vanilla image by FILENAME - renaming a local img.xz makes
  it a "different" image.
- `custom-pi-kernel-builder` is hardcoded to exactly two drivers
  (hh983-serializer, himax-touch from br-wrapper/package) in
  00-build-all.sh validation and 04-build-drivers.sh - generalize before
  adding a board with different drivers.
- media-mux BUILD variants use `--variant=extern-dlna|selfhosted-dlna`
  (per-variant `VAR_<variant>` overrides in board.conf).
- `--dry-run` needs no root and runs full preflight incl. git reachability -
  always suggest it first.
- Repo branches: everything is merged to `main` in all repos (misc-tools,
  sp6bins) as of 2026-07-22; the historical development branch was
  `unified-build-structure`.
