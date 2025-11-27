# Raspberry Pi 4 Kernel Cross-Compilation Scripts

These scripts automate the process of cross-compiling a Raspberry Pi 4 Linux kernel and custom out-of-tree drivers on an Arch Linux x86_64 host machine.

## Quick Start

### Option 1: One-Command Build (Recommended)

```bash
# First time: Install dependencies
sudo ./01-setup-arch-deps.sh

# Interactive build (prompts for sudo at install step)
./00-build-all.sh \
    --branch rpi-6.12.y \
    --config /path/to/config-6.12.47+rpt-rpi-v8 \
    --drivers /path/to/br-wrapper/package \
    --image /path/to/raspios.img \
    --backup

# Unattended build (use sudo to avoid password timeout)
sudo ./00-build-all.sh \
    --branch rpi-6.12.y \
    --config /path/to/config-6.12.47+rpt-rpi-v8 \
    --drivers /path/to/br-wrapper/package \
    --image /path/to/raspios.img \
    --backup
```

### Option 2: Step-by-Step Build

```bash
# 1. Install dependencies (requires sudo)
sudo ./01-setup-arch-deps.sh

# 2. Download and configure kernel
./02-download-kernel.sh

# 3. Build kernel
./03-build-kernel.sh

# 4. Build custom drivers
./04-build-drivers.sh

# 5. Install to image (requires sudo)
sudo ./05-install-to-image.sh --backup
```

## Scripts

### 00-build-all.sh

Top-level wrapper script that orchestrates the complete build process. Calls all other scripts in sequence and only uses sudo for the final installation step.

```bash
./00-build-all.sh [OPTIONS]
```

**Required:**

| Option | Description |
|--------|-------------|
| `--image <path>` | Path to Raspberry Pi OS image file |

**Kernel Options:**

| Option | Description |
|--------|-------------|
| `--branch <name>` | Kernel branch (default: rpi-6.12.y) |
| `--config <config>` | Kernel config: `defconfig` or path to config file |
| `--fresh` | Remove existing kernel source and re-clone |

**Driver Options:**

| Option | Description |
|--------|-------------|
| `--drivers <path>` | Path to driver packages directory |

**Build Options:**

| Option | Description |
|--------|-------------|
| `--build-dir <path>` | Build directory (default: `$HOME/rpi-kernel-build`) |
| `--output <path>` | Output directory for modules and overlays |
| `--clean` | Clean build directories before building |

**Skip Options:**

| Option | Description |
|--------|-------------|
| `--skip-kernel` | Skip kernel download and build (steps 02-03) |
| `--skip-drivers` | Skip driver build (step 04) |

**Install Options:**

| Option | Description |
|--------|-------------|
| `--backup` | Backup original kernel before installing |

**Other:**

| Option | Description |
|--------|-------------|
| `--dry-run` | Show what would be done without executing |
| `--help` | Show help message |

**Examples:**

```bash
# Full build with all custom paths
./00-build-all.sh \
    --branch rpi-6.12.y \
    --config /path/to/config-6.12.47+rpt-rpi-v8 \
    --drivers /path/to/br-wrapper/package \
    --image /path/to/raspios.img \
    --backup

# Rebuild only drivers and install (kernel already built)
./00-build-all.sh \
    --skip-kernel \
    --drivers /path/to/br-wrapper/package \
    --image /path/to/raspios.img

# Preview what would be done
./00-build-all.sh \
    --image /path/to/raspios.img \
    --dry-run

# Use default bcm2711_defconfig
./00-build-all.sh \
    --config defconfig \
    --image /path/to/raspios.img
```

**Usage Modes:**

1. **Normal user** (recommended for interactive use):
   ```bash
   ./00-build-all.sh --image /path/to/image.img
   ```
   Will prompt for sudo password at the final install step.

2. **With sudo** (recommended for unattended builds):
   ```bash
   sudo ./00-build-all.sh --image /path/to/image.img
   ```
   Automatically drops privileges for build steps (runs as `$SUDO_USER`), then runs the install step directly as root. This avoids sudo timeout issues during long builds.

**Note:** Running as root directly (not via sudo) is not supported.

---

### 01-setup-arch-deps.sh

Installs all required packages on Arch Linux for cross-compiling the Raspberry Pi 4 kernel.

```bash
sudo ./01-setup-arch-deps.sh
```

**What it installs:**
- `aarch64-linux-gnu-gcc` - Cross-compiler toolchain
- `aarch64-linux-gnu-binutils` - Cross-compilation binutils
- `bc`, `bison`, `flex` - Kernel build tools
- `libelf`, `openssl`, `pahole` - Required libraries
- `dtc` - Device tree compiler

### 02-download-kernel.sh

Downloads and configures the Raspberry Pi Linux kernel source.

```bash
./02-download-kernel.sh [OPTIONS]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--fresh` | Remove existing source and re-clone |
| `--branch <name>` | Use specific kernel branch (default: `rpi-6.12.y`) |
| `--config <config>` | Kernel configuration (see below) |
| `--defconfig` | *(deprecated)* Alias for `--config defconfig` |

**Config option values:**

| Value | Description |
|-------|-------------|
| `defconfig` | Use default `bcm2711_defconfig` |
| `<path>` | Use custom config file at specified path |

**Examples:**

```bash
# Use default defconfig
./02-download-kernel.sh --config defconfig

# Use custom config file
./02-download-kernel.sh --config /path/to/config-6.12.47+rpt-rpi-v8

# Fresh clone with different branch
./02-download-kernel.sh --fresh --branch rpi-6.1.y --config defconfig

# Use default from config.env (no --config specified)
./02-download-kernel.sh
```

### 03-build-kernel.sh

Cross-compiles the kernel Image, device trees, and in-tree modules.

```bash
./03-build-kernel.sh [OPTIONS]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--clean` | Run `make clean` before building |
| `--modules-only` | Only rebuild modules (skip Image and dtbs) |

**Examples:**

```bash
# Full build
./03-build-kernel.sh

# Clean build
./03-build-kernel.sh --clean

# Only rebuild modules (faster)
./03-build-kernel.sh --modules-only
```

### 04-build-drivers.sh

Cross-compiles custom out-of-tree drivers and their device tree overlays.

```bash
./04-build-drivers.sh [OPTIONS]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--clean` | Clean driver build directories before building |
| `--kernel <path>` | Path to kernel source directory (built by 03-build-kernel.sh) |
| `--drivers <path>` | Path to driver packages directory (containing `hh983-serializer/` and `himax-touch/`) |
| `--output <path>` | Output directory for built modules and overlays |

**Examples:**

```bash
# Use defaults from config.env
./04-build-drivers.sh

# Clean build with custom paths
./04-build-drivers.sh --clean \
    --kernel /path/to/linux \
    --drivers /path/to/br-wrapper/package \
    --output /tmp/driver-build

# Only override kernel path
./04-build-drivers.sh --kernel ~/custom-kernel/linux

# Only override drivers path
./04-build-drivers.sh --drivers ~/my-project/br-wrapper/package
```

**Expected directory structure for `--drivers`:**

```
<drivers-path>/
├── hh983-serializer/
│   └── src/
│       ├── hh983-serializer.c
│       ├── Makefile
│       └── hh983-serializer-overlay.dts
└── himax-touch/
    ├── src/
    │   ├── himax_*.c
    │   └── Makefile
    └── dts/
        └── himax-touch-overlay.dts
```

**Drivers built:**
- `hh983-serializer` - TI FPDLink serializer driver
- `himax-touch` - Himax TDDI touchscreen driver

**Output:**
- `$BUILD_OUTPUT/modules/hh983-serializer.ko`
- `$BUILD_OUTPUT/modules/himax_mmi.ko`
- `$BUILD_OUTPUT/overlays/hh983-serializer.dtbo`
- `$BUILD_OUTPUT/overlays/himax-touch.dtbo`

### 05-install-to-image.sh

Mounts a Raspberry Pi OS image and installs the compiled kernel, modules, and drivers.

```bash
sudo ./05-install-to-image.sh [OPTIONS]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--image <path>` | Path to Raspberry Pi image (default from `config.env`) |
| `--backup` | Create backup of original kernel before overwriting |
| `--modules-only` | Only install modules, skip kernel Image and DTBs |
| `--skip-intree` | Skip in-tree modules, only install custom drivers |

**Examples:**

```bash
# Full install with backup
sudo ./05-install-to-image.sh --backup

# Different image
sudo ./05-install-to-image.sh --image /path/to/raspios.img --backup

# Only install custom drivers (faster)
sudo ./05-install-to-image.sh --skip-intree
```

### find-kernel-version.sh

Helper script to find kernel version information and available tags.

```bash
./find-kernel-version.sh
```

## Configuration

All scripts source `config.env` for shared configuration. Key variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `BUILD_BASE` | `$HOME/rpi-kernel-build` | Base directory for all operations |
| `KERNEL_BRANCH` | `rpi-6.12.y` | Kernel branch to clone |
| `CUSTOM_KERNEL_CONFIG` | `$BUILD_BASE/config-*` | Custom kernel config file |
| `RPI_IMAGE` | `$BUILD_BASE/*.img` | Raspberry Pi OS image path |
| `DRIVER_PKG_DIR` | `$BUILD_BASE/br-wrapper/package` | Custom driver source directory |
| `JOBS` | `$(nproc)` | Parallel build jobs |

**Override variables:**

```bash
# Override image path
RPI_IMAGE=/path/to/custom.img sudo ./05-install-to-image.sh

# Override build base
BUILD_BASE=/tmp/kernel-build ./02-download-kernel.sh
```

## Directory Structure

After running all scripts:

```
$BUILD_BASE/
├── linux/                          # Kernel source (step 2)
│   ├── .config                     # Kernel configuration
│   └── arch/arm64/boot/Image       # Compiled kernel
├── output/                         # Build artifacts (steps 3-4)
│   ├── modules/                    # Custom driver .ko files
│   │   ├── hh983-serializer.ko
│   │   └── himax_mmi.ko
│   └── overlays/                   # Device tree overlays
│       ├── hh983-serializer.dtbo
│       └── himax-touch.dtbo
├── kernel-version.txt              # Kernel version string
└── *.img                           # Raspberry Pi OS image
```

## Troubleshooting

### Version mismatch errors

If you see "version magic" errors when loading modules:

```bash
# Check module version
modinfo hh983-serializer.ko | grep vermagic

# Check running kernel
uname -r
```

The script automatically disables `CONFIG_LOCALVERSION_AUTO` to prevent `+` suffix mismatches.

### Cross-compiler not found

```bash
# Verify installation
which aarch64-linux-gnu-gcc
aarch64-linux-gnu-gcc --version
```

### Kernel config issues

```bash
# Reset to default
cd $BUILD_BASE/linux
make mrproper
make bcm2711_defconfig
```

## Requirements

- **Host**: Arch Linux x86_64
- **Target**: Raspberry Pi 4 (64-bit, ARM64)
- **Disk space**: ~5GB for kernel source + build artifacts
- **RAM**: 4GB minimum (8GB+ recommended for parallel builds)
