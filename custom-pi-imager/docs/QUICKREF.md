# Custom Pi Imager - Quick Reference Card

## Essential Commands

### Stage 1: Base Image (Run Once)
```bash
sudo ./custom-pi-imager.sh \
    --baseimage=./2025-10-01-raspios-bookworm-arm64-lite.img.xz \
    --output=/tmp/pi-base \
    --password=brb0x \
    --extend-size-mb=1000 \
    --package-list=./package-list.txt

# Preserve base
xz -k -9 /tmp/pi-base/*.img
mv /tmp/pi-base/*.img.xz ./base.img.xz
```

### Stage 2A: Application Layer - Pre-built (Iterate)
```bash
sudo ./custom-pi-imager.sh \
    --baseimage=./base.img.xz \
    --output=/tmp/pi-custom \
    --micropanel-source=./micropanel \
    --configure-script=./post-install.sh
```

### Stage 2B: Application Layer - Compile from Source (NEW)
```bash
sudo ./custom-pi-imager.sh \
    --baseimage=./base.img.xz \
    --output=/tmp/pi-custom \
    --setup-hook=./micropanel-setup-hook.sh \
    --configure-script=./post-install.sh
```

### Deploy to SD Card
```bash
# Identify device
lsblk

# Write image
sudo dd if=/tmp/pi-custom/*.img of=/dev/sdX bs=8M status=progress conv=fsync

# Eject
sudo eject /dev/sdX
```

## Command Arguments

| Argument | Required? | Example | Purpose |
|----------|-----------|---------|---------|
| `--baseimage` | **YES** | `raspios.img.xz` | Source image |
| `--output` | **YES** | `/tmp/build` | Working directory |
| `--password` | No | `mypass` | User password (keeps existing if omitted) |
| `--extend-size-mb` | No | `1000` | Add 1GB space (default: 0) |
| `--package-list` | No | `packages.txt` | Packages to install |
| `--micropanel-source` | No | `./app` or `user@host:/path` | Application files (pre-built) |
| `--scp-password` | No | `pass` | SCP authentication |
| `--setup-hook` | No | `build.sh` | Setup hook (compile from source) |
| `--configure-script` | No | `setup.sh` | Post-install script |

## File Formats

### package-list.txt
```txt
# Comments with #
avahi-daemon
i2c-tools
iperf3
libcurl4-openssl-dev
```

### setup-hook.sh (NEW - Compile from Source)
```bash
#!/bin/bash
set -e

# Runs in chroot (ARM64 via QEMU)
# Available variables: $MOUNT_POINT, $PI_PASSWORD, $IMAGE_WORK_DIR

# Install build dependencies
apt-get install -y cmake g++ make git

# Clone and build
git clone https://github.com/user/project.git /tmp/build
cd /tmp/build
cmake -DCMAKE_INSTALL_PREFIX=/home/pi/app ..
make -j$(nproc) && make install

# Cleanup to avoid bloat
apt-get purge -y cmake g++ make git
apt-get autoremove -y
rm -rf /tmp/build
```

### post-install.sh (System Configuration)
```bash
#!/bin/bash
set -e

# Runs after setup-hook
# Available variables:
# - $MICROPANEL_INSTALLED (true/false)
# - $PI_PASSWORD (empty if unchanged)
# - $MOUNT_POINT

# Enable service
if [ "$MICROPANEL_INSTALLED" = "true" ]; then
    systemctl enable /home/pi/micropanel/app.service
fi

# Load kernel module
echo 'i2c-dev' > /etc/modules-load.d/i2c.conf
```

## Prerequisites (Arch Linux)

```bash
# Install QEMU ARM64 emulation
sudo pacman -S qemu-user-static qemu-user-static-binfmt

# Install SDM
git clone https://github.com/gitbls/sdm.git
cd sdm && sudo make install

# Verify
systemctl status systemd-binfmt.service
qemu-aarch64-static --version
sdm --version
```

## Post-Boot Verification

```bash
# SSH access
ssh pi@raspberrypi.local
# Password: brb0x (or whatever you set)

# Check service
systemctl status micropanel

# Check I2C
lsmod | grep i2c_dev
i2cdetect -y 1

# Check network buffers
sysctl net.core.rmem_max

# Check packages
dpkg -l | grep -E 'i2c-tools|avahi|iperf3'
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `ARM64 binfmt failed` | `sudo systemctl restart systemd-binfmt.service` |
| `sdm not found` | Install SDM from github.com/gitbls/sdm |
| `Chroot test failed` | Verify QEMU: `file /usr/bin/qemu-aarch64-static` |
| `Low space warning` | Free disk space or change `--output` directory |
| `Loop device busy` | `sudo losetup -D` to detach all |
| `Permission denied` | Run with `sudo` |

## Common Modifications

### Add Package
```bash
echo "python3-pip" >> package-list.txt
# Rebuild base image
```

### Enable WiFi
```bash
# In post-install.sh
cat > /etc/wpa_supplicant/wpa_supplicant.conf <<EOF
country=US
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
network={
    ssid="YourSSID"
    psk="YourPassword"
}
EOF
```

### Static IP
```bash
# In post-install.sh
cat >> /etc/dhcpcd.conf <<EOF
interface eth0
static ip_address=192.168.1.100/24
static routers=192.168.1.1
static domain_name_servers=8.8.8.8
EOF
```

### Enable Hardware
```bash
# In post-install.sh
cat >> /boot/firmware/config.txt <<EOF
dtparam=spi=on
dtparam=i2c_arm=on
start_x=1
gpu_mem=128
EOF
```

## Performance Tips

- **Use SSD** for `--output` directory
- **Pre-decompress** images for multiple builds: `unxz image.img.xz`
- **Incremental builds** from base (~5 min vs ~15 min)
- **Parallel testing** with QEMU before SD write

## Project Structure

```
custom-pi-imager/
├── custom-pi-imager.sh     # Main script
├── package-list.txt         # System packages
├── post-install.sh          # Hardware config
├── micropanel/              # Your application
│   ├── micropanel.service
│   └── [app files]
└── docs/
    ├── CLAUDE.md            # Full documentation
    └── QUICKREF.md          # This file
```

## Environment Variables (post-install.sh)

| Variable | Example | Description |
|----------|---------|-------------|
| `MOUNT_POINT` | `/tmp/pi/mnt` | Root filesystem mount |
| `PI_PASSWORD` | `brb0x` or empty | User password |
| `MICROPANEL_INSTALLED` | `true` or `false` | Whether micropanel copied |
| `IMAGE_WORK_DIR` | `/tmp/pi` | Working directory |

## Time Estimates

| Operation | Duration | Notes |
|-----------|----------|-------|
| Base image build | ~15 min | Includes package install |
| Application build | ~5 min | From existing base |
| SD card write (8GB) | ~10 min | Depends on card speed |
| First boot expand | ~30 sec | Auto-expands root partition |

## Security Checklist

- [ ] Change default password from `raspberry`
- [ ] Disable root SSH login (done automatically)
- [ ] Use SSH keys instead of passwords (production)
- [ ] Review package list for unnecessary packages
- [ ] Update packages regularly (`apt update && apt upgrade`)
- [ ] Don't hardcode secrets in scripts

## Distribution Workflow

```bash
# 1. Build production image
sudo ./custom-pi-imager.sh --baseimage=base.img.xz --output=/tmp/release \
  --micropanel-source=./micropanel --configure-script=post-install.sh

# 2. Compress
xz -k -9 /tmp/release/*.img

# 3. Generate checksum
sha256sum /tmp/release/*.img.xz > checksum.txt

# 4. Tag release
git tag -a v1.0 -m "Production release 1.0"

# 5. Distribute
# - Upload to file server
# - Provide checksum for verification
# - Document in release notes
```

## Resources

- [Full Documentation](CLAUDE.md) - Complete technical reference
- [RaspiOS Images](https://www.raspberrypi.com/software/operating-systems/)
- [SDM GitHub](https://github.com/gitbls/sdm)
- [Example Files](../) - package-list.txt, post-install.sh

---

**Version**: 2.0 | **Updated**: 2025-10-25 | **Platform**: Arch Linux → Raspberry Pi 4
