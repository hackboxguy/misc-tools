# Custom Pi Imager - Technical Documentation

## Quick Start

**Two-stage workflow for creating custom Raspberry Pi 4 images:**

| Stage | Purpose | Build Time | Command |
|-------|---------|------------|---------|
| **1. Base** | System packages + build deps | ~15 min | `sudo ./custom-pi-imager.sh --mode=base --baseimage=raspios.img.xz --output=/tmp/pi-base --password=brb0x --extend-size-mb=1000 --runtime-package=runtime-deps.txt --builddep-package=build-deps.txt` |
| **2. Incremental** | Compile apps + purge deps | ~5 min | `sudo ./custom-pi-imager.sh --mode=incremental --baseimage=base.img.xz --output=/tmp/pi-custom --builddep-package=build-deps.txt --setup-hook=./app-build-hook.sh --post-build-script=finalize.sh` |

**What you get**: Bootable Pi4 image with hardware interfaces (I2C, UART), network tools (avahi, iperf3), and custom applications compiled from source with zero build dependency bloat.

**Jump to**: [Real-World Workflow](#real-world-workflow-example) | [Package Lists](#file-formats) | [Setup Hooks](#setup-hook-vs-post-build-script)

---

## Table of Contents

- [Quick Start](#quick-start) - Two-stage build commands
- [Overview](#overview) - Purpose and features
- [Architecture](#architecture) - Execution flow and structure
- [Dependencies](#dependencies) - Required packages and tools
- [Usage](#usage) - Command syntax and arguments
- [Real-World Workflow](#real-world-workflow-example) - **Production example with actual files**
  - [Stage 1: Base Image](#stage-1-base-image-creation) - System packages
  - [Stage 2: Application](#stage-2-incremental-customization) - Micropanel + config
  - [Deployment](#stage-3-deployment) - Writing to SD card
  - [Verification](#verification-checklist) - Post-boot checks
- [File Formats](#file-formats) - Package lists and config scripts
- [Technical Details](#technical-details) - SDM, QEMU, loop devices
- [Troubleshooting](#troubleshooting) - Common issues and solutions
- [Integration Examples](#integration-examples) - CI/CD, testing
- [Advanced: Kernel & Driver Compilation](#advanced-kernel--driver-compilation) - **Building custom kernels and drivers**
- [Best Practices](#best-practices) - Security, reproducibility
- [Summary](#summary) - Quick reference and next steps

---

## Overview

The `custom-pi-imager.sh` script is a comprehensive Bash-based automation tool designed for customizing Raspberry Pi OS (Debian-based) images on Arch Linux hosts. It uses a **mode-based two-stage workflow** to create bootable disk images with pre-configured settings, packages, and custom software compiled from source—all while maintaining zero build dependency bloat in the final image.

## Purpose

This tool addresses the need for reproducible, customized Raspberry Pi OS deployments by:
- Automating base image extraction and modification
- Enabling ARM64 image customization on x86_64 hosts via QEMU emulation
- Separating runtime dependencies from build dependencies (dual-purpose package management)
- Supporting compilation from source via generic setup hooks
- Auto-purging build tools after compilation (keeps images clean)
- Providing extensibility through custom configuration scripts

## Key Features

### 1. Mode-Based Architecture
- **Base Mode** (`--mode=base`): Install runtime packages + build dependencies
- **Incremental Mode** (`--mode=incremental`): Run setup hooks, compile from source, auto-purge build deps
- Mode-aware validation (only validates files needed for specific mode)
- Clear separation of concerns (system vs application layer)

### 2. Dual-Purpose Package Management
- **Runtime packages** (`--runtime-package`): Kept in final image (libraries, tools)
- **Build dependencies** (`--builddep-package`): Installed in base, purged in incremental
- Same file used in both modes (e.g., `build-deps.txt`)
- Zero bloat: Build tools downloaded once, used for compilation, then removed

### 3. Generic Setup Hooks
- Multiple `--setup-hook` scripts supported (compile different apps)
- Runs in ARM64 chroot via QEMU (native compilation experience)
- Access to apt-get for additional dependencies
- Environment variables: `MOUNT_POINT`, `PI_PASSWORD`, `IMAGE_WORK_DIR`

### 4. Base Image Management
- Accepts compressed (`.img.xz`) or uncompressed (`.img`) Raspberry Pi OS images
- Automatic extraction and validation
- Optional image extension (base mode only)
- Disk space checking with user warnings

### 5. User Authentication
- Configurable password for the `pi` user
- Preserves existing passwords when not specified
- Automatic SSH configuration with password authentication
- Security hardening (root login disabled)

### 6. ARM64 Emulation
- QEMU-based ARM64 emulation on x86_64 hosts
- Automatic binfmt_misc validation
- Chroot testing for reliability

## Architecture

### Mode-Based Workflow

```
┌──────────────────────────────────────────────────────────────┐
│                     BASE MODE (--mode=base)                  │
├──────────────────────────────────────────────────────────────┤
│ 1. Argument Parsing → Mode validation                       │
│ 2. Environment Check → Prerequisites                        │
│ 3. Workspace Setup → Cleanup old runs                       │
│ 4. Image Extraction → Decompression                         │
│ 5. SDM Integration → Resize/customize                       │
│ 6. Image Mounting → Loop device setup                       │
│ 7. QEMU Setup → ARM64 emulation                             │
│ 8. Password Config → User management                        │
│ 9. Package Install → Runtime + Build deps (both installed)  │
│10. Verification → Image validation                          │
│11. Cleanup → Unmount/detach                                 │
│12. Summary → Compress for incremental use                   │
└──────────────────────────────────────────────────────────────┘
                            ↓ compress with xz
┌──────────────────────────────────────────────────────────────┐
│                INCREMENTAL MODE (--mode=incremental)         │
├──────────────────────────────────────────────────────────────┤
│ 1. Argument Parsing → Mode validation                       │
│ 2. Environment Check → Prerequisites                        │
│ 3. Workspace Setup → Cleanup old runs                       │
│ 4. Image Extraction → Use base image                        │
│ 5. SDM Integration → Redo-customize (no resize)             │
│ 6. Image Mounting → Loop device setup                       │
│ 7. QEMU Setup → ARM64 emulation                             │
│ 8. Password Config → Preserved from base                    │
│ 9. Package Install → SKIPPED (already in base)              │
│10. Setup Hooks → Compile from source (multiple allowed)     │
│11. Post-Build Script → System configuration                 │
│12. Purge Build Deps → Remove cmake, g++, make, git, etc.    │
│13. Verification → Image validation                          │
│14. Cleanup → Unmount/detach                                 │
│15. Summary → Ready for deployment                           │
└──────────────────────────────────────────────────────────────┘
```

### Execution Flow (Detailed)

**Base Mode**:
1. Argument Parsing → Validate `--mode=base`, `--runtime-package`, `--builddep-package`
2. Environment Check → QEMU, SDM, binfmt prerequisites
3. Workspace Setup → Create `WORK_DIR`, cleanup old mounts
4. Image Extraction → Decompress `.img.xz` to `.img`
5. SDM Integration → Extend image by `--extend-size-mb`
6. Image Mounting → Loop device + partition mounting
7. QEMU Setup → Copy `qemu-aarch64-static`, mount proc/sys/dev
8. Password Config → Set/preserve pi user password
9. **Package Install** → Install runtime-package + builddep-package (both)
10. Verification → Check critical directories
11. Cleanup → Unmount, detach loop device
12. Summary → Instruct user to compress for reuse

**Incremental Mode**:
1. Argument Parsing → Validate `--mode=incremental`, `--builddep-package`, `--setup-hook`
2. Environment Check → QEMU, SDM, binfmt prerequisites
3. Workspace Setup → Create `WORK_DIR`, cleanup old mounts
4. Image Extraction → Decompress base image
5. SDM Integration → Redo-customize (no resize)
6. Image Mounting → Loop device + partition mounting
7. QEMU Setup → Copy `qemu-aarch64-static`, mount proc/sys/dev
8. Password Config → Inherited from base (skip if not specified)
9. **Package Install** → SKIPPED (packages already installed in base)
10. **Setup Hooks** → Run all `--setup-hook` scripts in chroot (compile apps)
11. **Post-Build Script** → System configuration (services, hardware)
12. **Purge Build Deps** → Remove packages from `--builddep-package`
13. Verification → Check critical directories
14. Cleanup → Unmount, detach loop device
15. Summary → Image ready for SD card writing

### Directory Structure

```
WORK_DIR/
├── {IMAGE_NAME}           # Modified .img file
├── mnt/                   # Mount point for image
│   ├── boot/firmware/     # Boot partition (p1)
│   ├── etc/, home/, ...   # Root filesystem (p2)
│   ├── usr/bin/qemu-*     # QEMU binary (temporary)
│   └── tmp/               # Setup hooks copied here for execution
└── loop_device            # Loop device tracking file
```

## Dependencies

### Required Packages (Arch Linux)
```bash
sudo pacman -S qemu-user-static qemu-user-static-binfmt
```

### Required Tools
- `sdm` - Raspberry Pi SD card image manager
- `unxz` - XZ decompression
- `losetup` - Loop device management
- `mount/umount` - Filesystem mounting
- `chroot` - Change root environment
- `openssl` - Password hashing

### System Requirements
- Root/sudo privileges
- ARM64 binfmt_misc support
- Sufficient disk space (5GB+ recommended)

## Usage

### Basic Syntax
```bash
sudo ./custom-pi-imager.sh --mode=MODE --baseimage=PATH --output=DIR --builddep-package=FILE [OPTIONS]
```

### Mandatory Arguments

| Argument | Description |
|----------|-------------|
| `--mode=MODE` | Build mode: `base` or `incremental` (REQUIRED) |
| `--baseimage=PATH` | Path to base Raspberry Pi OS image (.img.xz or .img) |
| `--output=DIR` | Output directory for image customization |
| `--builddep-package=FILE` | Build dependencies file (use `none` if not needed) |

### Optional Arguments (Base Mode)

| Argument | Default | Description |
|----------|---------|-------------|
| `--password=PASS` | [keep existing] | Password for 'pi' user |
| `--extend-size-mb=SIZE` | 0 | Image extension size in MB |
| `--runtime-package=FILE` | [none] | Runtime dependencies (kept in final image) |

### Optional Arguments (Incremental Mode)

| Argument | Default | Description |
|----------|---------|-------------|
| `--setup-hook=FILE` | [none] | Setup hook script (multiple allowed, runs in chroot) |
| `--post-build-script=FILE` | [none] | Post-build configuration script (runs in chroot) |

### Optional Arguments (Both Modes)

| Argument | Default | Description |
|----------|---------|-------------|
| `--password=PASS` | [keep existing] | Override password from base (incremental) or set new (base) |
| `--help, -h` | - | Show usage information |

### Usage Patterns

#### Pattern 1: Base Image Only (No Build Dependencies)
```bash
sudo ./custom-pi-imager.sh \
  --mode=base \
  --baseimage=./2024-07-04-raspios-bookworm-arm64.img.xz \
  --output=/tmp/pi-base \
  --password=mypass \
  --extend-size-mb=1000 \
  --runtime-package=./runtime-deps.txt \
  --builddep-package=none
```
- Sets password to 'mypass'
- Extends image by 1GB
- Installs runtime packages only
- No build dependencies (useful for runtime-only images)

#### Pattern 2: Base with Build Dependencies
```bash
sudo ./custom-pi-imager.sh \
  --mode=base \
  --baseimage=./raspios.img.xz \
  --output=/tmp/pi-base \
  --password=secure123 \
  --extend-size-mb=2000 \
  --runtime-package=./runtime-deps.txt \
  --builddep-package=./build-deps.txt
```
- Custom password
- 2GB additional space
- Installs both runtime and build dependencies
- Ready for incremental compilation stage

#### Pattern 3: Incremental Build (Recommended Two-Stage Workflow)
```bash
# Stage 1: Base image with dependencies
sudo ./custom-pi-imager.sh \
  --mode=base \
  --baseimage=./raspios.img.xz \
  --output=/tmp/pi-base \
  --password=mypass \
  --extend-size-mb=1000 \
  --runtime-package=./runtime-deps.txt \
  --builddep-package=./build-deps.txt

# Compress base for reuse
xz -k -9 /tmp/pi-base/*.img

# Stage 2: Compile applications and purge build deps
sudo ./custom-pi-imager.sh \
  --mode=incremental \
  --baseimage=/tmp/pi-base/*.img.xz \
  --output=/tmp/pi-custom \
  --builddep-package=./build-deps.txt \
  --setup-hook=./app1-build-hook.sh \
  --setup-hook=./app2-build-hook.sh \
  --post-build-script=./finalize.sh
```

#### Pattern 4: Multiple Setup Hooks
```bash
# Compile multiple applications from source
sudo ./custom-pi-imager.sh \
  --mode=incremental \
  --baseimage=./base.img.xz \
  --output=/tmp/multi-app \
  --builddep-package=./build-deps.txt \
  --setup-hook=./micropanel-build.sh \
  --setup-hook=./data-logger-build.sh \
  --setup-hook=./web-server-build.sh \
  --post-build-script=./configure-all.sh
```

## Real-World Workflow Example

This section demonstrates the actual production workflow used to create distributable Raspberry Pi 4 images with embedded systems tooling.

### Workflow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                   STAGE 1: BASE IMAGE (--mode=base)             │
├─────────────────────────────────────────────────────────────────┤
│ Input:  2025-10-01-raspios-bookworm-arm64-lite.img.xz         │
│ Args:   --mode=base --password=brb0x --extend-size-mb=1000    │
│         --runtime-package=runtime-deps.txt                      │
│         --builddep-package=build-deps.txt                       │
│                                                                 │
│ Process:                                                        │
│   1. Extract RaspiOS Lite → 3.2GB                              │
│   2. Extend by 1GB → 4.2GB                                      │
│   3. Set password & enable SSH                                  │
│   4. Install runtime packages (i2c-tools, avahi, iperf3, etc.) │
│   5. Install build dependencies (cmake, g++, make, git)         │
│                                                                 │
│ Output: 2025-10-01-raspios-bookworm-arm64-lite.img (4.2GB)    │
│         ↓ compress (xz -k -9)                                   │
│         2025-10-01-raspios-bookworm-arm64-lite-base.img.xz     │
│                                                                 │
│ ⏱️  Time: ~15 minutes                                           │
│ 💾 Store: Reusable base for multiple applications              │
│ 📦 Contains: Runtime deps + Build tools (cmake, g++, make)     │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│              STAGE 2: INCREMENTAL (--mode=incremental)          │
├─────────────────────────────────────────────────────────────────┤
│ Input:  2025-10-01-raspios-bookworm-arm64-lite-base.img.xz    │
│ Args:   --mode=incremental                                      │
│         --builddep-package=build-deps.txt                       │
│         --setup-hook=./micropanel-setup-hook.sh                 │
│         --post-build-script=./finalize.sh                       │
│                                                                 │
│ Process:                                                        │
│   1. Use base image (password brb0x preserved)                  │
│   2. Run micropanel-setup-hook.sh in chroot:                    │
│      • Clone https://github.com/hackboxguy/micropanel.git       │
│      • cmake → make → make install                              │
│      • Install to /home/pi/micropanel                           │
│   3. Run finalize.sh:                                           │
│      • Tune network buffers (25MB)                              │
│      • Enable micropanel.service                                │
│      • Disable UART console                                     │
│      • Auto-load i2c-dev module                                 │
│   4. PURGE build dependencies (cmake, g++, make, git)           │
│                                                                 │
│ Output: 2025-10-01-raspios-bookworm-arm64-lite.img (4.1GB)    │
│                                                                 │
│ ⏱️  Time: ~5 minutes (no package reinstall!)                    │
│ 🚀 Deploy: Write to SD card → Boot Pi4                         │
│ ✨ Clean: Build tools auto-purged, zero bloat!                  │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                         DEPLOYMENT                              │
├─────────────────────────────────────────────────────────────────┤
│ Write:  sudo dd if=image.img of=/dev/sdX bs=8M status=progress│
│ Boot:   Insert SD → Power on Pi4                               │
│ Access: ssh pi@raspberrypi.local (password: brb0x)             │
│                                                                 │
│ ✅ Auto-configured:                                             │
│    • Root partition expands to fill SD                          │
│    • SSH enabled on boot                                        │
│    • Micropanel service starts                                  │
│    • I2C devices accessible (i2cdetect -y 1)                    │
│    • UART free for hardware (no kernel console)                 │
│    • mDNS resolves raspberrypi.local                            │
└─────────────────────────────────────────────────────────────────┘
```

### Project Structure
```
custom-pi-imager/
├── custom-pi-imager.sh                 # Main script (mode-based)
├── runtime-deps.txt                    # Runtime packages (kept in final image)
├── build-deps.txt                      # Build tools (purged after compilation)
├── micropanel-setup-hook.sh            # Example: Compile micropanel from GitHub
├── finalize.sh                         # Example: System configuration
└── docs/
    └── CLAUDE.md                        # This file
```

### Stage 1: Base Image Creation

**Objective**: Create a reusable base image with runtime + build dependencies

```bash
# Base image with runtime and build dependencies
sudo ./custom-pi-imager.sh \
    --mode=base \
    --baseimage=./2025-10-01-raspios-bookworm-arm64-lite.img.xz \
    --output=/tmp/pi-base \
    --password=brb0x \
    --extend-size-mb=1000 \
    --runtime-package=./runtime-deps.txt \
    --builddep-package=./build-deps.txt
```

**What happens**:
1. Extracts Raspberry Pi OS Lite (minimal, no desktop)
2. Extends image by 1GB for packages and future compilations
3. Sets user `pi` password to `brb0x`
4. Installs **runtime packages** (hardware libraries, tools - kept in final image)
5. Installs **build dependencies** (cmake, g++, make - will be purged in incremental stage)

**Runtime Packages** ([runtime-deps.txt](../runtime-deps.txt)):
```txt
# Network discovery and mDNS
avahi-daemon          # Enables raspberrypi.local hostname
avahi-utils           # mDNS utilities

# Hardware interfaces
fbi                   # Framebuffer imageviewer
fxload                # Firmware loader for USB devices
i2c-tools             # I2C bus utilities (i2cdetect, i2cget)
libftdi1              # FTDI USB-serial library
libhidapi-libusb0     # HID API for USB devices
libi2c-dev            # I2C development headers
libudev-dev           # udev development headers

# Network tools
iperf3                # Network bandwidth testing

# Development libraries
libcurl4-openssl-dev  # cURL with OpenSSL
nlohmann-json3-dev    # Modern C++ JSON library
```

**Build Dependencies** ([build-deps.txt](../build-deps.txt)):
```txt
# Build tools (will be purged in incremental mode)
cmake
g++
make
git
```

**Output**: `/tmp/pi-base/2025-10-01-raspios-bookworm-arm64-lite.img`

**Preserve the base**:
```bash
# Compress for storage/distribution
xz -k -9 /tmp/pi-base/*.img
mv /tmp/pi-base/*.img.xz ./2025-10-01-raspios-bookworm-arm64-lite-base.img.xz

# Archive for version control
md5sum ./2025-10-01-raspios-bookworm-arm64-lite-base.img.xz > base-image.md5
```

### Stage 2: Incremental Customization

**Objective**: Compile applications from source and configure system

```bash
# Incremental: Compile from source + configure + purge build deps
sudo ./custom-pi-imager.sh \
    --mode=incremental \
    --baseimage=./2025-10-01-raspios-bookworm-arm64-lite-base.img.xz \
    --output=/tmp/pi-custom \
    --builddep-package=./build-deps.txt \
    --setup-hook=./micropanel-setup-hook.sh \
    --post-build-script=./finalize.sh
```

**What happens**:
1. Uses previously created base image (runtime + build deps already installed)
2. Preserves `brb0x` password from base (inherited automatically)
3. Runs [micropanel-setup-hook.sh](../micropanel-setup-hook.sh) in ARM64 chroot:
   - Clones https://github.com/hackboxguy/micropanel.git
   - Compiles with cmake → make → make install (via QEMU)
   - Installs to `/home/pi/micropanel`
   - Configures systemd service, hardware (I2C, UART)
4. Runs [finalize.sh](../finalize.sh) for system-wide configuration (if provided)
5. **Automatically purges** build dependencies (cmake, g++, make, git) based on `build-deps.txt`

**Setup Hook Example** ([micropanel-setup-hook.sh](../micropanel-setup-hook.sh)):

```bash
#!/bin/bash
set -e

update_sysctl() {
    local key=$1
    local value=$2
    echo "${key} = ${value}" >> /etc/sysctl.conf
}

# [1/5] Install build dependencies (no-op if already in base)
apt-get install -y cmake g++ make git

# [2/5] Clone micropanel from GitHub
cd /tmp
git clone https://github.com/hackboxguy/micropanel.git
cd micropanel/build

# [3/5] Configure CMake
cmake -DCMAKE_INSTALL_PREFIX=/home/pi/micropanel \
      -DINSTALL_SYSTEMD_SERVICE=ON \
      -DSYSTEMD_UNITFILE_ARGS="-a -i gpio -s /dev/i2c-3" ..

# [4/5] Build (parallel compilation)
make -j$(nproc)

# [5/5] Install
make install
chown -R 1000:1000 /home/pi/micropanel

###### Finalize micropanel installation ######
# Update sysctl settings
update_sysctl "net.core.rmem_max" "26214400"      # 25MB
update_sysctl "net.core.wmem_max" "26214400"

# Resolve config paths
cp /home/pi/micropanel/etc/micropanel/config.json \
   /home/pi/micropanel/etc/micropanel/config-temp.json
/home/pi/micropanel/usr/bin/update-config-path.sh \
   --path=/home/pi/micropanel \
   --output=/home/pi/micropanel/etc/micropanel/config.json \
   --input=/home/pi/micropanel/etc/micropanel/config-temp.json

# Enable service
systemctl enable /home/pi/micropanel/lib/systemd/system/micropanel.service

# Configure hardware
cp /home/pi/micropanel/usr/share/micropanel/configs/config.txt /boot/firmware/
sed -i 's/^console=serial0,115200 //' /boot/firmware/cmdline.txt
echo 'i2c-dev' > /etc/modules-load.d/i2c.conf

# Cleanup source (build deps purged automatically by main script)
rm -rf /tmp/micropanel
```

**Hardware Optimizations**:
- **Network Buffers**: Optimized for high-speed data transfer (useful for iperf3 testing, network sensors)
- **UART Liberation**: Removes kernel console from serial port for direct hardware access
- **I2C Auto-load**: Ensures I2C bus available for sensors/peripherals without manual modprobe

**Output**: `/tmp/pi-custom/2025-10-01-raspios-bookworm-arm64-lite.img`

### Benefits of Two-Stage Workflow

| Aspect | Single Build | Two-Stage Build |
|--------|--------------|-----------------|
| **Time per iteration** | 15-20 minutes | **5-8 minutes** (stage 2 only) |
| **Package re-installation** | Every build | Once (stage 1) |
| **Flexibility** | Monolithic | Modular (swap applications) |
| **Testing** | Full rebuild for changes | Quick iteration on app/config |
| **Distribution** | Single variant | Multiple variants from one base |

**Use Cases**:
- **Development**: Rapidly test micropanel changes without re-installing system packages
- **Multiple Products**: Create different images (sensor variant, display variant) from same base
- **Version Control**: Base image pinned to specific package versions, application layers versioned independently

### Stage 3: Deployment

```bash
# 1. Verify image integrity
ls -lh /tmp/pi-custom/*.img
file /tmp/pi-custom/*.img

# 2. Write to SD card (identify device with lsblk)
sudo dd if=/tmp/pi-custom/2025-10-01-raspios-bookworm-arm64-lite.img \
  of=/dev/sdX \
  bs=8M \
  status=progress \
  conv=fsync

# 3. First boot (on Raspberry Pi 4)
# - Root partition auto-expands to fill SD card
# - Network: dhcp assigns IP, accessible via raspberrypi.local
# - SSH: ssh pi@raspberrypi.local (password: brb0x)
# - Micropanel service: systemctl status micropanel
# - I2C devices: i2cdetect -y 1
```

### Verification Checklist

After first boot, verify the customizations:

```bash
# 1. SSH access
ssh pi@raspberrypi.local
# Password: brb0x

# 2. Network buffers applied
sysctl net.core.rmem_max
# Expected: net.core.rmem_max = 26214400

# 3. Micropanel service running
systemctl status micropanel
# Expected: active (running)

# 4. I2C module loaded
lsmod | grep i2c_dev
# Expected: i2c_dev

# 5. UART console disabled
cat /boot/firmware/cmdline.txt | grep console
# Expected: no console=serial0,115200

# 6. Packages installed
dpkg -l | grep -E 'i2c-tools|avahi-daemon|iperf3'
# Expected: ii (installed) status

# 7. mDNS resolution
avahi-browse -a
# Expected: service advertisements
```

### Maintenance and Updates

#### Update Base Image
```bash
# When new RaspiOS release or package updates needed
sudo ./custom-pi-imager.sh \
    --baseimage=./2025-12-01-raspios-bookworm-arm64-lite.img.xz \
    --output=/tmp/pi-base-new \
    --password=brb0x \
    --extend-size-mb=1000 \
    --package-list=./package-list.txt

# Archive old base
mv 2025-10-01-*-base.img.xz archive/

# Promote new base
mv /tmp/pi-base-new/*.img.xz ./2025-12-01-raspios-bookworm-arm64-lite-base.img.xz
```

#### Update Application Only
```bash
# Modify micropanel code, then rebuild from existing base
sudo ./custom-pi-imager.sh \
    --baseimage=./2025-10-01-raspios-bookworm-arm64-lite-base.img.xz \
    --output=/tmp/pi-custom-v2 \
    --micropanel-source=./micropanel \
    --configure-script=./post-install.sh
```

#### Add/Remove Packages
```bash
# Edit package-list.txt
echo "python3-pip" >> package-list.txt

# Rebuild base (invalidates old base)
sudo ./custom-pi-imager.sh \
    --baseimage=./2025-10-01-raspios-bookworm-arm64-lite.img.xz \
    --output=/tmp/pi-base-updated \
    --password=brb0x \
    --extend-size-mb=1000 \
    --package-list=./package-list.txt
```

## Setup Hook vs Post-Build Script

The tool supports two types of customization scripts with different purposes:

### Setup Hook (`--setup-hook`)
**Purpose**: Build and install custom applications from source
**Execution**: Runs in chroot environment (ARM64 via QEMU) during incremental mode
**When to use**: Compile code, install applications, build from git
**Multiple allowed**: Yes - you can specify multiple `--setup-hook` arguments

**Environment Variables**:
- `MOUNT_POINT`: Root filesystem mount point
- `PI_PASSWORD`: User password (empty if unchanged)
- `IMAGE_WORK_DIR`: Working directory path

**Example: [micropanel-setup-hook.sh](../micropanel-setup-hook.sh)**
```bash
#!/bin/bash
set -e

# Build dependencies already installed in base mode
# Clone and build
git clone https://github.com/hackboxguy/micropanel.git /tmp/mp
cd /tmp/mp/build
cmake -DCMAKE_INSTALL_PREFIX=/home/pi/micropanel ..
make -j$(nproc) && make install
chown -R 1000:1000 /home/pi/micropanel

# Configure systemd, hardware
systemctl enable /home/pi/micropanel/lib/systemd/system/micropanel.service
cp /home/pi/micropanel/usr/share/micropanel/configs/config.txt /boot/firmware/
echo 'i2c-dev' > /etc/modules-load.d/i2c.conf

# Cleanup source (build deps purged automatically by main script)
rm -rf /tmp/mp
```

**Key Features**:
- Build dependencies already installed (from base mode)
- Native ARM64 compilation via QEMU
- Can clone from git repositories
- **No manual purge needed** - main script auto-purges build deps after all hooks complete

### Post-Build Script (`--post-build-script`)
**Purpose**: System-wide configuration (networking, static IP, additional services)
**Execution**: Runs in chroot after all setup hooks complete (incremental mode only)
**When to use**: Additional system configuration not handled by setup hooks

**Environment Variables**:
- `MOUNT_POINT`: Root filesystem mount point
- `PI_PASSWORD`: User password
- `IMAGE_WORK_DIR`: Working directory path

**Example: finalize.sh**
```bash
#!/bin/bash
set -e

# Additional network tuning
echo "net.ipv4.tcp_window_scaling = 1" >> /etc/sysctl.conf

# Configure static IP
cat >> /etc/dhcpcd.conf <<EOF
interface eth0
static ip_address=192.168.1.100/24
static routers=192.168.1.1
EOF

# Set hostname
echo "pi-device-001" > /etc/hostname
```

### Execution Order (Incremental Mode)
```
1. install_packages    → SKIPPED (already in base)
2. run_setup_hooks     → Execute all --setup-hook scripts
3. run_post_build_script → Execute --post-build-script
4. purge_build_dependencies → Auto-purge build deps from --builddep-package
```

### When to Use Which?

| Task | Use |
|------|-----|
| Compile C++ application from GitHub | `--setup-hook` |
| Build Rust/Go/Python app from source | `--setup-hook` |
| Clone git repository and build | `--setup-hook` |
| Enable systemd service for built app | `--setup-hook` (same script) |
| Configure hardware (I2C, SPI, UART) for app | `--setup-hook` (same script) |
| Additional network configuration | `--post-build-script` |
| Configure static IP / WiFi | `--post-build-script` |
| Additional sysctl tuning | `--post-build-script` |
| Install system-wide config files | `--post-build-script` |

**Best Practice**: Include hardware/service configuration in the same `--setup-hook` script that builds the application. Use `--post-build-script` only for additional system-wide configuration not tied to a specific application.

### Both Can Be Used Together
```bash
sudo ./custom-pi-imager.sh \
    --mode=incremental \
    --baseimage=base.img.xz \
    --output=/tmp/custom \
    --builddep-package=./build-deps.txt \
    --setup-hook=./micropanel-build.sh \  # Build + configure micropanel
    --setup-hook=./logger-build.sh \      # Build + configure data logger
    --post-build-script=./finalize.sh     # System-wide final config
```

## File Formats

### Runtime Package File (runtime-deps.txt)
```bash
# Runtime dependencies (kept in final image)
avahi-daemon
avahi-utils
i2c-tools
iperf3
libcurl4-openssl-dev
libi2c-dev
nlohmann-json3-dev

# Empty lines and comments ignored
```

### Build Dependency File (build-deps.txt)
```bash
# Build tools (purged after compilation in incremental mode)
cmake
g++
make
git

# Can also include language-specific build tools
# python3-dev
# cargo
# golang-go
```

### Custom Configuration Script

The configuration script runs inside the chroot environment with full access to the filesystem. It receives environment variables from the main script.

**Available Environment Variables**:
- `MOUNT_POINT`: Root filesystem mount point (e.g., `/tmp/pi-custom/mnt`)
- `PI_PASSWORD`: User password (empty string if unchanged)
- `MICROPANEL_INSTALLED`: "true" or "false"
- `IMAGE_WORK_DIR`: Working directory path (e.g., `/tmp/pi-custom`)

**Example: post-install.sh** (actual production script):

```bash
#!/bin/bash
set -e

# Helper function to update sysctl
update_sysctl() {
    local key=$1
    local value=$2
    echo "${key} = ${value}" >> /etc/sysctl.conf
}

# Update sysctl settings for network buffer optimization
update_sysctl "net.core.rmem_max" "26214400"      # 25MB max receive buffer
update_sysctl "net.core.wmem_max" "26214400"      # 25MB max send buffer
update_sysctl "net.core.rmem_default" "1310720"   # 1.25MB default receive
update_sysctl "net.core.wmem_default" "1310720"   # 1.25MB default send

# Enable micropanel service if installed
if [ "$MICROPANEL_INSTALLED" = "true" ]; then
    systemctl enable /home/pi/micropanel/micropanel.service
    cp /home/pi/micropanel/configs/config.txt /boot/firmware/
fi

# Enable high-speed UART (remove console to free serial port)
sed -i 's/^console=serial0,115200 //' /boot/firmware/cmdline.txt

# Enable i2c module auto-load on boot
echo 'i2c-dev' > /etc/modules-load.d/i2c.conf

echo "Custom configuration complete!"
```

**Additional Examples**:

<details>
<summary>Static IP Configuration</summary>

```bash
#!/bin/bash
# configure-network.sh

# Configure static IP for eth0
cat >> /etc/dhcpcd.conf <<EOF

# Static IP configuration
interface eth0
static ip_address=192.168.1.100/24
static routers=192.168.1.1
static domain_name_servers=8.8.8.8 1.1.1.1
EOF

# Set hostname
echo "pi-device-001" > /etc/hostname
sed -i 's/raspberrypi/pi-device-001/g' /etc/hosts
```
</details>

<details>
<summary>Install Python Application with Virtual Environment</summary>

```bash
#!/bin/bash
# install-python-app.sh

# Install pip if not in package list
apt-get install -y python3-pip python3-venv

# Create virtual environment in pi home
sudo -u pi python3 -m venv /home/pi/myapp/venv

# Install dependencies
sudo -u pi /home/pi/myapp/venv/bin/pip install -r /home/pi/myapp/requirements.txt

# Create systemd service
cat > /etc/systemd/system/myapp.service <<EOF
[Unit]
Description=My Python Application
After=network.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/myapp
ExecStart=/home/pi/myapp/venv/bin/python main.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl enable myapp.service
```
</details>

<details>
<summary>Configure WiFi with Static IP</summary>

```bash
#!/bin/bash
# configure-wifi.sh

WIFI_SSID="MyNetwork"
WIFI_PASSWORD="MyPassword"

# Configure wpa_supplicant
cat > /etc/wpa_supplicant/wpa_supplicant.conf <<EOF
country=US
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="${WIFI_SSID}"
    psk="${WIFI_PASSWORD}"
    key_mgmt=WPA-PSK
}
EOF

# Static IP for wlan0
cat >> /etc/dhcpcd.conf <<EOF

interface wlan0
static ip_address=192.168.1.101/24
static routers=192.168.1.1
static domain_name_servers=8.8.8.8
EOF
```
</details>

<details>
<summary>Hardware Enablement (SPI, I2C, Camera)</summary>

```bash
#!/bin/bash
# enable-hardware.sh

# Enable SPI, I2C, Camera in config.txt
cat >> /boot/firmware/config.txt <<EOF

# Hardware interfaces
dtparam=spi=on
dtparam=i2c_arm=on
start_x=1
gpu_mem=128

# Overclock (Pi 4)
over_voltage=6
arm_freq=2000
EOF

# Load modules on boot
cat > /etc/modules-load.d/hardware.conf <<EOF
i2c-dev
i2c-bcm2835
spi-bcm2835
EOF

# I2C tools permissions
usermod -aG i2c pi
```
</details>

## Technical Details

### SDM Integration

The script leverages [SDM (SD card Manager)](https://github.com/gitbls/sdm) for core image operations:

```bash
sdm --batch \
  --extend --xmb 1000 \              # Extend by 1000MB
  --customize \                       # Enable customization
  --plugin user:"adduser=pi|password=..." \
  --plugin disables:piwiz \          # Disable first-boot wizard
  --expand-root \                    # Auto-expand on first boot
  --nowait-timesync \                # Skip time sync wait
  image.img
```

#### SDM Modes
- **Extend mode** (`--extend`): Adds space to image, full customization
- **Redo mode** (`--redo-customize`): Re-customize without extending

### QEMU ARM64 Emulation

The script uses QEMU user-mode emulation to run ARM64 binaries on x86_64:

1. **Binfmt Registration**: Kernel automatically runs ARM64 binaries via QEMU
2. **Static Binary**: `/usr/bin/qemu-aarch64-static` copied to image
3. **Chroot Environment**: Full ARM64 environment with process/device access

```bash
# Verification check
grep -q "enabled" /proc/sys/fs/binfmt_misc/qemu-aarch64
```

### Loop Device Management

Images are mounted using loop devices with partition probing:

```bash
# Create loop device
losetup -P /dev/loop0 image.img

# Partitions available as:
# - /dev/loop0p1 (boot/firmware)
# - /dev/loop0p2 (root filesystem)
```

### Password Hashing

User passwords are hashed using SHA-512 (crypt format 6):

```bash
echo "password" | openssl passwd -6 -stdin
# Output: $6$rounds=5000$...(88 chars total)
```

### SSH Configuration

Automatic SSH hardening in `/etc/ssh/sshd_config`:
```
PasswordAuthentication yes    # Enable password login
PermitRootLogin no            # Disable root SSH
```

Service enabled via systemd symlink:
```bash
ln -sf /lib/systemd/system/ssh.service \
  /etc/systemd/system/multi-user.target.wants/ssh.service
```

## Error Handling

### Trap-Based Cleanup

The script uses EXIT trap for guaranteed cleanup:
```bash
trap cleanup EXIT

cleanup() {
    umount -l MOUNT_POINT/*
    losetup -d /dev/loopX
}
```

### Validation Points

1. **Prerequisites** (`check_prerequisites`): Tools and ARM64 support
2. **Arguments** (`parse_arguments`): Required parameters
3. **Disk Space** (`extract_image`): 5GB minimum
4. **Chroot Test** (`setup_qemu_chroot`): QEMU functionality
5. **Image Structure** (`verify_image`): Critical directories

### Path Normalization

All input paths converted to absolute to prevent chroot issues:
```bash
# Relative → Absolute
/path/to/image.xz → /absolute/path/to/image.xz
./packages.txt → /current/dir/packages.txt
```

## Security Considerations

### 1. Root Requirement
- Script requires `sudo` for mount/losetup operations
- Validates `EUID` before execution

### 2. Password Handling
- Passwords masked in output (`${PI_PASSWORD//?/*}`)
- SHA-512 hashing before storage
- No plaintext password storage

### 3. SSH Hardening
- Root login disabled
- Password authentication explicitly configured
- SSH service auto-enabled

### 4. SCP Authentication
- Supports `sshpass` for password-based SCP
- SSH keys recommended for production

## Troubleshooting

### Issue: ARM64 binfmt failed
```
ERROR: ARM64 binfmt failed. Try: sudo systemctl restart systemd-binfmt.service
```
**Solution**: Restart binfmt and verify:
```bash
sudo systemctl restart systemd-binfmt.service
cat /proc/sys/fs/binfmt_misc/qemu-aarch64
```

### Issue: Chroot test failed
```
ERROR: Chroot test failed
```
**Causes**:
- QEMU not properly copied
- Binfmt misconfiguration
- Missing ARM64 libraries

**Solution**:
```bash
# Verify QEMU
file /usr/bin/qemu-aarch64-static
# Should show: statically linked

# Check binfmt
update-binfmts --display qemu-aarch64
```

### Issue: Low space warning
```
WARNING: Low space: 3500MB
Continue? (y/N)
```
**Solution**: Free space or use different `--output` directory
```bash
df -h /tmp
# Compressed: ~1GB, Extracted: ~3-4GB, Final: ~5-8GB
```

### Issue: SDM not found
```
ERROR: sdm not found
```
**Solution**: Install SDM
```bash
git clone https://github.com/gitbls/sdm.git
cd sdm
sudo make install
```

### Issue: Loop device busy
```
ERROR: Partition /dev/loop0p2 not found
```
**Solution**: Clean up stale loop devices
```bash
sudo losetup -D  # Detach all
sudo losetup -a  # List active
```

## Performance Considerations

### Disk I/O
- **Extraction**: ~2-5 minutes (depends on CPU/disk)
- **Extension**: ~1-3 minutes per GB
- **Chroot operations**: Slower than native (QEMU overhead)

### Optimization Tips
1. **Use SSD** for `--output` directory
2. **Pre-decompress** large images for multiple builds
3. **Minimize packages** in package list
4. **Local micropanel** faster than SCP

### Resource Usage
- **Disk**: 5-10GB per build
- **RAM**: ~500MB-1GB (QEMU chroot)
- **CPU**: Moderate (compression/emulation)

## Integration Examples

### CI/CD Pipeline (GitLab)
```yaml
build-pi-image:
  stage: build
  image: archlinux:latest
  before_script:
    - pacman -Sy --noconfirm qemu-user-static qemu-user-static-binfmt
    - git clone https://github.com/gitbls/sdm.git && cd sdm && make install && cd ..
  script:
    - ./custom-pi-imager.sh
        --baseimage=raspios.img.xz
        --output=/builds/output
        --password=$PI_PASSWORD
        --package-list=packages.txt
        --configure-script=ci-config.sh
  artifacts:
    paths:
      - /builds/output/*.img
    expire_in: 1 week
```

### Automated Testing
```bash
#!/bin/bash
# test-runner.sh

for config in configs/*.txt; do
    name=$(basename "$config" .txt)
    ./custom-pi-imager.sh \
      --baseimage=base.img.xz \
      --output="/tmp/test-${name}" \
      --package-list="$config" \
      --configure-script=test-validator.sh

    # Validate output
    if [ -f "/tmp/test-${name}/"*.img ]; then
        echo "✓ Build ${name} succeeded"
    else
        echo "✗ Build ${name} failed"
        exit 1
    fi
done
```

### Multi-Stage Build
```bash
#!/bin/bash
# build-stages.sh

# Stage 1: Base system
./custom-pi-imager.sh \
  --baseimage=lite.img.xz \
  --output=/tmp/stage1 \
  --extend-size-mb=3000 \
  --package-list=base-packages.txt

# Compress stage 1
xz -k -9 /tmp/stage1/*.img

# Stage 2: Application layer
./custom-pi-imager.sh \
  --baseimage=/tmp/stage1/*.img.xz \
  --output=/tmp/stage2 \
  --micropanel-source=./app \
  --configure-script=app-setup.sh

# Final image
cp /tmp/stage2/*.img ./production-$(date +%Y%m%d).img
```

## Extending the Script

### Adding Custom Plugins

Create a plugin function:
```bash
install_docker() {
    log "Installing Docker..."
    chroot "${MOUNT_POINT}" /bin/bash <<'CHROOT_EOF'
curl -fsSL https://get.docker.com | sh
usermod -aG docker pi
systemctl enable docker
CHROOT_EOF
    log "Docker installed"
}
```

Add to main workflow:
```bash
main() {
    # ... existing steps ...
    install_packages
    install_docker  # Custom plugin
    copy_micropanel
    # ... remaining steps ...
}
```

### Custom Argument Parser
```bash
parse_arguments() {
    # ... existing code ...

    case $arg in
        # ... existing cases ...
        --enable-docker) INSTALL_DOCKER=true ;;
        --wifi-ssid=*) WIFI_SSID="${arg#*=}" ;;
        --wifi-pass=*) WIFI_PASS="${arg#*=}" ;;
    esac
}
```

## Advanced: Kernel & Driver Compilation

This section describes the **hybrid approach (Option 3)** for compiling custom Linux kernels and kernel drivers within the QEMU ARM64 chroot environment on an x86_64 host machine. This approach leverages the existing two-stage workflow and hook-script mechanism to build and install custom kernels directly into the Pi image.

### Why Compile Kernels in QEMU?

Traditional approaches for kernel compilation on x86 hosts:

| Approach | Method | Pros | Cons |
|----------|--------|------|------|
| **Option 1: Cross-Compilation** | Use `arm-linux-gnueabihf-gcc` on x86 | Fast compilation | Complex toolchain setup, path issues |
| **Option 2: Native Pi Build** | Compile on actual Raspberry Pi | 100% compatible | Very slow (hours), needs physical Pi |
| **Option 3: QEMU Hybrid** | Compile in ARM64 chroot via QEMU | Uses existing workflow, native toolchain | Moderate speed (slower than cross) |

**Option 3 (Hybrid Approach)** benefits:
- ✅ **No cross-compiler setup** - Uses native ARM64 gcc/make in chroot
- ✅ **Integrated workflow** - Fits into existing `--setup-hook` mechanism
- ✅ **Automatic installation** - `make modules_install` works directly in target image
- ✅ **Reproducible** - Kernel version locked in base image
- ✅ **Modular** - Build kernel in stage 2, reuse base image for testing

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│               STAGE 1: BASE IMAGE (--mode=base)                 │
├─────────────────────────────────────────────────────────────────┤
│  Input: RaspiOS Lite image                                      │
│                                                                 │
│  Install kernel build dependencies:                             │
│    • build-essential       (gcc, make, binutils)                │
│    • bc, bison, flex       (kernel build tools)                 │
│    • libssl-dev            (kernel crypto modules)              │
│    • libncurses-dev        (menuconfig support)                 │
│    • libelf-dev            (eBPF/BTF support)                   │
│    • kmod                  (module utilities)                   │
│    • git                   (fetch kernel source)                │
│                                                                 │
│  Output: base.img.xz (with kernel build tools installed)        │
│  Time: ~15-20 minutes                                           │
└─────────────────────────────────────────────────────────────────┘
                            ↓ compress with xz
┌─────────────────────────────────────────────────────────────────┐
│           STAGE 2: INCREMENTAL (--mode=incremental)             │
├─────────────────────────────────────────────────────────────────┤
│  Input: base.img.xz (from stage 1)                              │
│                                                                 │
│  --setup-hook=./kernel-build-hook.sh:                           │
│    1. Clone/download Raspberry Pi kernel source                 │
│       - git clone --depth=1 --branch=rpi-6.6.y \                │
│         https://github.com/raspberrypi/linux.git                │
│    2. Configure kernel (.config)                                │
│       - Use bcm2711_defconfig (Pi 4)                            │
│       - Customize via scripts/config (enable/disable features)  │
│    3. Compile kernel image                                      │
│       - make -j$(nproc) Image.gz                                │
│       - Time: 30-90 minutes in QEMU                             │
│    4. Compile device tree blobs (DTBs)                          │
│       - make -j$(nproc) dtbs                                    │
│    5. Compile kernel modules                                    │
│       - make -j$(nproc) modules                                 │
│    6. Compile custom driver modules (optional)                  │
│       - cd /path/to/driver && make                              │
│    7. Install kernel to /boot/firmware                          │
│       - cp arch/arm64/boot/Image.gz /boot/firmware/kernel8.img  │
│    8. Install device trees                                      │
│       - cp arch/arm64/boot/dts/broadcom/*.dtb /boot/firmware/   │
│    9. Install kernel modules                                    │
│       - make modules_install (installs to /lib/modules/)        │
│   10. Install custom driver modules                             │
│       - insmod or copy to /lib/modules/$(uname -r)/extra/       │
│   11. Update boot config                                        │
│       - Edit /boot/firmware/config.txt if needed                │
│   12. Generate initramfs (if required)                          │
│       - update-initramfs -c -k <version>                        │
│                                                                 │
│  --post-build-script=./finalize.sh:                             │
│    • Configure module auto-loading (/etc/modules-load.d/)       │
│    • Set kernel boot parameters (/boot/firmware/cmdline.txt)    │
│                                                                 │
│  Purge kernel build dependencies:                               │
│    • Auto-removes gcc, make, headers (saves ~500MB)             │
│                                                                 │
│  Output: custom.img (with custom kernel + drivers)              │
│  Time: ~30-90 minutes (kernel compilation in QEMU)              │
└─────────────────────────────────────────────────────────────────┘
```

### Workflow: Compiling Custom Kernel

#### Step 1: Prepare Kernel Build Dependencies

Create a dedicated build dependencies file for kernel compilation.

**File: `kernel-build-deps.txt`**
```bash
# Kernel compilation essentials
build-essential          # gcc, g++, make, dpkg-dev
bc                       # Basic calculator (kernel scripts)
bison                    # Parser generator (kernel config)
flex                     # Lexical analyzer (kernel config)
libssl-dev               # OpenSSL headers (kernel crypto)
libncurses-dev           # Ncurses headers (make menuconfig)
libelf-dev               # ELF headers (eBPF/BTF support)
kmod                     # Kernel module utilities (modprobe, insmod)
git                      # Fetch kernel source
wget                     # Download kernel patches
rsync                    # Install kernel files
cpio                     # Initramfs generation
```

**File: `runtime-deps.txt`** (keep kernel runtime dependencies)
```bash
# Kernel runtime (keep in final image)
kmod                     # Module loading utilities
initramfs-tools          # Boot ramdisk tools (if using initramfs)
firmware-brcm80211       # WiFi/Bluetooth firmware (if needed)
```

#### Step 2: Create Base Image with Kernel Build Tools

```bash
# Stage 1: Base image with kernel build dependencies
sudo ./custom-pi-imager.sh \
    --mode=base \
    --baseimage=./2025-10-01-raspios-bookworm-arm64-lite.img.xz \
    --output=/tmp/pi-kernel-base \
    --password=kerneldev \
    --extend-size-mb=3000 \
    --runtime-package=./runtime-deps.txt \
    --builddep-package=./kernel-build-deps.txt

# Compress base for reuse (important: kernel compilation takes time!)
xz -k -9 /tmp/pi-kernel-base/*.img
mv /tmp/pi-kernel-base/*.img.xz ./kernel-base.img.xz
```

**Note**: Extend by at least **3GB** for kernel source (~1.5GB) + build artifacts (~1GB).

#### Step 3: Create Kernel Build Hook Script

This is the main script that compiles the kernel. See the next section for a complete example.

**File: `kernel-build-hook.sh`** (example structure)
```bash
#!/bin/bash
set -e

# [1/10] Clone Raspberry Pi kernel source
cd /usr/src
git clone --depth=1 --branch=rpi-6.6.y \
    https://github.com/raspberrypi/linux.git rpi-linux
cd rpi-linux

# [2/10] Configure kernel
make bcm2711_defconfig  # Pi 4 default config

# [3/10] Customize kernel config (optional)
scripts/config --enable CONFIG_MY_DRIVER
scripts/config --module CONFIG_USB_SERIAL

# [4/10] Build kernel image (30-90 minutes in QEMU)
make -j$(nproc) Image.gz

# [5/10] Build device tree blobs
make -j$(nproc) dtbs

# [6/10] Build kernel modules
make -j$(nproc) modules

# [7/10] Install kernel image
cp arch/arm64/boot/Image.gz /boot/firmware/kernel8.img

# [8/10] Install device trees
cp arch/arm64/boot/dts/broadcom/bcm2711-rpi-4-b.dtb /boot/firmware/

# [9/10] Install kernel modules
make modules_install

# [10/10] Cleanup source (optional, saves space)
cd /usr/src && rm -rf rpi-linux
```

#### Step 4: Compile Kernel in Incremental Mode

```bash
# Stage 2: Compile kernel from base
sudo ./custom-pi-imager.sh \
    --mode=incremental \
    --baseimage=./kernel-base.img.xz \
    --output=/tmp/pi-custom-kernel \
    --builddep-package=./kernel-build-deps.txt \
    --setup-hook=./kernel-build-hook.sh \
    --post-build-script=./finalize.sh

# Result: custom.img with your kernel installed
# Build tools (gcc, make, headers) automatically purged
```

#### Step 5: Deployment and Testing

```bash
# Write to SD card
sudo dd if=/tmp/pi-custom-kernel/*.img of=/dev/sdX bs=8M status=progress

# Boot Raspberry Pi 4
# SSH access: ssh pi@raspberrypi.local

# Verify kernel version
uname -r
# Expected: 6.6.x+ (or your compiled version)

# Check loaded modules
lsmod

# Check custom driver (if compiled)
modprobe my_custom_driver
dmesg | tail
```

### Custom Kernel Driver Compilation

To compile custom out-of-tree kernel drivers alongside the kernel:

#### Option A: In-Tree Driver (Recommended)

Add your driver to the kernel source tree and enable it in the config.

**In `kernel-build-hook.sh`:**
```bash
#!/bin/bash
set -e

# Clone kernel
cd /usr/src
git clone --depth=1 --branch=rpi-6.6.y \
    https://github.com/raspberrypi/linux.git rpi-linux
cd rpi-linux

# Add custom driver to kernel tree
mkdir -p drivers/custom
cp -r /path/to/my_driver/* drivers/custom/

# Update Kconfig and Makefile
echo 'obj-$(CONFIG_MY_DRIVER) += custom/' >> drivers/Makefile

# Configure kernel with driver enabled
make bcm2711_defconfig
scripts/config --module CONFIG_MY_DRIVER

# Build kernel + driver together
make -j$(nproc) Image.gz modules

# Install everything
cp arch/arm64/boot/Image.gz /boot/firmware/kernel8.img
make modules_install
```

#### Option B: Out-of-Tree Driver Module

Build driver separately after kernel compilation.

**File: `driver-build-hook.sh`** (separate hook)
```bash
#!/bin/bash
set -e

echo "Building custom kernel driver..."

# Ensure kernel headers are available
KERNEL_VERSION=$(ls /lib/modules/ | grep -v "$(uname -r)" | head -1)
KERNEL_SRC="/usr/src/rpi-linux"

# Clone/copy driver source
cd /tmp
git clone https://github.com/youruser/my-driver.git
cd my-driver

# Build driver against installed kernel
make -C ${KERNEL_SRC} M=$(pwd) modules

# Install driver module
mkdir -p /lib/modules/${KERNEL_VERSION}/extra
cp my_driver.ko /lib/modules/${KERNEL_VERSION}/extra/

# Update module dependencies
depmod -a ${KERNEL_VERSION}

# Auto-load on boot
echo 'my_driver' > /etc/modules-load.d/my_driver.conf

# Cleanup
cd /tmp && rm -rf my-driver

echo "Driver installed: /lib/modules/${KERNEL_VERSION}/extra/my_driver.ko"
```

**Usage with multiple hooks:**
```bash
sudo ./custom-pi-imager.sh \
    --mode=incremental \
    --baseimage=./kernel-base.img.xz \
    --output=/tmp/pi-custom \
    --builddep-package=./kernel-build-deps.txt \
    --setup-hook=./kernel-build-hook.sh \
    --setup-hook=./driver-build-hook.sh \
    --post-build-script=./finalize.sh
```

### Performance Considerations

Kernel compilation in QEMU is slower than native or cross-compilation:

| Environment | Time (Pi 4 kernel) | Notes |
|-------------|-------------------|-------|
| **Native Pi 4** | ~4-6 hours | Single-threaded, limited RAM |
| **QEMU ARM64** | ~30-90 minutes | Multi-core, depends on host CPU |
| **Cross-compile (x86)** | ~10-20 minutes | Fastest, requires toolchain setup |

**Optimization tips for QEMU compilation:**
- Use `make -j$(nproc)` to parallelize (uses all host cores)
- Compile on SSD (not HDD) for faster I/O
- Allocate sufficient RAM to host (8GB+ recommended)
- Use `--depth=1` for shallow git clones (saves time/space)
- Disable debug symbols: `scripts/config --disable DEBUG_INFO`

### Kernel Configuration Examples

#### Enable Custom Driver

```bash
# In kernel-build-hook.sh
cd /usr/src/rpi-linux

# Load default config
make bcm2711_defconfig

# Enable your driver as module
scripts/config --module CONFIG_MY_CUSTOM_DRIVER

# Enable specific subsystems
scripts/config --enable CONFIG_I2C
scripts/config --enable CONFIG_SPI
scripts/config --enable CONFIG_CAN
scripts/config --enable CONFIG_CAN_RAW

# Disable unneeded features (reduce build time)
scripts/config --disable CONFIG_WIRELESS
scripts/config --disable CONFIG_SOUND
scripts/config --disable CONFIG_DRM

# Apply changes
make olddefconfig
```

#### Interactive Configuration (menuconfig)

For advanced kernel customization, use `make menuconfig`:

```bash
# In kernel-build-hook.sh
cd /usr/src/rpi-linux
make bcm2711_defconfig

# Interactive TUI for kernel config (requires libncurses-dev)
make menuconfig

# Navigate and enable/disable options
# Save and exit

# Continue with compilation
make -j$(nproc) Image.gz modules
```

**Note**: `menuconfig` requires terminal interaction, so this is best done in a development workflow where you manually run the hook script, then capture the `.config` file for automated builds.

### Example: Complete Kernel Build Hook

**File: `kernel-build-hook.sh`** (production-ready example)

```bash
#!/bin/bash
set -e

echo "======================================"
echo "  Raspberry Pi Kernel Build Hook"
echo "======================================"
echo ""

KERNEL_BRANCH="rpi-6.6.y"
KERNEL_SRC="/usr/src/rpi-linux"
KERNEL_VERSION=""

echo "Running inside ARM64 chroot via QEMU"
echo "This will take 30-90 minutes depending on host CPU..."
echo ""

# [1/11] Clone kernel source
echo "[1/11] Cloning Raspberry Pi kernel (branch: ${KERNEL_BRANCH})..."
cd /usr/src
if [ -d "${KERNEL_SRC}" ]; then
    echo "Kernel source already exists, pulling latest..."
    cd ${KERNEL_SRC} && git pull
else
    git clone --depth=1 --branch=${KERNEL_BRANCH} \
        https://github.com/raspberrypi/linux.git rpi-linux
    cd ${KERNEL_SRC}
fi

# [2/11] Configure kernel
echo "[2/11] Configuring kernel (bcm2711_defconfig for Pi 4)..."
make bcm2711_defconfig

# [3/11] Customize configuration
echo "[3/11] Applying custom kernel configuration..."
scripts/config --enable CONFIG_I2C
scripts/config --enable CONFIG_I2C_CHARDEV
scripts/config --enable CONFIG_SPI
scripts/config --disable CONFIG_DEBUG_INFO  # Saves space and time

# Apply configuration changes
make olddefconfig

# [4/11] Extract kernel version
KERNEL_VERSION=$(make kernelrelease)
echo "Kernel version: ${KERNEL_VERSION}"

# [5/11] Build kernel image
echo "[5/11] Building kernel image (this takes the longest)..."
echo "Progress: Compiling with $(nproc) parallel jobs..."
make -j$(nproc) Image.gz 2>&1 | grep -E "(CC|LD|AS)" | tail -20

# [6/11] Build device tree blobs
echo "[6/11] Building device tree blobs..."
make -j$(nproc) dtbs

# [7/11] Build kernel modules
echo "[7/11] Building kernel modules..."
make -j$(nproc) modules 2>&1 | grep -E "Building modules" | tail -10

# [8/11] Install kernel image
echo "[8/11] Installing kernel image to /boot/firmware/kernel8.img..."
cp -v arch/arm64/boot/Image.gz /boot/firmware/kernel8.img

# [9/11] Install device tree blobs
echo "[9/11] Installing device tree blobs..."
cp -v arch/arm64/boot/dts/broadcom/bcm2711-rpi-4-b.dtb /boot/firmware/
cp -v arch/arm64/boot/dts/overlays/*.dtbo /boot/firmware/overlays/ 2>/dev/null || true

# [10/11] Install kernel modules
echo "[10/11] Installing kernel modules to /lib/modules/${KERNEL_VERSION}..."
make modules_install

# Update module dependencies
depmod -a ${KERNEL_VERSION}

# [11/11] Cleanup (optional, saves ~1.5GB)
echo "[11/11] Cleaning up build artifacts..."
make clean
# Uncomment to remove source entirely:
# cd /usr/src && rm -rf rpi-linux

echo ""
echo "======================================"
echo "  Kernel Build Complete!"
echo "======================================"
echo "Kernel Version:    ${KERNEL_VERSION}"
echo "Kernel Image:      /boot/firmware/kernel8.img"
echo "Modules Installed: /lib/modules/${KERNEL_VERSION}"
echo ""
echo "Note: Kernel build tools will be purged by main script"
echo "======================================"
```

### Troubleshooting Kernel Compilation

#### Issue: Out of space during compilation

**Error**: `No space left on device`

**Solution**: Increase `--extend-size-mb` in base mode (minimum 3000MB)

```bash
sudo ./custom-pi-imager.sh \
    --mode=base \
    --extend-size-mb=4000 \
    ...
```

#### Issue: QEMU compilation too slow

**Error**: Taking 2+ hours to compile

**Solutions**:
1. Use shallow clone: `git clone --depth=1`
2. Disable debug info: `scripts/config --disable DEBUG_INFO`
3. Reduce kernel features (disable drivers you don't need)
4. Use faster host machine (more CPU cores)

#### Issue: Kernel panic on boot

**Error**: Kernel panic after installing custom kernel

**Solutions**:
1. Check kernel version matches running Pi version
2. Ensure device tree blobs are installed correctly
3. Verify `/boot/firmware/config.txt` points to correct kernel:
   ```
   kernel=kernel8.img
   ```
4. Boot with fallback kernel: rename `kernel8.img` → `kernel8-custom.img`

#### Issue: Module not loading

**Error**: `modprobe: FATAL: Module my_driver not found`

**Solutions**:
```bash
# Verify module is installed
find /lib/modules/ -name "my_driver.ko"

# Update module dependencies
depmod -a

# Check for errors
dmesg | grep -i error
```

### Best Practices for Kernel Development

1. **Separate kernel base image**: Keep a dedicated base image with kernel build tools
2. **Version control `.config`**: Store kernel configuration in git for reproducibility
3. **Test incrementally**: Boot test each kernel change before adding drivers
4. **Backup working kernel**: Keep `kernel8.img.backup` for easy rollback
5. **Use shallow clones**: `--depth=1` saves time and space
6. **Clean builds**: Remove `/usr/src/rpi-linux` after installation (saves 1.5GB)
7. **Module staging**: Test drivers as out-of-tree first, then integrate in-tree

### Integration with CI/CD

Automate kernel builds for reproducible deployments:

```yaml
# .gitlab-ci.yml example
build-kernel-image:
  stage: build
  script:
    - sudo ./custom-pi-imager.sh --mode=base --baseimage=raspios.img.xz
        --output=/tmp/kernel-base --extend-size-mb=4000
        --runtime-package=runtime-deps.txt
        --builddep-package=kernel-build-deps.txt
    - xz -k -9 /tmp/kernel-base/*.img
    - sudo ./custom-pi-imager.sh --mode=incremental
        --baseimage=/tmp/kernel-base/*.img.xz --output=/tmp/custom
        --builddep-package=kernel-build-deps.txt
        --setup-hook=./kernel-build-hook.sh
  artifacts:
    paths:
      - /tmp/custom/*.img
    expire_in: 1 week
```

### Summary: Hybrid Kernel Compilation Approach

**Advantages**:
- ✅ No cross-compiler toolchain setup required
- ✅ Native ARM64 compilation ensures 100% compatibility
- ✅ Integrated with existing two-stage workflow
- ✅ Reusable base image (rebuild kernel quickly)
- ✅ Automatic module installation and dependency management
- ✅ Build dependencies auto-purged after compilation

**Ideal Use Cases**:
- Custom kernel patches for Pi projects
- Embedded systems with custom hardware drivers
- IoT devices with specific kernel requirements
- Security hardening (disable unused subsystems)
- Real-time kernel patches (PREEMPT_RT)
- Educational projects learning kernel development

**Time Investment**:
- Initial setup: ~15 minutes (base image creation)
- Per kernel build: ~30-90 minutes (QEMU compilation)
- Iteration cycles: ~40-100 minutes total (reuse base)

**Next Steps**:
1. Create `kernel-build-deps.txt` with required packages
2. Build kernel base image (stage 1)
3. Write `kernel-build-hook.sh` for your kernel version
4. Test kernel compilation (stage 2)
5. Add custom driver hooks as needed
6. Deploy and verify on physical Raspberry Pi 4

## Best Practices

### 1. Version Control
- Store package lists, config scripts in git
- Tag releases with image versions
- Document configuration changes

### 2. Security
- Never hardcode passwords in scripts
- Use environment variables or encrypted vaults
- Rotate SSH keys regularly

### 3. Testing
- Test images in QEMU before SD card writing
- Validate boot process
- Check service status post-boot

### 4. Documentation
- Maintain package list comments
- Document custom script purposes
- Version micropanel deployments

### 5. Reproducibility
- Pin package versions when critical
- Archive base images
- Use checksums for verification

## Deployment Workflow

### 1. Write to SD Card
```bash
# Identify SD card
lsblk

# Write image (replace /dev/sdX)
sudo dd if=/tmp/output/raspios.img \
  of=/dev/sdX \
  bs=8M \
  status=progress \
  conv=fsync

# Verify
sudo dd if=/dev/sdX \
  bs=8M \
  count=100 | md5sum
```

### 2. First Boot
```
1. Root filesystem auto-expands
2. Network configuration (DHCP/static)
3. SSH service starts
4. Custom services initialize
```

### 3. Post-Boot Verification
```bash
# SSH into Pi
ssh pi@raspberrypi.local

# Check services
systemctl status micropanel

# Verify packages
dpkg -l | grep -E 'vim|git|htop'

# Check logs
journalctl -u micropanel -f
```

## Appendix

### A. SDM Command Reference
- `--batch`: Non-interactive mode
- `--extend`: Resize image before customization
- `--xmb`: Extension size in MB
- `--customize`: Enable Phase 1 customization
- `--redo-customize`: Re-run without extension
- `--plugin`: Load SDM plugins (user, disables, etc.)
- `--expand-root`: Auto-expand root on first boot
- `--nowait-timesync`: Skip NTP wait

### B. Partition Layout
```
/dev/loop0
├── /dev/loop0p1: /boot/firmware (FAT32, ~500MB)
│   ├── bootcode.bin
│   ├── config.txt
│   └── kernel8.img
└── /dev/loop0p2: / (ext4, remainder)
    ├── /bin, /etc, /home, /usr, ...
    └── Auto-expanded on first boot
```

### C. Exit Codes
- `0`: Success
- `1`: Error (file not found, validation failed, etc.)
- Trap ensures cleanup on any exit

### D. Log Format
```
[YYYY-MM-DD HH:MM:SS] Message  # Standard log
[ERROR] Message                 # Fatal error
[WARNING] Message               # Warning
[INFO] Message                  # Informational
```

## Summary

### What This Tool Does

The `custom-pi-imager.sh` script automates the creation of production-ready Raspberry Pi 4 SD card images using a **mode-based two-stage workflow**:

1. **Base Mode**: Pre-install runtime packages + build dependencies
2. **Incremental Mode**: Compile applications from source + auto-purge build tools
3. **Result**: Clean images with zero build dependency bloat

### Why Mode-Based Two-Stage Build?

| Need | Solution |
|------|----------|
| **Fast iteration** | Base image cached, only rebuild application (5 min vs 15 min) |
| **Zero bloat** | Build tools (cmake, g++, make) auto-purged after compilation |
| **Multiple variants** | One base → multiple applications (sensor, display, gateway) |
| **Network efficiency** | Build deps downloaded once in base, reused across builds |
| **Dependency stability** | Package versions locked in base, app versions independent |
| **Clear workflow** | Required `--mode` argument prevents user confusion |

### Key Technologies

- **Mode-Based Architecture**: Explicit base vs incremental separation
- **Dual-Purpose Packages**: Install in base, purge in incremental (same file)
- **SDM**: Raspberry Pi image manager (resize, customize, plugins)
- **QEMU**: ARM64 emulation on x86_64 (compile natively from source)
- **Generic Setup Hooks**: Multiple hooks for building different applications
- **Auto-Purge**: Automatic cleanup of build dependencies

### Production Use Case

This tool is designed for embedded systems developers who need to:
- **Compile from source**: Build applications from GitHub within the image
- **Distribute clean images**: Zero build dependency bloat in final image
- **Deploy fleet of Pis**: Identical configuration, versioned base images
- **Network efficiency**: Download build tools once, compile multiple apps
- **Version control**: Separate base (system) and application layers

### Typical Hardware Integrations

Based on the package list and configuration:
- **I2C sensors**: Temperature, pressure, accelerometers (i2c-tools, libi2c-dev)
- **USB devices**: FTDI, HID devices (libftdi1, libhidapi)
- **Network apps**: Bandwidth testing, data streaming (iperf3, tuned buffers)
- **Serial communication**: UART freed from console for hardware protocols

### Project Files

| File | Purpose | When to Edit |
|------|---------|--------------|
| [custom-pi-imager.sh](../custom-pi-imager.sh) | Main build script (mode-based) | Adding features, fixing bugs |
| [runtime-deps.txt](../runtime-deps.txt) | Runtime packages (kept in image) | New library dependencies |
| [build-deps.txt](../build-deps.txt) | Build tools (auto-purged) | New compiler/build tool needs |
| [micropanel-setup-hook.sh](../micropanel-setup-hook.sh) | Compile micropanel from GitHub | Application build process |
| [finalize.sh](../finalize.sh) | System-wide config (optional) | Network, static IP, etc. |

### Common Workflows

```bash
# Stage 1: Create base (once, or when dependencies change)
sudo ./custom-pi-imager.sh --mode=base \
  --baseimage=raspios.img.xz --output=/tmp/base \
  --password=mypass --extend-size-mb=1000 \
  --runtime-package=runtime-deps.txt \
  --builddep-package=build-deps.txt

# Compress base for reuse
xz -k -9 /tmp/base/*.img

# Stage 2: Develop application (iterative)
# 1. Edit setup hook script (e.g., micropanel-setup-hook.sh)
# 2. Rebuild from base:
sudo ./custom-pi-imager.sh --mode=incremental \
  --baseimage=/tmp/base/*.img.xz --output=/tmp/test \
  --builddep-package=build-deps.txt \
  --setup-hook=./micropanel-setup-hook.sh \
  --post-build-script=./finalize.sh
# 3. Test on Pi
# 4. Repeat

# Production release
sudo ./custom-pi-imager.sh --mode=incremental \
  --baseimage=/tmp/base/*.img.xz --output=/tmp/release-v1.2 \
  --builddep-package=build-deps.txt \
  --setup-hook=./micropanel-setup-hook.sh \
  --post-build-script=./finalize.sh
xz -k -9 /tmp/release-v1.2/*.img  # Compress for distribution
```

### Next Steps

1. **Install prerequisites**: `sudo pacman -S qemu-user-static qemu-user-static-binfmt`
2. **Install SDM**: Clone from [github.com/gitbls/sdm](https://github.com/gitbls/sdm)
3. **Download RaspiOS**: Get Lite image from [raspberrypi.com](https://www.raspberrypi.com/software/operating-systems/)
4. **Create base**: Follow [Stage 1](#stage-1-base-image-creation)
5. **Build custom**: Follow [Stage 2](#stage-2-incremental-customization)
6. **Deploy**: Write to SD, boot Pi, verify

### References

- [Raspberry Pi OS Images](https://www.raspberrypi.com/software/operating-systems/)
- [SDM Project](https://github.com/gitbls/sdm)
- [QEMU User Emulation](https://www.qemu.org/docs/master/user/main.html)
- [Arch Linux ARM](https://archlinuxarm.org/)
- [Raspberry Pi Documentation](https://www.raspberrypi.com/documentation/)
- [systemd Service Files](https://www.freedesktop.org/software/systemd/man/systemd.service.html)

## Recent Additions & Improvements (2025-11-04)

This section documents recent enhancements made to the custom-pi-imager system, including debug mode, idempotent builds, and kernel compilation workflow optimizations.

### Debug Mode (`--debug`)

**Purpose**: Preserve mount state on build failures for investigation and manual recovery.

**Implementation**:
- Added `--debug` flag to command-line arguments
- Modified `error()` function to set `ERROR_OCCURRED` flag
- Enhanced `cleanup()` trap handler to detect errors and skip unmounting
- Created `error_on_debug_exit()` function with detailed recovery instructions

**Usage**:
```bash
sudo ./custom-pi-imager.sh \
    --mode=incremental \
    --debug \
    --baseimage=base.img.xz \
    --output=/tmp/custom \
    --setup-hook=./my-hook.sh
```

**On Error Behavior**:
```
[ERROR] Build failed!
[DEBUG MODE ACTIVE]

Image is still mounted for inspection:
  Mount point: /tmp/custom/mnt
  Loop device: /dev/loop0

To inspect the chroot environment:
  sudo chroot /tmp/custom/mnt /bin/bash

To manually retry the failed hook:
  sudo chroot /tmp/custom/mnt /tmp/hook-script.sh

To check available space:
  df -h /tmp/custom/mnt

To cleanup manually when done:
  sudo ./cleanup-debug.sh /tmp/custom
```

**Files Modified**:
- [custom-pi-imager.sh:29-33](../custom-pi-imager.sh) - Modified `error()` function
- [custom-pi-imager.sh:775-789](../custom-pi-imager.sh) - Enhanced `cleanup()` trap handler
- [custom-pi-imager.sh:800-870](../custom-pi-imager.sh) - Added `error_on_debug_exit()` function

**Helper Script**:
- [cleanup-debug.sh](../cleanup-debug.sh) - Standalone cleanup utility for debug sessions

### Keep Build Dependencies (`--keep-build-deps`)

**Purpose**: Skip automatic purge of build dependencies for iterative development.

**Use Cases**:
- Debugging build failures without reinstalling tools
- Iterating on compilation flags or build configurations
- Development workflows where multiple builds are needed

**Usage**:
```bash
sudo ./custom-pi-imager.sh \
    --mode=incremental \
    --keep-build-deps \
    --baseimage=base.img.xz \
    --output=/tmp/dev \
    --setup-hook=./compile-app.sh
```

**Implementation**:
- Added `KEEP_BUILD_DEPS` configuration variable
- Modified `purge_build_dependencies()` to check flag before purging
- Environment variable propagated to hook scripts

**Files Modified**:
- [custom-pi-imager.sh:19](../custom-pi-imager.sh) - Added `KEEP_BUILD_DEPS=false` variable
- [custom-pi-imager.sh:740-755](../custom-pi-imager.sh) - Modified `purge_build_dependencies()`

### Idempotent Hook Execution

**Purpose**: Enable resumable builds by detecting already-completed work and skipping redundant steps.

**Implementation Levels**:

#### Level 1: Simple File Checks
```bash
if [ -f /path/to/artifact ]; then
    echo "✓ Already built, skipping"
else
    # Build artifact
fi
```

#### Level 2: Multi-Stage Checks (Recommended)
```bash
# Check source
if [ -d "${SOURCE_DIR}/.git" ]; then
    echo "✓ Source exists, skipping clone"
    cd ${SOURCE_DIR}
else
    git clone ...
fi

# Check compiled artifacts
if [ -f arch/arm64/boot/Image.gz ]; then
    echo "✓ Kernel image exists, skipping compilation"
else
    make -j$(nproc) Image.gz
fi

# Always run installation (idempotent)
make install
```

**Kernel Build Idempotency**:

The [kernel-build-hook.sh](../kernel-build-hook.sh) implements Level 2 idempotency:

1. **Clone check** (line 24-34): Skips git clone if `/usr/src/rpi-linux/.git` exists
2. **Image check** (line 76-96): Skips kernel compilation if `arch/arm64/boot/Image.gz` exists
3. **DTB check** (line 101-115): Skips device tree compilation if `bcm2711-rpi-4-b.dtb` exists
4. **Module check** (line 121-148): Skips module build if `modules.order` exists AND `.ko` files present
5. **Installation** (line 150-190): Always runs (safe to re-run)

**DEBUG_MODE Integration**:

Hooks receive `DEBUG_MODE` environment variable:
```bash
if [ "$DEBUG_MODE" = "1" ] || [ "$DEBUG_MODE" = "true" ]; then
    echo "⚠️  Debug mode: Keeping source for inspection"
    # Don't delete build artifacts
else
    rm -rf /usr/src/build-artifacts
fi
```

**Files Modified**:
- [kernel-build-hook.sh:24-34](../kernel-build-hook.sh) - Source clone idempotency
- [kernel-build-hook.sh:76-96](../kernel-build-hook.sh) - Kernel image idempotency
- [kernel-build-hook.sh:101-115](../kernel-build-hook.sh) - DTB idempotency
- [kernel-build-hook.sh:121-148](../kernel-build-hook.sh) - Module idempotency
- [kernel-build-hook.sh:164-172](../kernel-build-hook.sh) - DEBUG_MODE source preservation

### Bug Fixes

#### 1. Inline Comments in Dependency Files
**Issue**: Package names with inline comments like `git # Source control` caused apt-get install failures.

**Fix**: Removed all inline comments from dependency files, keeping only clean package names.

**Files Fixed**:
- [unified-build-deps.txt](../unified-build-deps.txt)
- [kernel-build-deps.txt](../kernel-build-deps.txt)

#### 2. `set -e` Exit on Empty Local Sources
**Issue**: When no local sources existed, the script exited silently due to `set -e` catching the false return from `[ $sources_copied -gt 0 ] && info ...`.

**Fix**: Changed to if-statement to always return success:
```bash
# Before (fails with set -e when sources_copied=0)
[ $sources_copied -gt 0 ] && info "Copied sources"

# After (always succeeds)
if [ $sources_copied -gt 0 ]; then
    info "Copied $sources_copied source(s)"
fi
```

**File Fixed**: [custom-pi-imager.sh:595-597](../custom-pi-imager.sh)

#### 3. basename Error in Debug Output
**Issue**: When showing debug instructions, `basename` received pipe-separated hook line as input, causing "extra operand" errors.

**Fix**: Extract just the hook script path before calling basename:
```bash
local last_hook="${SETUP_HOOKS[-1]}"
local hook_script_path="${last_hook%%|*}"  # Get before first |
echo "sudo chroot ${MOUNT_POINT} /tmp/$(basename "$hook_script_path")"
```

**File Fixed**: [custom-pi-imager.sh:825-829](../custom-pi-imager.sh)

#### 4. Redundant depmod Call
**Issue**: `make modules_install` already runs `depmod`, but script called it again manually. When `kmod` wasn't in PATH, this caused failures.

**Fix**: Removed redundant `depmod -a` call, relying on `make modules_install`.

**File Fixed**: [kernel-build-hook.sh:187-190](../kernel-build-hook.sh)

#### 5. Module Compilation Error Masking
**Issue**: `make -j$(nproc) modules 2>&1 | grep ... || true` masked compilation errors, always returning success.

**Fix**: Proper error handling without suppressing failures:
```bash
if ! make -j$(nproc) modules; then
    echo "ERROR: Module compilation failed!"
    echo "Check build output above for details"
    exit 1
fi
```

**File Fixed**: [kernel-build-hook.sh:130-134](../kernel-build-hook.sh)

### Space Requirements Updates

Based on actual kernel compilation testing, space requirements were updated:

#### Base Image Sizes

| Workload | Previous | Updated | Reason |
|----------|----------|---------|--------|
| **Application builds** | 1200-1500 MB | 1500-2000 MB | Safety margin |
| **Kernel builds** | 3000-4500 MB | **6000 MB** | /tmp tmpfs space for gcc temporary files |
| **Kernel + Apps** | 4500-5000 MB | **6500 MB** | Combined overhead |

**Space Breakdown (Kernel Build)**:
```
Kernel source (shallow):  ~1.2 GB
Build artifacts:          ~1.5 GB
Module compilation:       ~1.2 GB
Temporary files (/tmp):   ~1.0 GB (gcc assembly files during parallel build)
Safety margin:            ~600 MB
─────────────────────────
Total:                    ~5.5-6.0 GB
```

**Files Updated**:
- [docs/WORKFLOW_EXAMPLES.md:46](WORKFLOW_EXAMPLES.md) - Updated base creation example to 6000 MB
- [docs/WORKFLOW_EXAMPLES.md:279-290](WORKFLOW_EXAMPLES.md) - Updated space requirement breakdown

### Workflow Improvements

#### Unified Build Dependencies

Created `unified-build-deps.txt` combining application and kernel build dependencies:

**Structure**:
```bash
# Core Compilation Tools (shared)
build-essential, cmake, make, g++, git

# Kernel-Specific Requirements
bc, bison, flex, libssl-dev, libncurses-dev, libelf-dev, kmod, cpio, xz-utils

# Application-Specific Requirements
libusb-dev, libftdi-dev, libgpiod-dev, zlib1g-dev
qtbase5-dev, qtdeclarative5-dev

# Additional Utilities
wget, rsync
```

**Benefits**:
- ✅ Single base image for both kernel and application builds
- ✅ Maximum flexibility (can build apps, kernel, or both)
- ✅ Faster iteration (no need to switch base images)
- ✅ All build tools pre-installed in base (~20 min creation)

**File Added**: [unified-build-deps.txt](../unified-build-deps.txt)

#### Kernel Build Hook

Created production-ready kernel compilation hook with:
- Automatic kernel version detection
- Parallel compilation (`-j$(nproc)`)
- I2C and SPI enablement
- Debug info disabled (faster builds, smaller kernel)
- Automatic cleanup with DEBUG_MODE awareness

**Key Features**:
```bash
# [1/11] Clone kernel source (idempotent)
# [2/11] Configure kernel (bcm2711_defconfig)
# [3/11] Customize config (I2C, SPI, disable DEBUG_INFO)
# [4/11] Extract version (6.6.78-v8+)
# [5/11] Build kernel image (30-60 min)
# [6/11] Build device tree blobs
# [7/11] Build kernel modules (10-30 min)
# [8/11] Install kernel to /boot/firmware/kernel8.img
# [9/11] Install device tree blobs
# [10/11] Install kernel modules to /lib/modules/
# [11/11] Cleanup (remove source unless DEBUG_MODE=1)
```

**File Added**: [kernel-build-hook.sh](../kernel-build-hook.sh)

#### Cleanup Helper Script

Created standalone cleanup utility for debug sessions:

**Features**:
- Unmounts all chroot bind mounts (dev, sys, proc, boot/firmware)
- Detaches loop devices
- Removes debug marker files
- Provides post-cleanup instructions

**Usage**:
```bash
sudo ./cleanup-debug.sh /tmp/custom-kernel
```

**File Added**: [cleanup-debug.sh](../cleanup-debug.sh)

### Testing & Validation

All features were tested with real kernel compilation:

**Test Environment**:
- Host: Arch Linux x86_64, EPYC CPU, 64GB RAM
- Target: Raspberry Pi 4 (BCM2711)
- Base: RaspiOS Bookworm ARM64 Lite (2025-10-01)
- Kernel: 6.6.78-v8+ (rpi-6.6.y branch)

**Test Results**:
```
✅ Base image creation:     ~20 minutes
✅ Kernel compilation:      ~45 minutes (QEMU)
✅ Module compilation:      ~15 minutes (QEMU)
✅ Application builds:      ~10 minutes
✅ Total build time:        ~90 minutes
✅ Final image size:        5.8 GB
✅ Boot successful:         Yes
✅ Kernel version:          6.6.78-v8+
✅ I2C/SPI functional:      Yes
```

### Known Limitations

1. **Idempotency is per-run only**: If you stop and restart the script, workdir is cleaned and build starts fresh. (Future: `--resume` flag will address this)

2. **Kernel source not preserved by default**: After build, kernel source is deleted to save 1.2GB. (Future: `--keep-kernel-source` flag will preserve source for module development)

3. **No checkpoint/resume capability**: Long builds (60+ min) cannot be paused and resumed. Debug mode helps but requires manual intervention.

### Recommended Workflows

**Development (with debugging)**:
```bash
# Use debug mode and keep build deps for iteration
sudo ./custom-pi-imager.sh \
    --mode=incremental \
    --debug \
    --keep-build-deps \
    --baseimage=unified-base.img.xz \
    --output=/tmp/dev \
    --setup-hook=./my-app-hook.sh
```

**Production (clean build)**:
```bash
# No debug flags, purge all build deps
sudo ./custom-pi-imager.sh \
    --mode=incremental \
    --baseimage=unified-base.img.xz \
    --output=/tmp/production \
    --setup-hook=./kernel-build-hook.sh \
    --setup-hook-list=./app-packages.txt \
    --post-build-script=./finalize.sh
```

**Kernel + Applications**:
```bash
# Complete system: kernel + apps in one build
sudo ./custom-pi-imager.sh \
    --mode=incremental \
    --baseimage=unified-base.img.xz \
    --output=/tmp/complete \
    --builddep-package=./unified-build-deps.txt \
    --setup-hook=./kernel-build-hook.sh \
    --setup-hook-list=./micropanel-packages.txt \
    --version="FULL-01.00"
```

### Future Enhancements (Planned)

1. **`--resume` flag**: Skip workdir cleanup and image extraction, remount and continue from previous state
2. **`--keep-kernel-source` flag**: Preserve `/usr/src/rpi-linux` for out-of-tree module development
3. **Checkpoint system**: Save build state at key milestones for faster recovery
4. **Parallel hook execution**: Run independent hooks concurrently to reduce build time
5. **Module development workflow**: Documentation and tooling for building custom kernel modules

---

## License & Support

This script is designed for Arch Linux hosts and optimized for Raspberry Pi OS Debian distributions. For issues or contributions, refer to the project repository.

---

**Document Version**: 4.0 (Debug Mode + Idempotent Builds + Kernel Compilation)
**Last Updated**: 2025-11-04
**Compatible With**: Raspberry Pi OS (Bookworm/Bullseye), Raspberry Pi 4
**Example Files**: Real production usage with [unified-build-deps.txt](../unified-build-deps.txt), [kernel-build-hook.sh](../kernel-build-hook.sh), and [micropanel-packages.txt](../micropanel-packages.txt)
