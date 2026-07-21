# misc-tools

Tools for building customized Raspberry Pi 4 SD-card images (RaspiOS lite
based), plus the board configurations that use them.

```bash
./build-image.sh --list-boards                 # what can be built
./build-image.sh --board=micropanel --dry-run  # preflight + plan (no root)
sudo ./build-image.sh --board=micropanel --version=01.15
```

## Setting up a fresh PC (Arch Linux)

### 1. Install host packages

```bash
sudo pacman -S --needed git git-lfs github-cli wget xz \
    qemu-user-static qemu-user-static-binfmt
git lfs install                     # enable LFS filters (media-files repo)
```

Verify ARM64 emulation is registered (needed for the QEMU chroot stages):

```bash
ls /proc/sys/fs/binfmt_misc/qemu-aarch64 || sudo systemctl restart systemd-binfmt.service
```

### 2. Install sdm (Raspberry Pi image customizer)

```bash
sudo curl -L https://raw.githubusercontent.com/gitbls/sdm/master/EZsdmInstaller | sudo bash
sdm --version
```

### 3. Kernel cross-toolchain (only for boards with KERNEL=1)

```bash
sudo ./custom-pi-kernel-builder/scripts/01-setup-arch-deps.sh
```

Installs `aarch64-linux-gnu-gcc`, `dtc`, `bc`, `bison`, `flex`, etc.
Boards without a kernel stage (media-mux, qt-cluster-demo) don't need this.

### 4. GitHub authentication (private source repos)

Some source repos (e.g. `sp6bins`, `media-files`) are private; the sources
stage clones them as your user over https. Pick one:

**Option A - gh credential helper (recommended, persistent):**

```bash
gh auth login --hostname github.com --git-protocol https --web
gh auth setup-git        # registers gh as git's credential helper
```

After this, git clone/push (including git-lfs transfers) is passwordless
for you and for any tool running git as your user.

**Option B - one-shot credentials per build (nothing stored on the PC):**

```bash
sudo GIT_USERNAME=<github-user> GIT_TOKEN=ghp_xxxxxxxx \
    ./build-image.sh --board=micropanel --version=01.15
```

`GIT_TOKEN` must be a GitHub *Personal Access Token* with `repo` scope -
GitHub does not accept account passwords for git. The credentials are
written to a mode-0600 temp file, used only for the sources stage, and
deleted afterwards. They are intentionally environment variables, not
CLI flags: command-line arguments would be visible in `ps` and shell
history.

**Option C - skip remote auth entirely:** keep local checkouts of the
private repos and point the build at them with `--repobins=DIR`.

### 5. Clone and build

```bash
git clone https://github.com/hackboxguy/misc-tools.git
cd misc-tools
./build-image.sh --board=micropanel --dry-run     # validates everything first
sudo ./build-image.sh --board=micropanel --version=01.15
```

`--dry-run` runs the full preflight (host tools, binfmt, board files, hook
lists, local sources, git reachability, disk space) and prints the build
plan without touching anything - run it first on a fresh machine.

### 6. Flash

```bash
sudo ./build-image.sh --board=micropanel --version=01.15 --flash=/dev/sdX
# (stages skip via stamps; asks for confirmation before dd)
```

or manually: `sudo dd if=<image> of=/dev/sdX bs=8M status=progress conv=fsync`

## How a build works

| Stage   | What it does                                                | Engine |
|---------|-------------------------------------------------------------|--------|
| sources | clone/update dependent repos into `<workspace>/sources`     | git    |
| base    | vanilla `img.xz` → extended image + apt runtime/build deps (+ optional profile hooks) | `custom-pi-imager` (sdm) |
| kernel  | cross-compile kernel + out-of-tree drivers into the image   | `custom-pi-kernel-builder` |
| apps    | build/install apps via hooks in QEMU chroot, purge build deps | `custom-pi-imager` |

Each stage records a hash of its real inputs (dependency lists, hook lists
and scripts, kernel config, source repo revisions, remote hook revisions);
re-running the same command only rebuilds stages whose inputs changed.
Typical day-to-day flow: push changes to an app repo, re-run the build with
a bumped `--version` - base and kernel report `up-to-date (stamp match)`,
only the apps stage re-runs.

Everything lives in a workspace (default `~/pi-image-workspace`; avoid
tmpfs-backed `/tmp` - images are ~5GB): `downloads/` (vanilla image cache),
`sources/`, `kernel-build/`, `base/`, `kernel/`, `out/` (final images).

### Base profiles (shared base images)

Boards with similar package needs share one cached base image via a
**base profile** (`BASE_PROFILE=<name>` in board.conf → `base-configs/<name>/`):
the profile owns the base-stage apt lists, extend size, password and
optional profile hooks that bake heavy, rarely-changing components (e.g. a
compiled vsomeip) into the shared base. micropanel, pi4-touch-demo and
qt-cluster-demo share the `qt-common` profile (bookworm); `qt-trixie` is
the RaspiOS-trixie variant. The base build cost is paid once for all
boards of a profile. Base parameters must stay profile-owned - passing a
different `--extend-size-mb`/`--password` per board would make the shared
stamp ping-pong.

### Useful options (see `--help` for all)

- `--baseimage=FILE` / `--image-url=URL` - use your own vanilla image.
- `--start-from=FILE` - feed an already-prepared base(+kernel) image
  straight into the apps stage.
- `--sources-dir=DIR` / `--output-dir=DIR` / `--workspace=DIR` - relocate
  the repo clones, the final image, or everything.
- `--repobins=DIR` - use local checkouts for `file://${REPOBINS}/...` hook
  sources instead of the auto-cloned workspace sources.
- `--skip-*` / `--force-*` - override the automatic stage caching
  (`--skip-kernel` is handy for userspace-only iterations).
- `--variant=NAME` - board variants (e.g. `media-mux --variant=selfhosted-dlna`).
- `--debug` - on a hook failure, keep the chroot mounted for inspection.

## Repository layout

- `build-image.sh` - top-level orchestrator (see above).
- `custom-pi-imager/` - image customization engine (base + incremental
  modes, setup-hook mechanism). Run `custom-pi-imager.sh --help`.
- `custom-pi-kernel-builder/` - kernel + out-of-tree driver cross-build
  scripts (`scripts/00-build-all.sh`).
- `board-configs/<name>/` - one directory per buildable image type:
  `board.conf` (declarative config: image URL, deps, hook list, kernel
  settings, source repos), hook list(s), dependency lists and
  board-specific hook scripts in `packages/`.
- `base-configs/<name>/` - shared base profiles (`profile.conf`,
  `runtime-deps.txt`, `build-deps.txt`, optional `hooks.txt`).

## Adding a new board

1. `mkdir board-configs/myboard && cp board-configs/media-mux/board.conf board-configs/myboard/`
2. Adjust `board.conf` (set `KERNEL=0` unless you need custom drivers;
   set `BASE_PROFILE=qt-common` to reuse the shared Qt base).
3. Write `runtime-deps.txt` and a hook list; reuse
   `custom-pi-imager/packages/generic-package-hook.sh` for cmake-based
   git or local (`file://${REPOBINS}/...`) packages.
4. `./build-image.sh --board=myboard --dry-run`

## Troubleshooting

- **"arm64 binfmt not registered"** - `sudo systemctl restart systemd-binfmt.service`
  (needs `qemu-user-static-binfmt` installed).
- **Private repo clone fails in the sources stage** - set up auth (section 4);
  clones run as the invoking user, so `gh auth setup-git` done as your user
  also works under `sudo`.
- **git-lfs repos yield tiny pointer files** - run `git lfs install` once as
  your user (preflight checks for git-lfs when a board needs it).
- **Hook fails mid-build** - re-run with `--debug`; the chroot stays mounted
  and the failure banner prints inspection/cleanup commands.
- **Host disk pressure** - a full build needs ~15GB in the workspace and
  ≥2GB free on `/` (sdm/nspawn temp files); preflight checks both.
