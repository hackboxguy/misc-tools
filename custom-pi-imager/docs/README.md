# Documentation Index

This directory contains comprehensive documentation for the Custom Pi Imager tool.

## Documents

### [CLAUDE.md](CLAUDE.md) - Complete Technical Documentation
**38KB | 1,232 lines | Comprehensive reference**

The complete technical guide covering:
- Architecture and execution flow
- Real-world two-stage build workflow
- Detailed explanations of all features
- Your actual production files analyzed ([package-list.txt](../package-list.txt), [post-install.sh](../post-install.sh))
- QEMU, SDM, and loop device internals
- Troubleshooting guide with solutions
- CI/CD integration examples
- Best practices and security considerations

**Best for**: Understanding how everything works, deep dives, troubleshooting complex issues

### [QUICKREF.md](QUICKREF.md) - Quick Reference Card
**6KB | Command cheat sheet**

Practical quick reference with:
- Essential commands for both stages
- Argument reference table
- File format templates
- Post-boot verification commands
- Common modifications (WiFi, static IP, hardware)
- Troubleshooting table
- Distribution workflow

**Best for**: Day-to-day usage, command lookup, quick copy-paste

## Quick Start

**New users**: Start with [QUICKREF.md](QUICKREF.md) to get building immediately, then refer to [CLAUDE.md](CLAUDE.md) for deeper understanding.

**Experienced users**: Keep [QUICKREF.md](QUICKREF.md) open for command reference.

## Your Production Workflow

### Stage 1: Base Image (Once per OS version)
```bash
sudo ./custom-pi-imager.sh \
    --baseimage=./2025-10-01-raspios-bookworm-arm64-lite.img.xz \
    --output=/tmp/pi-base \
    --password=brb0x \
    --extend-size-mb=1000 \
    --package-list=./package-list.txt
```
**Time**: ~15 minutes
**Output**: Base image with 13 packages installed
**Packages**: avahi, i2c-tools, iperf3, libftdi1, libhidapi, nlohmann-json3-dev, etc.

### Stage 2: Application Layer (Iterate)
```bash
sudo ./custom-pi-imager.sh \
    --baseimage=./2025-10-01-raspios-bookworm-arm64-lite-base.img.xz \
    --output=/tmp/pi-custom \
    --micropanel-source=./micropanel \
    --configure-script=./post-install.sh
```
**Time**: ~5 minutes
**Output**: Custom image with micropanel installed
**Config**: Network buffer tuning, UART freed, I2C auto-load, systemd service enabled

## File Overview

| File | Lines | Purpose |
|------|-------|---------|
| [custom-pi-imager.sh](../custom-pi-imager.sh) | 431 | Main automation script |
| [package-list.txt](../package-list.txt) | 14 | System packages for base |
| [post-install.sh](../post-install.sh) | 30 | Hardware configuration |
| [CLAUDE.md](CLAUDE.md) | 1,232 | Complete documentation |
| [QUICKREF.md](QUICKREF.md) | 250 | Quick reference card |

## What This Tool Does

Creates **production-ready Raspberry Pi 4 images** with:

1. **System Layer**
   - Pre-installed hardware interface libraries (I2C, FTDI, HID)
   - Network discovery (Avahi/mDNS)
   - Development tools and utilities
   - Configured SSH access

2. **Application Layer**
   - Custom micropanel application
   - Systemd service auto-start
   - Hardware-specific configurations

3. **Hardware Optimizations**
   - Network buffers tuned (25MB max)
   - UART freed from console
   - I2C module auto-loaded
   - Boot firmware configured

## Key Benefits

✅ **Fast Iteration**: 5-minute builds using cached base image
✅ **Reproducible**: Identical configuration across all deployments
✅ **Flexible**: One base → multiple application variants
✅ **Automated**: No manual Pi configuration needed
✅ **Version Controlled**: All configs in git

## Hardware Integrations Supported

Based on installed packages and configuration:

- **I2C Devices**: Sensors, displays, ADCs (i2c-tools, libi2c-dev)
- **USB-Serial**: FTDI adapters (libftdi1)
- **HID Devices**: USB input devices (libhidapi-libusb0)
- **Network Testing**: Bandwidth analysis (iperf3)
- **Serial Communication**: UART without kernel console interference

## Prerequisites

**Host System**: Arch Linux (recommended) or compatible

```bash
# Install QEMU for ARM64 emulation
sudo pacman -S qemu-user-static qemu-user-static-binfmt

# Install SDM (Raspberry Pi image manager)
git clone https://github.com/gitbls/sdm.git
cd sdm && sudo make install

# Verify
systemctl status systemd-binfmt.service
sdm --version
```

## Documentation Structure

```
docs/
├── README.md          # This file (documentation index)
├── CLAUDE.md          # Complete technical documentation
└── QUICKREF.md        # Quick reference card

Both documents reference your actual production files:
../package-list.txt    # 13 packages for hardware/network
../post-install.sh     # Network tuning, hardware config
```

## Common Use Cases

### Development
1. Edit micropanel code
2. Rebuild from base (5 min)
3. Write to SD card
4. Test on Pi4
5. Iterate

### Multiple Products
- **Base image**: Common packages
- **Sensor variant**: + sensor application
- **Display variant**: + display application
- **Gateway variant**: + gateway application

### CI/CD
- Base image built on schedule (weekly)
- Application images built on commit
- Artifacts stored with checksums
- Automated testing in QEMU

## Next Steps

1. **Prerequisites**: Install QEMU and SDM
2. **Download OS**: Get Raspberry Pi OS Lite
3. **Build Base**: Follow Stage 1 in [QUICKREF.md](QUICKREF.md)
4. **Customize**: Follow Stage 2 with your application
5. **Deploy**: Write to SD card and boot
6. **Verify**: SSH and check services

## Support & Contributing

- **Issues**: Report problems in project repository
- **Improvements**: Edit [post-install.sh](../post-install.sh) for new configs
- **Packages**: Edit [package-list.txt](../package-list.txt) for new dependencies
- **Documentation**: These docs reference your actual working setup

## Version Information

| Component | Version | Status |
|-----------|---------|--------|
| Documentation | 2.0 | Current |
| Script | 1.0 | Stable |
| Base OS | Bookworm (Debian 12) | Latest |
| Target Hardware | Raspberry Pi 4 | Tested |
| Host Platform | Arch Linux | Recommended |

**Last Updated**: 2025-10-25
**Documentation by**: Claude (Anthropic)
**Production Configuration**: Real working examples from your setup

---

**Ready to build?** → [QUICKREF.md](QUICKREF.md)
**Need details?** → [CLAUDE.md](CLAUDE.md)
