#!/bin/bash
set -e

# Configuration
PI_PASSWORD=""
EXTEND_SIZE_MB=""
IMAGE_SOURCE=""
IMAGE_NAME=""
WORK_DIR=""
MOUNT_POINT=""
SOURCE_FILES_HOST=""
SCP_PASSWORD=""
PACKAGE_LIST_FILE=""
CONFIGURE_SCRIPT=""
SKIP_MICROPANEL=false
SKIP_PACKAGES=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

show_usage() {
    cat <<EOF
Raspberry Pi Image Customization Script for Arch Linux

Usage:
  sudo $0 --baseimage=PATH --output=DIR [OPTIONS]

Mandatory Arguments:
  --baseimage=PATH          Path to base Raspberry Pi OS image (.img.xz)
  --output=DIR              Output directory for image customization

Optional Arguments:
  --password=PASS           Password for 'pi' user (default: keep existing/raspberry)
  --extend-size-mb=SIZE     Image extension size in MB (default: 0, no extension)
  --package-list=FILE       Path to package list file (one per line, # for comments)
  --micropanel-source=SRC   Micropanel source (user@host:/path or /local/path)
  --scp-password=PASS       SCP password for remote micropanel source
  --configure-script=FILE   Custom configuration script (runs in chroot)
                            Receives: MOUNT_POINT, PI_PASSWORD, MICROPANEL_INSTALLED
  --help, -h                Show this help

Examples:
  # Minimal (keeps default raspberry password)
  sudo $0 --baseimage=./image.img.xz --output=/tmp/pi

  # Base image with custom password
  sudo $0 --baseimage=./image.img.xz --output=/tmp/pi \\
    --password=mypass --extend-size-mb=1000 --package-list=./packages.txt

  # Incremental build (keeps base image password)
  sudo $0 --baseimage=./base.img.xz --output=/tmp/pi \\
    --micropanel-source=./mp --configure-script=./post-install.sh

EOF
    exit 0
}

parse_arguments() {
    [ $# -eq 0 ] && show_usage

    for arg in "$@"; do
        case $arg in
            --baseimage=*) IMAGE_SOURCE="${arg#*=}" ;;
            --output=*) WORK_DIR="${arg#*=}" ;;
            --password=*) PI_PASSWORD="${arg#*=}" ;;
            --extend-size-mb=*) EXTEND_SIZE_MB="${arg#*=}" ;;
            --micropanel-source=*) SOURCE_FILES_HOST="${arg#*=}" ;;
            --scp-password=*) SCP_PASSWORD="${arg#*=}" ;;
            --package-list=*) PACKAGE_LIST_FILE="${arg#*=}" ;;
            --configure-script=*) CONFIGURE_SCRIPT="${arg#*=}" ;;
            --help|-h) show_usage ;;
            *) error "Unknown argument: $arg\nUse --help for usage" ;;
        esac
    done

    local missing=()
    [ -z "$IMAGE_SOURCE" ] && missing+=("--baseimage")
    [ -z "$WORK_DIR" ] && missing+=("--output")
    [ ${#missing[@]} -gt 0 ] && error "Missing: ${missing[*]}\nUse --help"
    
    # Set defaults if not provided
    [ -z "$EXTEND_SIZE_MB" ] && EXTEND_SIZE_MB=0
    [ -z "$PI_PASSWORD" ] && PI_PASSWORD="" && info "No password specified, keeping existing password"

    # Convert to absolute paths
    if [[ "$IMAGE_SOURCE" != /* ]]; then
        IMAGE_SOURCE="$(cd "$(dirname "$IMAGE_SOURCE")" && pwd)/$(basename "$IMAGE_SOURCE")"
    fi
    
    if [[ "$WORK_DIR" != /* ]]; then
        local tmpdir=$(dirname "$WORK_DIR")
        if cd "$tmpdir" 2>/dev/null; then
            WORK_DIR="$(pwd)/$(basename "$WORK_DIR")"
            cd - >/dev/null
        else
            WORK_DIR="$(pwd)/$WORK_DIR"
        fi
    fi
    
    if [ -n "$SOURCE_FILES_HOST" ] && [[ "$SOURCE_FILES_HOST" != *@*:* ]] && [[ "$SOURCE_FILES_HOST" != /* ]]; then
        SOURCE_FILES_HOST="$(cd "$(dirname "$SOURCE_FILES_HOST")" 2>/dev/null && pwd)/$(basename "$SOURCE_FILES_HOST")" || SOURCE_FILES_HOST="$(pwd)/$SOURCE_FILES_HOST"
    fi
    
    if [ -n "$PACKAGE_LIST_FILE" ] && [[ "$PACKAGE_LIST_FILE" != /* ]]; then
        PACKAGE_LIST_FILE="$(cd "$(dirname "$PACKAGE_LIST_FILE")" 2>/dev/null && pwd)/$(basename "$PACKAGE_LIST_FILE")" || PACKAGE_LIST_FILE="$(pwd)/$PACKAGE_LIST_FILE"
    fi
    
    if [ -n "$CONFIGURE_SCRIPT" ] && [[ "$CONFIGURE_SCRIPT" != /* ]]; then
        CONFIGURE_SCRIPT="$(cd "$(dirname "$CONFIGURE_SCRIPT")" 2>/dev/null && pwd)/$(basename "$CONFIGURE_SCRIPT")" || CONFIGURE_SCRIPT="$(pwd)/$CONFIGURE_SCRIPT"
    fi

    IMAGE_NAME="$(basename "$IMAGE_SOURCE")"
    IMAGE_NAME="${IMAGE_NAME%.xz}"
    MOUNT_POINT="${WORK_DIR}/mnt"
    
    [ -z "$SOURCE_FILES_HOST" ] && SKIP_MICROPANEL=true && warn "Micropanel installation will be skipped"
    [ -z "$PACKAGE_LIST_FILE" ] && SKIP_PACKAGES=true && warn "Package installation will be skipped"
    
    return 0
}

show_configuration() {
    info "Configuration:"
    echo "  Base Image:      ${IMAGE_SOURCE}"
    echo "  Output Dir:      ${WORK_DIR}"
    echo "  Password:        $([ -z "$PI_PASSWORD" ] && echo "[KEEP EXISTING]" || echo "${PI_PASSWORD//?/*}")"
    echo "  Extend Size:     $([ "$EXTEND_SIZE_MB" -eq 0 ] && echo "[NONE]" || echo "${EXTEND_SIZE_MB} MB")"
    echo "  Package List:    $([ "$SKIP_PACKAGES" = true ] && echo "[SKIPPED]" || echo "${PACKAGE_LIST_FILE}")"
    echo "  Micropanel:      $([ "$SKIP_MICROPANEL" = true ] && echo "[SKIPPED]" || echo "${SOURCE_FILES_HOST}")"
    echo "  Config Script:   $([ -z "$CONFIGURE_SCRIPT" ] && echo "[NONE]" || echo "${CONFIGURE_SCRIPT}")"
    echo ""
}

check_arch_linux() {
    [ ! -f /etc/arch-release ] && warn "Optimized for Arch Linux" && \
        read -p "Continue? (y/N) " -n 1 -r && echo && [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    info "Detected Arch Linux"
}

check_prerequisites() {
    log "Checking prerequisites..."
    command -v qemu-aarch64-static >/dev/null 2>&1 || error "Install: sudo pacman -S qemu-user-static qemu-user-static-binfmt"
    [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] && systemctl status systemd-binfmt.service >/dev/null 2>&1 || true && sleep 2
    [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] && error "ARM64 binfmt failed. Try: sudo systemctl restart systemd-binfmt.service"
    grep -q "enabled" /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null && info "ARM64 emulation: enabled ✓"
    command -v sdm >/dev/null 2>&1 || error "sdm not found"
    info "SDM version: $(sdm --version 2>&1 | head -n1 | awk '{print $2}')"
    
    for tool in unxz losetup mount umount chroot rsync; do
        command -v $tool >/dev/null 2>&1 || error "Missing: $tool"
    done
    
    if [ "$SKIP_MICROPANEL" = false ] && [[ "$SOURCE_FILES_HOST" == *@*:* ]]; then
        command -v scp >/dev/null 2>&1 || error "Missing: scp"
    fi
    
    if [ "$SKIP_MICROPANEL" = false ] && [ -n "$SCP_PASSWORD" ]; then
        command -v sshpass >/dev/null 2>&1 || error "Install: sudo pacman -S sshpass"
    fi
    
    log "Prerequisites OK"
}

setup_workdir() {
    log "Setting up: ${WORK_DIR}"
    [ -d "${WORK_DIR}" ] && warn "Cleaning old workdir..." && umount -R "${MOUNT_POINT}" 2>/dev/null || true
    local ld=$(losetup -a | grep "${IMAGE_NAME}" | cut -d: -f1)
    [ -n "$ld" ] && losetup -d "$ld" 2>/dev/null || true
    mkdir -p "${WORK_DIR}" "${MOUNT_POINT}"
    cd "${WORK_DIR}"
}

extract_image() {
    log "Extracting..."
    [ ! -f "${IMAGE_SOURCE}" ] && error "Not found: ${IMAGE_SOURCE}"
    info "Source: $(du -h ${IMAGE_SOURCE} | cut -f1)"
    
    local avail=$(df -BM "${WORK_DIR}" | tail -1 | awk '{print $4}' | sed 's/M//')
    [ ${avail} -lt 5000 ] && warn "Low space: ${avail}MB" && read -p "Continue? (y/N) " -n 1 -r && echo && [[ ! $REPLY =~ ^[Yy]$ ]] && error "Aborted"
    
    # Check if image is compressed or already extracted
    if [[ "${IMAGE_SOURCE}" == *.xz ]]; then
        info "Compressed image detected, extracting..."
        cp "${IMAGE_SOURCE}" "${WORK_DIR}/" || error "Copy failed"
        unxz -fv "${WORK_DIR}/$(basename ${IMAGE_SOURCE})" || error "Extract failed"
    else
        info "Uncompressed image detected, copying..."
        cp "${IMAGE_SOURCE}" "${WORK_DIR}/${IMAGE_NAME}" || error "Copy failed"
    fi
    
    [ ! -f "${WORK_DIR}/${IMAGE_NAME}" ] && error "Image preparation failed"
    log "Ready: $(du -h ${WORK_DIR}/${IMAGE_NAME} | cut -f1)"
}

run_sdm() {
    log "Running SDM..."
    
    local sdm_cmd="sdm --batch"
    
    if [ "$EXTEND_SIZE_MB" -gt 0 ]; then
        sdm_cmd="$sdm_cmd --extend --xmb ${EXTEND_SIZE_MB}"
        info "Extending image by ${EXTEND_SIZE_MB}MB"
    else
        info "Skipping image extension (using existing space)"
        sdm_cmd="$sdm_cmd --redo-customize"
    fi
    
    sdm_cmd="$sdm_cmd --customize"
    
    if [ -n "$PI_PASSWORD" ]; then
        sdm_cmd="$sdm_cmd --plugin user:\"adduser=pi|password=${PI_PASSWORD}\""
    fi
    
    sdm_cmd="$sdm_cmd --plugin disables:piwiz --expand-root --nowait-timesync \
        \"${WORK_DIR}/${IMAGE_NAME}\""
    
    eval $sdm_cmd
    log "SDM complete"
}

mount_image() {
    log "Mounting..."
    local ld=$(losetup -f)
    [ -z "$ld" ] && error "No loop device"
    losetup -P "${ld}" "${WORK_DIR}/${IMAGE_NAME}"
    sleep 2 && partprobe "${ld}" 2>/dev/null || true && sleep 1
    [ ! -e "${ld}p2" ] && error "Partition ${ld}p2 not found"
    mount "${ld}p2" "${MOUNT_POINT}"
    mkdir -p "${MOUNT_POINT}/boot/firmware"
    mount "${ld}p1" "${MOUNT_POINT}/boot/firmware"
    echo "${ld}" > "${WORK_DIR}/loop_device"
    log "Mounted"
}

setup_qemu_chroot() {
    log "Setting up QEMU chroot..."
    [ ! -f /usr/bin/qemu-aarch64-static ] && error "qemu-aarch64-static not found"
    cp /usr/bin/qemu-aarch64-static "${MOUNT_POINT}/usr/bin/"
    chmod +x "${MOUNT_POINT}/usr/bin/qemu-aarch64-static"
    mount -t proc /proc "${MOUNT_POINT}/proc"
    mount -t sysfs /sys "${MOUNT_POINT}/sys"
    mount --bind /dev "${MOUNT_POINT}/dev"
    mount --bind /dev/pts "${MOUNT_POINT}/dev/pts"
    cp -L /etc/resolv.conf "${MOUNT_POINT}/etc/resolv.conf"
    chroot "${MOUNT_POINT}" /bin/bash -c "echo 'Test'" >/dev/null 2>&1 || error "Chroot test failed"
    log "Chroot ready"
}

set_user_password() {
    if [ -z "$PI_PASSWORD" ]; then
        info "No password provided, keeping existing password"
        
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' "${MOUNT_POINT}/etc/ssh/sshd_config"
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "${MOUNT_POINT}/etc/ssh/sshd_config"
        
        if [ ! -e "${MOUNT_POINT}/etc/systemd/system/multi-user.target.wants/ssh.service" ]; then
            mkdir -p "${MOUNT_POINT}/etc/systemd/system/multi-user.target.wants"
            ln -sf /lib/systemd/system/ssh.service "${MOUNT_POINT}/etc/systemd/system/multi-user.target.wants/ssh.service"
        fi
        
        log "SSH configured (password unchanged)"
        return 0
    fi
    
    log "Setting password for 'pi'..."
    local epw=$(echo "${PI_PASSWORD}" | openssl passwd -6 -stdin)
    grep -q "^pi:" "${MOUNT_POINT}/etc/passwd" && info "User found" || warn "User 'pi' not found"
    sed -i "s|^pi:[^:]*:|pi:${epw}:|" "${MOUNT_POINT}/etc/shadow"
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' "${MOUNT_POINT}/etc/ssh/sshd_config"
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "${MOUNT_POINT}/etc/ssh/sshd_config"
    
    if [ ! -e "${MOUNT_POINT}/etc/systemd/system/multi-user.target.wants/ssh.service" ]; then
        mkdir -p "${MOUNT_POINT}/etc/systemd/system/multi-user.target.wants"
        ln -sf /lib/systemd/system/ssh.service "${MOUNT_POINT}/etc/systemd/system/multi-user.target.wants/ssh.service"
    fi
    
    log "Password and SSH configured"
}

install_packages() {
    [ "$SKIP_PACKAGES" = true ] && info "Skipping packages" && return 0
    log "Installing packages from: ${PACKAGE_LIST_FILE}"
    [ ! -f "${PACKAGE_LIST_FILE}" ] && error "Not found: ${PACKAGE_LIST_FILE}"
    local pkgs=$(grep -v '^#' "${PACKAGE_LIST_FILE}" | grep -v '^[[:space:]]*$' | tr '\n' ' ')
    [ -z "$pkgs" ] && warn "No packages" && return 0
    info "Packages: ${pkgs}"
    chroot "${MOUNT_POINT}" /bin/bash <<CHROOT_EOF
set -e
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ${pkgs}
CHROOT_EOF
    log "Packages installed"
}

copy_micropanel() {
    [ "$SKIP_MICROPANEL" = true ] && info "Skipping micropanel" && return 0
    log "Copying micropanel..."
    local tmp="${WORK_DIR}/micropanel-temp"
    mkdir -p "${tmp}"
    
    if [[ "$SOURCE_FILES_HOST" == *@*:* ]]; then
        info "Downloading via SCP..."
        if [ -n "$SCP_PASSWORD" ]; then
            sshpass -p "$SCP_PASSWORD" scp -r "${SOURCE_FILES_HOST}" "${tmp}/" || error "SCP failed"
        else
            scp -r "${SOURCE_FILES_HOST}" "${tmp}/" || error "SCP failed"
        fi
    else
        info "Copying local..."
        [ ! -d "${SOURCE_FILES_HOST}" ] && [ ! -f "${SOURCE_FILES_HOST}" ] && error "Not found: ${SOURCE_FILES_HOST}"
        cp -r "${SOURCE_FILES_HOST}" "${tmp}/" || error "Copy failed"
    fi
    
    local src
    [ -d "${tmp}/micropanel-install-dump" ] && src="${tmp}/micropanel-install-dump" || \
        src=$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d | head -n1)
    [ -z "$src" ] && error "Micropanel dir not found"
    
    mkdir -p "${MOUNT_POINT}/home/pi"
    cp -r "${src}" "${MOUNT_POINT}/home/pi/micropanel"
    chown -R 1000:1000 "${MOUNT_POINT}/home/pi/micropanel"
    log "Micropanel copied: $(du -sh ${MOUNT_POINT}/home/pi/micropanel | cut -f1)"
}

configure_system() {
    [ -z "$CONFIGURE_SCRIPT" ] && info "No configuration script, skipping" && return 0
    log "Running: ${CONFIGURE_SCRIPT}"
    [ ! -f "${CONFIGURE_SCRIPT}" ] && error "Not found: ${CONFIGURE_SCRIPT}"
    [ ! -x "${CONFIGURE_SCRIPT}" ] && warn "Making executable..." && chmod +x "${CONFIGURE_SCRIPT}"
    
    export MOUNT_POINT="${MOUNT_POINT}"
    export PI_PASSWORD="${PI_PASSWORD}"
    export MICROPANEL_INSTALLED="$([ "$SKIP_MICROPANEL" = false ] && echo "true" || echo "false")"
    export IMAGE_WORK_DIR="${WORK_DIR}"
    
    local sn=$(basename "${CONFIGURE_SCRIPT}")
    cp "${CONFIGURE_SCRIPT}" "${MOUNT_POINT}/tmp/${sn}"
    chmod +x "${MOUNT_POINT}/tmp/${sn}"
    
    info "Environment: MOUNT_POINT=${MOUNT_POINT}, MICROPANEL_INSTALLED=${MICROPANEL_INSTALLED}"
    chroot "${MOUNT_POINT}" /bin/bash -c "cd /tmp && ./${sn}" || error "Script failed"
    rm -f "${MOUNT_POINT}/tmp/${sn}"
    log "Configuration complete"
}

remove_qemu() {
    log "Removing QEMU..."
    rm -f "${MOUNT_POINT}/usr/bin/qemu-aarch64-static"
}

verify_image() {
    log "Verifying..."
    for d in /bin /etc /home /boot/firmware; do
        [ ! -d "${MOUNT_POINT}${d}" ] && error "Missing: ${d}"
    done
    log "Verified"
}

cleanup() {
    log "Cleaning up..."
    umount -l "${MOUNT_POINT}/dev/pts" 2>/dev/null || true
    umount -l "${MOUNT_POINT}/dev" 2>/dev/null || true
    umount -l "${MOUNT_POINT}/sys" 2>/dev/null || true
    umount -l "${MOUNT_POINT}/proc" 2>/dev/null || true
    umount -l "${MOUNT_POINT}/boot/firmware" 2>/dev/null || true
    umount -l "${MOUNT_POINT}" 2>/dev/null || true
    sleep 2
    if [ -f "${WORK_DIR}/loop_device" ]; then
        local ld=$(cat "${WORK_DIR}/loop_device")
        [ -n "$ld" ] && losetup -d "${ld}" 2>/dev/null || true
        rm "${WORK_DIR}/loop_device"
    fi
    log "Done"
}

show_summary() {
    echo ""
    echo "=================================="
    log "✓ Customization complete!"
    echo "=================================="
    echo "Image: ${WORK_DIR}/${IMAGE_NAME}"
    echo "Size:  $(du -h ${WORK_DIR}/${IMAGE_NAME} | cut -f1)"
    echo ""
    echo "Write to SD: sudo dd if=${WORK_DIR}/${IMAGE_NAME} of=/dev/sdX bs=8M status=progress"
    echo ""
    info "First boot will auto-expand root"
    [ "$SKIP_PACKAGES" = true ] && warn "Packages NOT installed"
    [ "$SKIP_MICROPANEL" = true ] && warn "Micropanel NOT installed"
    echo ""
}

# Parse arguments first (so --help works without sudo)
parse_arguments "$@"

# Now check if root is needed for actual operations
[ "$EUID" -ne 0 ] && error "Run as root (use sudo)"

# Set trap for cleanup
trap cleanup EXIT

main() {
    log "Starting..."
    echo ""
    show_configuration
    check_arch_linux
    check_prerequisites
    setup_workdir
    extract_image
    run_sdm
    mount_image
    setup_qemu_chroot
    set_user_password
    install_packages
    copy_micropanel
    configure_system
    verify_image
    remove_qemu
    show_summary
}

main
