# misc-tools

Tools for building customized Raspberry Pi 4 SD-card images (RaspiOS lite
based), plus the board configurations that use them.

## Quick start: one-command image build

```bash
git clone https://github.com/hackboxguy/misc-tools.git
cd misc-tools

./build-image.sh --list-boards                 # what can be built
./build-image.sh --board=micropanel --dry-run  # preflight + plan (no root)
sudo ./build-image.sh --board=micropanel --version=01.15
sudo ./build-image.sh --board=media-mux --variant=selfhosted-dlna
```

The build runs in cached stages; re-running only rebuilds stages whose
inputs (dependency lists, hook lists, hook scripts, kernel config, source
repo revisions) actually changed:

| Stage   | What it does                                                | Engine |
|---------|-------------------------------------------------------------|--------|
| sources | clone/update dependent repos into `<workspace>/sources`     | git    |
| base    | vanilla `img.xz` → extended image + apt runtime/build deps  | `custom-pi-imager` (sdm) |
| kernel  | cross-compile kernel + out-of-tree drivers into the image   | `custom-pi-kernel-builder` |
| apps    | build/install apps via hooks in QEMU chroot, purge build deps | `custom-pi-imager` |

Everything lives in a workspace (default `~/pi-image-workspace`):
`downloads/` (vanilla image cache), `sources/`, `kernel-build/`,
`base/<board>/`, `kernel/<board>/`, `out/<board>/` (final images).

Useful options (see `--help` for all):

- `--dry-run` – full preflight (tools, files, hook lists, local sources,
  git reachability, disk space) plus a build plan; changes nothing.
- `--baseimage=FILE` / `--image-url=URL` – use your own vanilla image.
- `--start-from=FILE` – feed an already-prepared base(+kernel) image
  straight into the apps stage.
- `--repobins=DIR` – point `file://${REPOBINS}/...` hook sources at local
  checkouts instead of the auto-cloned workspace sources.
- `--force-*` / `--skip-*` – override the automatic stage caching.
- `--flash=/dev/sdX` – write the final image to an SD card (asks first).

## Repository layout

- `build-image.sh` – top-level orchestrator (see above).
- `custom-pi-imager/` – image customization engine (base + incremental
  modes, setup-hook mechanism). Run `custom-pi-imager.sh --help`.
- `custom-pi-kernel-builder/` – kernel + out-of-tree driver cross-build
  scripts (`scripts/00-build-all.sh`); host deps via
  `scripts/01-setup-arch-deps.sh` (Arch Linux).
- `board-configs/<name>/` – one directory per buildable image type:
  `board.conf` (declarative config: image URL, sizes, deps, hook list,
  kernel settings, source repos), hook list(s), dependency lists and
  board-specific hook scripts in `packages/`.

## Adding a new board

1. `mkdir board-configs/myboard && cp board-configs/media-mux/board.conf board-configs/myboard/`
2. Adjust `board.conf` (set `KERNEL=0` unless you need custom drivers).
3. Write `runtime-deps.txt`, `build-deps.txt` and a hook list; reuse
   `custom-pi-imager/packages/generic-package-hook.sh` for cmake-based
   git or local (`file://${REPOBINS}/...`) packages.
4. `./build-image.sh --board=myboard --dry-run`

## Host prerequisites (Arch Linux)

`sdm`, `qemu-user-static` + `qemu-user-static-binfmt` (arm64 binfmt
active), and for kernel boards the cross toolchain installed by
`custom-pi-kernel-builder/scripts/01-setup-arch-deps.sh`. `--dry-run`
reports anything missing.
