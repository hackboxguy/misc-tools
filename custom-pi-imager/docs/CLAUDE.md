# Custom Pi Imager - Technical Documentation

## Quick Start

**Two-stage workflow for creating custom Raspberry Pi 4 images:**

| Stage | Purpose | Build Time | Command |
|-------|---------|------------|---------|
| **1. Base** | System packages + password | ~15 min | `sudo ./custom-pi-imager.sh --baseimage=raspios.img.xz --output=/tmp/pi-base --password=brb0x --extend-size-mb=1000 --package-list=package-list.txt` |
| **2. Custom** | Application layer | ~5 min | `sudo ./custom-pi-imager.sh --baseimage=base.img.xz --output=/tmp/pi-custom --micropanel-source=./micropanel --configure-script=post-install.sh` |

**What you get**: Bootable Pi4 image with hardware interfaces (I2C, UART), network tools (avahi, iperf3), and custom application pre-configured.

**Jump to**: [Real-World Workflow](#real-world-workflow-example) | [Package List](#stage-1-base-image-creation) | [Post-Install Script](#stage-2-incremental-customization)

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
- [Best Practices](#best-practices) - Security, reproducibility
- [Summary](#summary) - Quick reference and next steps

---

## Overview

The `custom-pi-imager.sh` script is a comprehensive Bash-based automation tool designed for customizing Raspberry Pi OS (Debian-based) images on Arch Linux hosts. It creates bootable disk images for Raspberry Pi 4 with pre-configured settings, packages, and custom software, enabling streamlined distribution of ready-to-use Pi images.

## Purpose

This tool addresses the need for reproducible, customized Raspberry Pi OS deployments by:
- Automating base image extraction and modification
- Enabling ARM64 image customization on x86_64 hosts via QEMU emulation
- Supporting package pre-installation
- Facilitating custom software deployment (e.g., micropanel applications)
- Providing extensibility through custom configuration scripts

## Key Features

### 1. Base Image Management
- Accepts compressed (`.img.xz`) or uncompressed (`.img`) Raspberry Pi OS images
- Automatic extraction and validation
- Optional image extension for additional storage space
- Disk space checking with user warnings

### 2. User Authentication
- Configurable password for the `pi` user
- Preserves existing passwords when not specified
- Automatic SSH configuration with password authentication
- Security hardening (root login disabled)

### 3. Package Installation
- Batch package installation from text files
- Comment support in package lists (`#` prefix)
- Automated apt-get operations in chroot environment

### 4. Micropanel Integration
- Support for local or remote (SCP) micropanel sources
- Automatic directory detection and installation
- Proper ownership configuration (uid:gid 1000:1000)

### 5. Custom Configuration
- Execute arbitrary scripts in chroot environment
- Environment variable passing (mount point, password, etc.)
- Post-installation customization hook

### 6. ARM64 Emulation
- QEMU-based ARM64 emulation on x86_64 hosts
- Automatic binfmt_misc validation
- Chroot testing for reliability

## Architecture

### Execution Flow

```
1. Argument Parsing → Validation
2. Environment Check → Prerequisites
3. Workspace Setup → Cleanup old runs
4. Image Extraction → Decompression
5. SDM Integration → Resize/customize
6. Image Mounting → Loop device setup
7. QEMU Setup → ARM64 emulation
8. Password Config → User management
9. Package Install → APT operations
10. Micropanel Copy → Software deployment
11. Custom Script → Post-configuration
12. Verification → Image validation
13. Cleanup → Unmount/detach
14. Summary → Usage instructions
```

### Directory Structure

```
WORK_DIR/
├── {IMAGE_NAME}           # Modified .img file
├── mnt/                   # Mount point for image
│   ├── boot/firmware/     # Boot partition (p1)
│   ├── etc/, home/, ...   # Root filesystem (p2)
│   └── usr/bin/qemu-*     # QEMU binary (temporary)
├── micropanel-temp/       # Temporary download location
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
- `rsync` - File synchronization
- `scp/sshpass` - Remote file transfer (optional)
- `openssl` - Password hashing

### System Requirements
- Root/sudo privileges
- ARM64 binfmt_misc support
- Sufficient disk space (5GB+ recommended)

## Usage

### Basic Syntax
```bash
sudo ./custom-pi-imager.sh --baseimage=PATH --output=DIR [OPTIONS]
```

### Mandatory Arguments

| Argument | Description |
|----------|-------------|
| `--baseimage=PATH` | Path to base Raspberry Pi OS image (.img.xz or .img) |
| `--output=DIR` | Output directory for image customization |

### Optional Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `--password=PASS` | [keep existing] | Password for 'pi' user |
| `--extend-size-mb=SIZE` | 0 | Image extension size in MB |
| `--package-list=FILE` | [skip] | Path to package list file |
| `--micropanel-source=SRC` | [skip] | Local path or user@host:/path |
| `--scp-password=PASS` | [none] | SCP authentication password |
| `--setup-hook=FILE` | [skip] | Setup hook script (compile/build apps in chroot) |
| `--configure-script=FILE` | [skip] | Custom post-install script |

### Usage Patterns

#### Pattern 1: Minimal Customization
```bash
sudo ./custom-pi-imager.sh \
  --baseimage=./2024-07-04-raspios-bookworm-arm64.img.xz \
  --output=/tmp/pi-custom
```
- Keeps default 'raspberry' password
- No image extension
- No packages or micropanel

#### Pattern 2: Full Customization
```bash
sudo ./custom-pi-imager.sh \
  --baseimage=./raspios.img.xz \
  --output=/tmp/pi-custom \
  --password=secure123 \
  --extend-size-mb=2000 \
  --package-list=./packages.txt \
  --micropanel-source=admin@server:/opt/micropanel \
  --scp-password=remotepass \
  --configure-script=./post-install.sh
```
- Custom password
- 2GB additional space
- Package installation
- Remote micropanel download
- Post-configuration script

#### Pattern 3: Incremental Build (Recommended Workflow)
```bash
# Base build
sudo ./custom-pi-imager.sh \
  --baseimage=./base.img.xz \
  --output=/tmp/pi-v1 \
  --password=mypass \
  --package-list=./core-packages.txt

# Use output as new base (compress first)
xz -k /tmp/pi-v1/*.img

# Incremental build
sudo ./custom-pi-imager.sh \
  --baseimage=/tmp/pi-v1/*.img.xz \
  --output=/tmp/pi-v2 \
  --micropanel-source=./micropanel-dir \
  --configure-script=./final-config.sh
```

## Real-World Workflow Example

This section demonstrates the actual production workflow used to create distributable Raspberry Pi 4 images with embedded systems tooling.

### Workflow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        STAGE 1: BASE IMAGE                      │
├─────────────────────────────────────────────────────────────────┤
│ Input:  2025-10-01-raspios-bookworm-arm64-lite.img.xz         │
│ Args:   --password=brb0x --extend-size-mb=1000                 │
│         --package-list=package-list.txt                         │
│                                                                 │
│ Process:                                                        │
│   1. Extract RaspiOS Lite → 3.2GB                              │
│   2. Extend by 1GB → 4.2GB                                      │
│   3. Set password & enable SSH                                  │
│   4. Install 13 packages (i2c-tools, avahi, iperf3, etc.)      │
│                                                                 │
│ Output: 2025-10-01-raspios-bookworm-arm64-lite.img (4.2GB)    │
│         ↓ compress (xz -k -9)                                   │
│         2025-10-01-raspios-bookworm-arm64-lite-base.img.xz     │
│                                                                 │
│ ⏱️  Time: ~15 minutes                                           │
│ 💾 Store: Reusable base for multiple applications              │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    STAGE 2: APPLICATION LAYER                   │
├─────────────────────────────────────────────────────────────────┤
│ Input:  2025-10-01-raspios-bookworm-arm64-lite-base.img.xz    │
│ Args:   --micropanel-source=./micropanel                        │
│         --configure-script=post-install.sh                      │
│                                                                 │
│ Process:                                                        │
│   1. Use base image (password brb0x preserved)                  │
│   2. Copy micropanel → /home/pi/micropanel                      │
│   3. Run post-install.sh:                                       │
│      • Tune network buffers (25MB)                              │
│      • Enable micropanel.service                                │
│      • Disable UART console                                     │
│      • Auto-load i2c-dev module                                 │
│                                                                 │
│ Output: 2025-10-01-raspios-bookworm-arm64-lite.img (4.3GB)    │
│                                                                 │
│ ⏱️  Time: ~5 minutes (no package reinstall!)                    │
│ 🚀 Deploy: Write to SD card → Boot Pi4                         │
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
├── custom-pi-imager.sh           # Main script
├── package-list.txt               # System packages for base image
├── post-install.sh                # Hardware configuration script
├── micropanel/                    # Custom application directory
│   ├── micropanel.service         # Systemd service file
│   ├── configs/
│   │   └── config.txt            # Hardware config overlay
│   └── [application files]
└── docs/
    └── CLAUDE.md                  # This file
```

### Stage 1: Base Image Creation

**Objective**: Create a reusable base image with all system dependencies

```bash
# Base with custom password and core packages
sudo ./custom-pi-imager.sh \
    --baseimage=./2025-10-01-raspios-bookworm-arm64-lite.img.xz \
    --output=/tmp/pi-base \
    --password=brb0x \
    --extend-size-mb=1000 \
    --package-list=./package-list.txt
```

**What happens**:
1. Extracts Raspberry Pi OS Lite (minimal, no desktop)
2. Extends image by 1GB for packages and future tools
3. Sets user `pi` password to `brb0x`
4. Installs hardware interface libraries and development tools (see [package-list.txt](../package-list.txt))

**Installed Packages** (`package-list.txt`):
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

**Objective**: Add custom application and hardware-specific configuration to the base

#### Option A: Pre-built Binaries (Original Method)
```bash
# Incremental (keeps brb0x password from base)
sudo ./custom-pi-imager.sh \
    --baseimage=./2025-10-01-raspios-bookworm-arm64-lite-base.img.xz \
    --output=/tmp/pi-custom \
    --micropanel-source=./micropanel \
    --configure-script=./post-install.sh
```

**What happens**:
1. Uses previously created base image (no re-installation of packages)
2. Preserves `brb0x` password from base (no `--password` flag)
3. Copies pre-built `micropanel` application to `/home/pi/micropanel`
4. Runs [post-install.sh](../post-install.sh:1-30) for hardware configuration

#### Option B: Compile from Source (NEW - Using Setup Hook)
```bash
# Compile micropanel from GitHub source
sudo ./custom-pi-imager.sh \
    --baseimage=./2025-10-01-raspios-bookworm-arm64-lite-base.img.xz \
    --output=/tmp/pi-custom \
    --setup-hook=./micropanel-setup-hook.sh \
    --configure-script=./post-install.sh
```

**What happens**:
1. Uses previously created base image (packages already installed)
2. Preserves `brb0x` password from base
3. Runs [micropanel-setup-hook.sh](../micropanel-setup-hook.sh) in chroot:
   - Installs build dependencies (cmake, g++, make, git)
   - Clones https://github.com/hackboxguy/micropanel.git
   - Compiles for ARM64 via QEMU
   - Installs to `/home/pi/micropanel`
   - **Removes build dependencies** (keeps image clean)
4. Runs [post-install.sh](../post-install.sh:1-30) for hardware configuration

**Post-Install Configuration** (`post-install.sh`):

```bash
#!/bin/bash
set -e

# 1. Network buffer tuning for high-throughput applications
update_sysctl "net.core.rmem_max" "26214400"      # 25MB receive buffer
update_sysctl "net.core.wmem_max" "26214400"      # 25MB send buffer
update_sysctl "net.core.rmem_default" "1310720"   # 1.25MB default receive
update_sysctl "net.core.wmem_default" "1310720"   # 1.25MB default send

# 2. Enable micropanel systemd service (auto-start on boot)
if [ "$MICROPANEL_INSTALLED" = "true" ]; then
    systemctl enable /home/pi/micropanel/micropanel.service
    cp /home/pi/micropanel/configs/config.txt /boot/firmware/
fi

# 3. Disable console on UART (free up UART for hardware communication)
sed -i 's/^console=serial0,115200 //' /boot/firmware/cmdline.txt

# 4. Load I2C kernel module on boot
echo 'i2c-dev' > /etc/modules-load.d/i2c.conf
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

## Setup Hook vs Configure Script

The tool supports two types of customization scripts with different purposes:

### Setup Hook (`--setup-hook`)
**Purpose**: Build and install custom applications from source
**Execution**: Runs in chroot environment (ARM64 via QEMU)
**When to use**: Compile code, install applications, build from git

**Environment Variables**:
- `MOUNT_POINT`: Root filesystem mount point
- `PI_PASSWORD`: User password (empty if unchanged)
- `IMAGE_WORK_DIR`: Working directory path

**Example: [micropanel-setup-hook.sh](../micropanel-setup-hook.sh)**
```bash
#!/bin/bash
set -e

# Install build dependencies
apt-get install -y cmake g++ make git

# Clone and build
git clone https://github.com/hackboxguy/micropanel.git /tmp/mp
cd /tmp/mp/build
cmake -DCMAKE_INSTALL_PREFIX=/home/pi/micropanel ..
make -j$(nproc) && make install

# Cleanup build dependencies
apt-get purge -y cmake g++ make git
apt-get autoremove -y
```

**Key Features**:
- Direct apt-get access (install/purge packages)
- Native ARM64 compilation via QEMU
- Can clone from git repositories
- Automatic cleanup to avoid image bloat

### Configure Script (`--configure-script`)
**Purpose**: System-wide configuration (networking, hardware, services)
**Execution**: Runs in chroot after setup hook completes
**When to use**: Enable services, configure hardware, tune system settings

**Environment Variables**:
- `MOUNT_POINT`: Root filesystem mount point
- `PI_PASSWORD`: User password
- `MICROPANEL_INSTALLED`: "true" or "false"
- `IMAGE_WORK_DIR`: Working directory path

**Example: [post-install.sh](../post-install.sh)**
```bash
#!/bin/bash
set -e

# Tune network buffers
echo "net.core.rmem_max = 26214400" >> /etc/sysctl.conf

# Enable service
if [ "$MICROPANEL_INSTALLED" = "true" ]; then
    systemctl enable /home/pi/micropanel/micropanel.service
fi

# Configure hardware
echo 'i2c-dev' > /etc/modules-load.d/i2c.conf
```

### Execution Order
```
1. install_packages (base packages from package-list.txt)
2. copy_micropanel (if --micropanel-source provided)
3. run_setup_hook (if --setup-hook provided) ← Build/compile apps
4. configure_system (if --configure-script provided) ← System config
```

### When to Use Which?

| Task | Use |
|------|-----|
| Compile C++ application | `--setup-hook` |
| Install Python package with pip | `--setup-hook` |
| Clone git repository and build | `--setup-hook` |
| Enable systemd service | `--configure-script` |
| Configure network (static IP, WiFi) | `--configure-script` |
| Tune sysctl parameters | `--configure-script` |
| Enable hardware (I2C, SPI, UART) | `--configure-script` |
| Install system-wide configuration files | `--configure-script` |

### Both Can Be Used Together
```bash
sudo ./custom-pi-imager.sh \
    --baseimage=base.img.xz \
    --output=/tmp/custom \
    --setup-hook=./build-app.sh \      # Build application
    --configure-script=./configure.sh  # Configure system
```

## File Formats

### Package List File
```bash
# Core utilities
vim
git
htop

# Development tools
python3-pip
nodejs
npm

# Empty lines and comments ignored
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

The `custom-pi-imager.sh` script automates the creation of production-ready Raspberry Pi 4 SD card images with:

1. **System Layer**: Pre-installed packages, configured users, SSH access
2. **Application Layer**: Custom software with systemd services
3. **Hardware Layer**: I2C, UART, SPI, network tuning

### Why Two-Stage Build?

| Need | Solution |
|------|----------|
| **Fast iteration** | Base image cached, only rebuild application (5 min vs 15 min) |
| **Multiple variants** | One base → sensor image, display image, gateway image |
| **Dependency stability** | Package versions locked in base, app versions independent |
| **Reduced risk** | Test base once, iterate on application safely |

### Key Technologies

- **SDM**: Raspberry Pi image manager (resize, customize, plugins)
- **QEMU**: ARM64 emulation on x86_64 (run ARM binaries natively)
- **Chroot**: Isolated environment for package installation
- **Loop devices**: Mount images as block devices for modification

### Production Use Case

This tool is designed for embedded systems developers who need to:
- Distribute pre-configured Pi images to customers
- Deploy fleet of Pis with identical configuration
- Test hardware applications without manual setup
- Version control entire system state (packages + config + app)

### Typical Hardware Integrations

Based on the package list and configuration:
- **I2C sensors**: Temperature, pressure, accelerometers (i2c-tools, libi2c-dev)
- **USB devices**: FTDI, HID devices (libftdi1, libhidapi)
- **Network apps**: Bandwidth testing, data streaming (iperf3, tuned buffers)
- **Serial communication**: UART freed from console for hardware protocols

### Project Files

| File | Purpose | When to Edit |
|------|---------|--------------|
| [custom-pi-imager.sh](../custom-pi-imager.sh) | Main build script | Adding features, fixing bugs |
| [package-list.txt](../package-list.txt) | System packages | New dependencies, libraries |
| [post-install.sh](../post-install.sh) | Hardware config | UART, I2C, services, networking |
| `micropanel/` | Your application | Application code changes |

### Common Workflows

```bash
# Initial setup (once)
sudo ./custom-pi-imager.sh --baseimage=raspios.img.xz --output=/tmp/base \
  --password=mypass --extend-size-mb=1000 --package-list=package-list.txt

# Develop application (iterative)
# 1. Edit micropanel code
# 2. Rebuild from base:
sudo ./custom-pi-imager.sh --baseimage=base.img.xz --output=/tmp/test \
  --micropanel-source=./micropanel --configure-script=post-install.sh
# 3. Test on Pi
# 4. Repeat

# Production release
sudo ./custom-pi-imager.sh --baseimage=base.img.xz --output=/tmp/release-v1.2 \
  --micropanel-source=./micropanel --configure-script=post-install.sh
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

## License & Support

This script is designed for Arch Linux hosts and optimized for Raspberry Pi OS Debian distributions. For issues or contributions, refer to the project repository.

---

**Document Version**: 2.0
**Last Updated**: 2025-10-25
**Compatible With**: Raspberry Pi OS (Bookworm/Bullseye), Raspberry Pi 4
**Example Files**: Real production usage with [package-list.txt](../package-list.txt) and [post-install.sh](../post-install.sh)
