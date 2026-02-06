# Custom Pi Imager Documentation

This directory contains documentation for the Custom Pi Imager tool - a flexible system for creating customized Raspberry Pi images.

## Overview

Custom Pi Imager uses a **two-stage build process**:

1. **Base Mode**: Creates a base image with runtime and build dependencies
2. **Incremental Mode**: Adds applications via hooks, then purges build dependencies

This separation enables:
- Fast iteration (rebuild apps without reinstalling packages)
- Smaller final images (build tools removed)
- Multiple product variants from one base

## Directory Structure

```
misc-tools/
├── custom-pi-imager/
│   ├── custom-pi-imager.sh          # Main build script
│   ├── cleanup-debug.sh             # Debug cleanup utility
│   ├── docs/
│   │   ├── README.md                # This file
│   │   ├── CLAUDE.md                # Complete technical docs
│   │   └── QUICKREF.md              # Quick reference card
│   └── packages/                    # Generic/shared hooks
│       └── generic-package-hook.sh
│
└── board-configs/                   # Board-specific configurations
    └── media-mux/                   # Media-Mux project config
        ├── media-mux-runtime-deps.txt
        ├── media-mux-runtime-deps-minimal.txt
        ├── media-mux-build-deps.txt
        ├── media-mux-packages.txt
        ├── media-mux-packages-extern-dlna.txt
        └── packages/
            ├── media-mux-hook.sh
            └── media-mux-bins-hook.sh
```

## Quick Start

### Prerequisites (Arch Linux)

```bash
# Install QEMU for ARM64 emulation
sudo pacman -S qemu-user-static qemu-user-static-binfmt

# Install SDM (Raspberry Pi image manager)
# See: https://github.com/gitbls/sdm
sdm --version

# For cross-compilation (optional)
sudo pacman -S aarch64-linux-gnu-gcc
```

### Basic Two-Stage Build

```bash
# Stage 1: Base image with dependencies
sudo ./misc-tools/custom-pi-imager/custom-pi-imager.sh \
  --mode=base \
  --baseimage=/path/to/raspios-bookworm-arm64-lite.img.xz \
  --output=/tmp/base \
  --password=mypassword \
  --extend-size-mb=2000 \
  --runtime-package=./misc-tools/board-configs/media-mux/media-mux-runtime-deps.txt \
  --builddep-package=./misc-tools/board-configs/media-mux/media-mux-build-deps.txt \
  --version="01.00"

# Stage 2: Install application and purge build deps
sudo ./misc-tools/custom-pi-imager/custom-pi-imager.sh \
  --mode=incremental \
  --baseimage=/tmp/base/*.img \
  --output=/tmp/final \
  --builddep-package=./misc-tools/board-configs/media-mux/media-mux-build-deps.txt \
  --setup-hook-list=./misc-tools/board-configs/media-mux/media-mux-packages.txt \
  --version="01.00"
```

## Command Reference

### Mandatory Arguments

| Argument | Description |
|----------|-------------|
| `--mode=MODE` | Build mode: `base` or `incremental` |
| `--baseimage=PATH` | Path to base Raspberry Pi OS image (.img or .img.xz) |
| `--output=DIR` | Output directory for customized image |
| `--builddep-package=FILE` | Build dependencies file (use `none` if not needed) |

### Optional Arguments (Base Mode)

| Argument | Description |
|----------|-------------|
| `--password=PASS` | Password for 'pi' user (default: keep existing) |
| `--extend-size-mb=SIZE` | Extend image size in MB (default: 0) |
| `--runtime-package=FILE` | Runtime dependencies to install |
| `--version=STRING` | Version identifier for /etc/base-version.txt |

### Optional Arguments (Incremental Mode)

| Argument | Description |
|----------|-------------|
| `--setup-hook=FILE` | Setup hook script (can specify multiple) |
| `--setup-hook-list=FILE` | File containing list of hooks to run |
| `--post-build-script=FILE` | Script to run after hooks complete |
| `--version=STRING` | Version identifier for /etc/incremental-version.txt |

### Optional Arguments (Both Modes)

| Argument | Description |
|----------|-------------|
| `--debug` | Keep image mounted on error for inspection |
| `--keep-build-deps` | Don't purge build dependencies |
| `--help` | Show help message |

## Media-Mux Build Examples

### Standard Build (compile on target)

```bash
# Stage 1: Base with build tools
sudo ./misc-tools/custom-pi-imager/custom-pi-imager.sh \
  --mode=base \
  --baseimage=/path/to/raspios-lite.img.xz \
  --output=/tmp/media-mux-base \
  --password=brb0x \
  --extend-size-mb=2000 \
  --runtime-package=./misc-tools/board-configs/media-mux/media-mux-runtime-deps.txt \
  --builddep-package=./misc-tools/board-configs/media-mux/media-mux-build-deps.txt \
  --version="01.00"

# Stage 2: Clone, compile, configure
sudo ./misc-tools/custom-pi-imager/custom-pi-imager.sh \
  --mode=incremental \
  --baseimage=/tmp/media-mux-base/*.img \
  --output=/tmp/media-mux-final \
  --builddep-package=./misc-tools/board-configs/media-mux/media-mux-build-deps.txt \
  --setup-hook-list=./misc-tools/board-configs/media-mux/media-mux-packages.txt \
  --version="01.00"
```

### Optimized Build (pre-compiled binaries)

Uses pre-compiled ARM64 binaries - no gcc, git, or npm needed on target.

```bash
# First, build the binaries package (on x86 host)
./build-bins.sh 01

# Stage 1: Minimal base (no build tools)
sudo ./misc-tools/custom-pi-imager/custom-pi-imager.sh \
  --mode=base \
  --baseimage=/path/to/raspios-lite.img.xz \
  --output=/tmp/media-mux-base \
  --password=brb0x \
  --extend-size-mb=1500 \
  --runtime-package=./misc-tools/board-configs/media-mux/media-mux-runtime-deps-minimal.txt \
  --builddep-package=none \
  --version="01.00"

# Stage 2: Download and install pre-compiled binaries
sudo ./misc-tools/custom-pi-imager/custom-pi-imager.sh \
  --mode=incremental \
  --baseimage=/tmp/media-mux-base/*.img \
  --output=/tmp/media-mux-final \
  --builddep-package=none \
  --setup-hook-list=./misc-tools/board-configs/media-mux/media-mux-packages-extern-dlna.txt \
  --version="01.00"
```

## Hook List File Format

Hook list files specify which setup hooks to run and their parameters.

### Simple Format
```
# Just the hook script path (relative to hook list file)
packages/my-hook.sh
```

### Parameterized Format
```
# HOOK_SCRIPT|GIT_REPO|GIT_TAG|INSTALL_DEST|DEP_LIST|POST_CMDS
packages/generic-package-hook.sh|https://github.com/user/repo.git|v1.0|/home/pi/app|cmake,build-essential

# Local source instead of git
packages/generic-package-hook.sh|file:///path/to/local/src|local|/home/pi/app|cmake
```

### Environment Variables Available to Hooks

| Variable | Description |
|----------|-------------|
| `MOUNT_POINT` | Root filesystem mount point |
| `PI_PASSWORD` | User password (if set) |
| `IMAGE_WORK_DIR` | Working directory path |
| `HOOK_GIT_REPO` | Git repository URL |
| `HOOK_GIT_TAG` | Git branch/tag/commit |
| `HOOK_INSTALL_DEST` | Installation destination |
| `HOOK_NAME` | Extracted from git repo name |
| `HOOK_DEP_LIST` | Comma-separated package list |
| `HOOK_LOCAL_SOURCE` | Path to local source (if file://) |
| `HOOK_POST_INSTALL_CMDS` | Post-install commands |

## Dependency File Format

Simple text files with one package per line:

```
# Comment lines start with #
package-name-1
package-name-2
# Empty lines are ignored

another-package
```

## Board Configs

Board-specific configurations are stored in `misc-tools/board-configs/<board-name>/`:

### Media-Mux Configuration Files

| File | Purpose |
|------|---------|
| `media-mux-runtime-deps.txt` | Runtime packages (kodi, avahi, nodejs, npm, pulseaudio) |
| `media-mux-runtime-deps-minimal.txt` | Minimal runtime (no npm - for pre-compiled builds) |
| `media-mux-build-deps.txt` | Build tools (gcc, git) |
| `media-mux-packages.txt` | Hook list for standard build |
| `media-mux-packages-extern-dlna.txt` | Hook list for pre-compiled build |
| `packages/media-mux-hook.sh` | Standard build hook (clone + compile) |
| `packages/media-mux-bins-hook.sh` | Pre-compiled binary installation hook |

### Creating a New Board Config

```bash
mkdir -p misc-tools/board-configs/my-board/packages

# Create dependency files
cat > misc-tools/board-configs/my-board/runtime-deps.txt << 'EOF'
# Runtime dependencies
package1
package2
EOF

# Create hook script
cat > misc-tools/board-configs/my-board/packages/setup-hook.sh << 'EOF'
#!/bin/bash
set -e
echo "Setting up my-board..."
# Your setup commands here
EOF
chmod +x misc-tools/board-configs/my-board/packages/setup-hook.sh

# Create hook list
echo "packages/setup-hook.sh" > misc-tools/board-configs/my-board/packages.txt
```

## Complete Build Walkthrough (Media-Mux PI4 Image)

Step-by-step instructions to create a bootable Media-Mux image from scratch.

### Prerequisites

```bash
# On Arch Linux host
sudo pacman -S qemu-user-static qemu-user-static-binfmt

# Install SDM (see https://github.com/gitbls/sdm)
# Verify installation:
sdm --version
```

### Step 1: Download Raspberry Pi OS Lite

```bash
cd $HOME
wget https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-11-19/2024-11-19-raspios-bookworm-arm64-lite.img.xz
```

### Step 2: Clone the Repository

```bash
git clone https://github.com/hackboxguy/misc-tools.git
cd misc-tools
```

### Step 3: Build Base Image (Stage 1)

```bash
sudo ./custom-pi-imager/custom-pi-imager.sh \
  --mode=base \
  --baseimage=$HOME/2024-11-19-raspios-bookworm-arm64-lite.img.xz \
  --output=/tmp/media-mux-base \
  --password=brb0x \
  --extend-size-mb=1000 \
  --runtime-package=./board-configs/media-mux/media-mux-runtime-deps-minimal.txt \
  --builddep-package=none \
  --version="01.00"
```

### Step 4: Build Final Image (Stage 2)

```bash
sudo ./custom-pi-imager/custom-pi-imager.sh \
  --mode=incremental \
  --baseimage=/tmp/media-mux-base/*.img \
  --output=/tmp/media-mux-final \
  --builddep-package=none \
  --setup-hook-list=./board-configs/media-mux/media-mux-packages-extern-dlna.txt \
  --version="01.00"
```

### Step 5: Write to SD Card

```bash
# Find your SD card device (e.g., /dev/sdb)
lsblk

# Write the image (replace /dev/sdX with your device)
sudo dd if=/tmp/media-mux-final/*.img of=/dev/sdX bs=4M status=progress
sync
```

### Step 6: Boot and Verify

1. Insert SD card into Raspberry Pi 4
2. Connect HDMI and power
3. Device will generate hostname from MAC address on first boot
4. Multiple devices auto-negotiate master/slave roles

## Pre-compiled Binaries (build-bins.sh)

For projects with compiled components, use `build-bins.sh` to create ARM64 binaries on x86.

See [media-mux/build-bins.sh](https://github.com/hackboxguy/media-mux/blob/master/build-bins.sh) for a complete example.

```bash
# Check dependencies
./build-bins.sh --check-only

# Build version 01
./build-bins.sh 01

# Build to custom directory
./build-bins.sh -o /tmp/bins 02

# Verbose output
./build-bins.sh -v 01
```

### Requirements
- `aarch64-linux-gnu-gcc` - ARM64 cross-compiler
- `npm` - For Node.js dependencies
- `tar`, `file` - Standard utilities

## Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| "Image is 99% full" | Increase `--extend-size-mb` in base mode |
| "Hook not found" | Check path in hook list file (relative to list file) |
| "404 downloading tarball" | Verify URL in hook script, check branch name |
| "qemu-aarch64 not found" | Install qemu-user-static and restart binfmt service |

### Debug Mode

```bash
# Keep image mounted on error for inspection
sudo ./custom-pi-imager.sh --debug ...

# After error, inspect the chroot:
sudo chroot /tmp/output/mnt /bin/bash

# Manual cleanup when done:
sudo /tmp/output/cleanup.sh /tmp/output
```

## Documents

| Document | Purpose |
|----------|---------|
| [README.md](README.md) | This overview and quick reference |
| [CLAUDE.md](CLAUDE.md) | Complete technical documentation |
| [QUICKREF.md](QUICKREF.md) | Command cheat sheet |

## Version Information

| Component | Version |
|-----------|---------|
| custom-pi-imager.sh | 2.0 |
| Documentation | 2.1 |
| Target OS | Raspberry Pi OS Bookworm (Debian 12) |
| Target Hardware | Raspberry Pi 3/4/5 |
| Host Platform | Arch Linux (recommended) |

**Last Updated**: 2026-02-05

---

**Quick Start** → See examples above
**Full Reference** → [CLAUDE.md](CLAUDE.md)
**Command Cheat Sheet** → [QUICKREF.md](QUICKREF.md)
