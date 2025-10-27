#!/bin/bash
set -e

# Configuration
MODE=""
PI_PASSWORD=""
EXTEND_SIZE_MB=""
IMAGE_SOURCE=""
IMAGE_NAME=""
WORK_DIR=""
MOUNT_POINT=""
RUNTIME_PACKAGE=""
BUILDDEP_PACKAGE=""
POST_BUILD_SCRIPT=""
SETUP_HOOKS=()
SETUP_HOOKS_FILE=""

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
  sudo $0 --mode=MODE --baseimage=PATH --output=DIR [OPTIONS]

Mandatory Arguments:
  --mode=MODE               Build mode: 'base' or 'incremental'
  --baseimage=PATH          Path to base Raspberry Pi OS image (.img.xz)
  --output=DIR              Output directory for image customization
  --builddep-package=FILE   Build dependencies (use 'none' if not needed)

Optional Arguments (Base Mode):
  --password=PASS           Password for 'pi' user (default: keep existing)
  --extend-size-mb=SIZE     Image extension size in MB (default: 0)
  --runtime-package=FILE    Runtime dependencies

Optional Arguments (Incremental Mode):
  --setup-hook=FILE         Setup hook script (multiple allowed, runs in chroot)
                            Receives: MOUNT_POINT, PI_PASSWORD, IMAGE_WORK_DIR
  --setup-hook-list=FILE    File containing list of setup hooks (one per line)
                            Format: HOOK_SCRIPT[|GIT_REPO|TAG|DEST|DEPS]
                            Simple: packages/my-hook.sh
                            Parameterized: packages/generic-hook.sh|https://github.com/user/repo.git|v1.0|/home/pi/app|lib1,lib2
  --post-build-script=FILE  Post-build configuration script (runs in chroot)
                            Receives: MOUNT_POINT, PI_PASSWORD, IMAGE_WORK_DIR

Optional Arguments (Both Modes):
  --help, -h                Show this help

Examples:
  # Stage 1: Base image with dependencies
  sudo $0 --mode=base --baseimage=./raspios.img.xz --output=/tmp/base \\
    --password=brb0x --extend-size-mb=1000 \\
    --runtime-package=./runtime-deps.txt \\
    --builddep-package=./build-deps.txt

  # Stage 2: Incremental build with individual hooks
  sudo $0 --mode=incremental --baseimage=./base.img.xz --output=/tmp/custom \\
    --builddep-package=./build-deps.txt \\
    --setup-hook=./micropanel-hook.sh \\
    --setup-hook=./test-daemon-hook.sh \\
    --post-build-script=./finalize.sh

  # Stage 2: Incremental build with hook list file
  sudo $0 --mode=incremental --baseimage=./base.img.xz --output=/tmp/custom \\
    --builddep-package=./build-deps.txt \\
    --setup-hook-list=./hook-packages.txt \\
    --post-build-script=./finalize.sh

  # Base mode with no build dependencies
  sudo $0 --mode=base --baseimage=./raspios.img.xz --output=/tmp/base \\
    --runtime-package=./runtime-deps.txt \\
    --builddep-package=none

EOF
    exit 0
}

parse_arguments() {
    [ $# -eq 0 ] && show_usage

    for arg in "$@"; do
        case $arg in
            --mode=*) MODE="${arg#*=}" ;;
            --baseimage=*) IMAGE_SOURCE="${arg#*=}" ;;
            --output=*) WORK_DIR="${arg#*=}" ;;
            --password=*) PI_PASSWORD="${arg#*=}" ;;
            --extend-size-mb=*) EXTEND_SIZE_MB="${arg#*=}" ;;
            --runtime-package=*) RUNTIME_PACKAGE="${arg#*=}" ;;
            --builddep-package=*) BUILDDEP_PACKAGE="${arg#*=}" ;;
            --setup-hook=*) SETUP_HOOKS+=("${arg#*=}") ;;
            --setup-hook-list=*) SETUP_HOOKS_FILE="${arg#*=}" ;;
            --post-build-script=*) POST_BUILD_SCRIPT="${arg#*=}" ;;
            --help|-h) show_usage ;;
            *) error "Unknown argument: $arg\nUse --help for usage" ;;
        esac
    done

    # Validate required arguments
    local missing=()
    [ -z "$MODE" ] && missing+=("--mode")
    [ -z "$IMAGE_SOURCE" ] && missing+=("--baseimage")
    [ -z "$WORK_DIR" ] && missing+=("--output")
    [ -z "$BUILDDEP_PACKAGE" ] && missing+=("--builddep-package")
    [ ${#missing[@]} -gt 0 ] && error "Missing required arguments: ${missing[*]}\nUse --help for usage"

    # Validate mode value
    case "$MODE" in
        base|incremental) ;;
        *)
            echo -e "${RED}Error: Invalid --mode value: '$MODE'${NC}"
            echo "Must be 'base' or 'incremental'"
            echo ""
            show_usage
            ;;
    esac

    # Handle 'none' keyword for builddep-package
    if [ "$BUILDDEP_PACKAGE" = "none" ]; then
        info "No build dependencies specified"
        BUILDDEP_PACKAGE=""
    fi

    # Set defaults
    [ -z "$EXTEND_SIZE_MB" ] && EXTEND_SIZE_MB=0
    [ -z "$PI_PASSWORD" ] && info "No password specified, keeping existing password"

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

    # Normalize runtime-package path
    if [ -n "$RUNTIME_PACKAGE" ] && [[ "$RUNTIME_PACKAGE" != /* ]]; then
        RUNTIME_PACKAGE="$(cd "$(dirname "$RUNTIME_PACKAGE")" 2>/dev/null && pwd)/$(basename "$RUNTIME_PACKAGE")" || RUNTIME_PACKAGE="$(pwd)/$RUNTIME_PACKAGE"
    fi

    # Normalize builddep-package path (skip if empty after 'none' handling)
    if [ -n "$BUILDDEP_PACKAGE" ] && [[ "$BUILDDEP_PACKAGE" != /* ]]; then
        BUILDDEP_PACKAGE="$(cd "$(dirname "$BUILDDEP_PACKAGE")" 2>/dev/null && pwd)/$(basename "$BUILDDEP_PACKAGE")" || BUILDDEP_PACKAGE="$(pwd)/$BUILDDEP_PACKAGE"
    fi

    # Normalize setup-hooks paths (array)
    for i in "${!SETUP_HOOKS[@]}"; do
        if [[ "${SETUP_HOOKS[$i]}" != /* ]]; then
            SETUP_HOOKS[$i]="$(cd "$(dirname "${SETUP_HOOKS[$i]}")" 2>/dev/null && pwd)/$(basename "${SETUP_HOOKS[$i]}")" || SETUP_HOOKS[$i]="$(pwd)/${SETUP_HOOKS[$i]}"
        fi
    done

    # Normalize post-build-script path
    if [ -n "$POST_BUILD_SCRIPT" ] && [[ "$POST_BUILD_SCRIPT" != /* ]]; then
        POST_BUILD_SCRIPT="$(cd "$(dirname "$POST_BUILD_SCRIPT")" 2>/dev/null && pwd)/$(basename "$POST_BUILD_SCRIPT")" || POST_BUILD_SCRIPT="$(pwd)/$POST_BUILD_SCRIPT"
    fi

    # Normalize setup-hook-list path
    if [ -n "$SETUP_HOOKS_FILE" ] && [[ "$SETUP_HOOKS_FILE" != /* ]]; then
        SETUP_HOOKS_FILE="$(cd "$(dirname "$SETUP_HOOKS_FILE")" 2>/dev/null && pwd)/$(basename "$SETUP_HOOKS_FILE")" || SETUP_HOOKS_FILE="$(pwd)/$SETUP_HOOKS_FILE"
    fi

    IMAGE_NAME="$(basename "$IMAGE_SOURCE")"
    IMAGE_NAME="${IMAGE_NAME%.xz}"
    MOUNT_POINT="${WORK_DIR}/mnt"

    # Mode-aware file validation
    validate_files

    return 0
}

validate_files() {
    log "Validating files..."

    # Always validate base image
    [ ! -f "$IMAGE_SOURCE" ] && error "Base image not found: $IMAGE_SOURCE"

    # Mode-specific validation
    if [ "$MODE" = "base" ]; then
        # Base mode: validate runtime and builddep packages
        [ -n "$RUNTIME_PACKAGE" ] && [ ! -f "$RUNTIME_PACKAGE" ] && error "Runtime package file not found: $RUNTIME_PACKAGE"
        [ -n "$BUILDDEP_PACKAGE" ] && [ ! -f "$BUILDDEP_PACKAGE" ] && error "Build dependency file not found: $BUILDDEP_PACKAGE"

        # Warn about ignored arguments
        [ ${#SETUP_HOOKS[@]} -gt 0 ] && warn "Ignoring --setup-hook in base mode"
        [ -n "$POST_BUILD_SCRIPT" ] && warn "Ignoring --post-build-script in base mode"
    fi

    if [ "$MODE" = "incremental" ]; then
        # Incremental mode: validate builddep, hooks, post-build script
        [ -n "$BUILDDEP_PACKAGE" ] && [ ! -f "$BUILDDEP_PACKAGE" ] && error "Build dependency file not found: $BUILDDEP_PACKAGE"

        # Validate setup-hook-list file
        [ -n "$SETUP_HOOKS_FILE" ] && [ ! -f "$SETUP_HOOKS_FILE" ] && error "Setup hook list file not found: $SETUP_HOOKS_FILE"

        # Validate all setup hooks
        for hook in "${SETUP_HOOKS[@]}"; do
            [ ! -f "$hook" ] && error "Setup hook not found: $hook"
        done

        # Validate post-build script
        [ -n "$POST_BUILD_SCRIPT" ] && [ ! -f "$POST_BUILD_SCRIPT" ] && error "Post-build script not found: $POST_BUILD_SCRIPT"

        # Silent ignore for runtime-package (user might keep it in script)
        # Warn about extend-size-mb
        [ "$EXTEND_SIZE_MB" -gt 0 ] && warn "Cannot extend image size in incremental mode (ignoring)"
    fi

    log "File validation complete"
}

show_configuration() {
    info "Configuration:"
    echo "  Mode:            ${MODE}"
    echo "  Base Image:      ${IMAGE_SOURCE}"
    echo "  Output Dir:      ${WORK_DIR}"
    echo "  Password:        $([ -z "$PI_PASSWORD" ] && echo "[KEEP EXISTING]" || echo "${PI_PASSWORD//?/*}")"

    if [ "$MODE" = "base" ]; then
        echo ""
        echo "  Base Mode Settings:"
        echo "  ├─ Extend Size:     $([ "$EXTEND_SIZE_MB" -eq 0 ] && echo "[NONE]" || echo "${EXTEND_SIZE_MB} MB")"
        echo "  ├─ Runtime Pkgs:    $([ -z "$RUNTIME_PACKAGE" ] && echo "[NONE]" || echo "${RUNTIME_PACKAGE}")"
        echo "  └─ Build Deps:      $([ -z "$BUILDDEP_PACKAGE" ] && echo "[NONE]" || echo "${BUILDDEP_PACKAGE}")"
    fi

    if [ "$MODE" = "incremental" ]; then
        echo ""
        echo "  Incremental Mode Settings:"
        echo "  ├─ Build Deps:      $([ -z "$BUILDDEP_PACKAGE" ] && echo "[NONE]" || echo "${BUILDDEP_PACKAGE} [WILL PURGE]")"
        echo "  ├─ Hook List File:  $([ -z "$SETUP_HOOKS_FILE" ] && echo "[NONE]" || echo "${SETUP_HOOKS_FILE}")"
        echo "  ├─ Setup Hooks:     $([ ${#SETUP_HOOKS[@]} -eq 0 ] && echo "[NONE]" || echo "${#SETUP_HOOKS[@]} hook(s)")"
        if [ ${#SETUP_HOOKS[@]} -gt 0 ]; then
            for i in "${!SETUP_HOOKS[@]}"; do
                echo "  │  $((i+1)). ${SETUP_HOOKS[$i]}"
            done
        fi
        echo "  └─ Post-Build:      $([ -z "$POST_BUILD_SCRIPT" ] && echo "[NONE]" || echo "${POST_BUILD_SCRIPT}")"
    fi

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
    
    for tool in unxz losetup mount umount chroot; do
        command -v $tool >/dev/null 2>&1 || error "Missing: $tool"
    done

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
    # Only run in base mode
    [ "$MODE" != "base" ] && info "Skipping package installation (incremental mode)" && return 0

    local all_packages=""

    # Add runtime packages
    if [ -n "$RUNTIME_PACKAGE" ]; then
        log "Reading runtime packages from: ${RUNTIME_PACKAGE}"
        local runtime=$(grep -v '^#' "${RUNTIME_PACKAGE}" | grep -v '^[[:space:]]*$' | tr '\n' ' ')
        all_packages+="$runtime "
        info "Runtime packages: ${runtime}"
    fi

    # Add build dependencies
    if [ -n "$BUILDDEP_PACKAGE" ]; then
        log "Reading build dependencies from: ${BUILDDEP_PACKAGE}"
        local builddeps=$(grep -v '^#' "${BUILDDEP_PACKAGE}" | grep -v '^[[:space:]]*$' | tr '\n' ' ')
        all_packages+="$builddeps "
        info "Build dependencies: ${builddeps}"
    fi

    [ -z "$all_packages" ] && info "No packages to install" && return 0

    log "Installing packages..."
    chroot "${MOUNT_POINT}" /bin/bash <<CHROOT_EOF
set -e
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ${all_packages}
CHROOT_EOF

    log "Packages installed successfully"
}

load_hooks_from_file() {
    [ -z "$SETUP_HOOKS_FILE" ] && return 0

    log "Loading hooks from: $SETUP_HOOKS_FILE"
    local line_num=0

    while IFS= read -r line; do
        line_num=$((line_num + 1))

        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Parse line: HOOK_SCRIPT[|GIT_REPO|GIT_TAG|INSTALL_DEST|DEP_LIST]
        # Use pipe (|) as separator to avoid conflicts with URLs (https://)
        IFS='|' read -r hook_script git_repo git_tag install_dest dep_list <<< "$line"

        # Determine field count
        local field_count=1
        [ -n "$git_repo" ] && field_count=5

        # Validate field count (1 = simple, 5 = parameterized)
        if [ "$field_count" != "1" ] && [ "$field_count" != "5" ]; then
            error "Invalid format at line $line_num in $SETUP_HOOKS_FILE\nExpected 1 or 5 pipe-separated fields\nLine: $line"
        fi

        # Normalize hook script path (relative to absolute)
        if [[ "$hook_script" != /* ]]; then
            # Get directory of hook-packages.txt file
            local hooks_dir="$(dirname "$SETUP_HOOKS_FILE")"
            hook_script="${hooks_dir}/${hook_script}"
        fi

        # Validate that hook script exists
        if [ ! -f "$hook_script" ]; then
            error "Hook script not found at line $line_num in $SETUP_HOOKS_FILE\nScript: $hook_script\nLine: $line"
        fi

        # Reconstruct line with absolute path
        if [ "$field_count" = "1" ]; then
            # Simple format: just the normalized path
            SETUP_HOOKS+=("$hook_script")
        else
            # Parameterized format: rebuild with normalized path using pipe separator
            SETUP_HOOKS+=("$hook_script|$git_repo|$git_tag|$install_dest|$dep_list")
        fi

    done < "$SETUP_HOOKS_FILE"

    info "Loaded ${#SETUP_HOOKS[@]} hook(s) from file"
}

run_setup_hooks() {
    # Only run in incremental mode
    [ "$MODE" != "incremental" ] && info "Skipping setup hooks (base mode)" && return 0

    # Load hooks from file if specified
    load_hooks_from_file

    [ ${#SETUP_HOOKS[@]} -eq 0 ] && info "No setup hooks to run" && return 0

    log "Running ${#SETUP_HOOKS[@]} setup hook(s)..."

    for i in "${!SETUP_HOOKS[@]}"; do
        local hook_line="${SETUP_HOOKS[$i]}"

        # Parse hook line: could be simple (1 field) or parameterized (5 fields)
        # Use pipe (|) as separator to avoid conflicts with URLs
        IFS='|' read -r hook_script git_repo git_tag install_dest dep_list <<< "$hook_line"

        # Determine if simple or parameterized
        if [ -z "$git_repo" ]; then
            # Simple format: just the hook script path
            log "[$((i+1))/${#SETUP_HOOKS[@]}] Running: ${hook_script}"
        else
            # Parameterized format: all fields present
            # Extract HOOK_NAME from git repo URL (last path component, remove .git)
            local hook_name=$(basename "$git_repo" .git)

            log "[$((i+1))/${#SETUP_HOOKS[@]}] Running: ${hook_script} (${hook_name} ${git_tag})"

            # Export parameterized environment variables
            export HOOK_GIT_REPO="$git_repo"
            export HOOK_GIT_TAG="$git_tag"
            export HOOK_INSTALL_DEST="$install_dest"
            export HOOK_NAME="$hook_name"
            export HOOK_DEP_LIST="$dep_list"

            info "  HOOK_NAME=$hook_name, HOOK_GIT_TAG=$git_tag"
            info "  HOOK_INSTALL_DEST=$install_dest"
            [ -n "$dep_list" ] && info "  HOOK_DEP_LIST=$dep_list"
        fi

        # Validate and prepare hook script
        [ ! -f "$hook_script" ] && error "Hook script not found: $hook_script"
        [ ! -x "$hook_script" ] && warn "Making executable..." && chmod +x "$hook_script"

        # Export common environment variables
        export MOUNT_POINT="${MOUNT_POINT}"
        export PI_PASSWORD="${PI_PASSWORD}"
        export IMAGE_WORK_DIR="${WORK_DIR}"

        # Copy hook to chroot and execute
        local hook_basename=$(basename "$hook_script")
        cp "$hook_script" "${MOUNT_POINT}/tmp/${hook_basename}"
        chmod +x "${MOUNT_POINT}/tmp/${hook_basename}"

        chroot "${MOUNT_POINT}" /bin/bash -c "cd /tmp && ./${hook_basename}" || error "Setup hook failed: ${hook_script}"
        rm -f "${MOUNT_POINT}/tmp/${hook_basename}"

        # Unset parameterized environment variables
        if [ "$field_count" != "1" ]; then
            unset HOOK_GIT_REPO HOOK_GIT_TAG HOOK_INSTALL_DEST HOOK_NAME HOOK_DEP_LIST
        fi

        log "[$((i+1))/${#SETUP_HOOKS[@]}] Complete: ${hook_script}"
    done

    log "All setup hooks completed successfully"
}

run_post_build_script() {
    # Only run in incremental mode
    [ "$MODE" != "incremental" ] && info "Skipping post-build script (base mode)" && return 0

    [ -z "$POST_BUILD_SCRIPT" ] && info "No post-build script specified" && return 0
    log "Running post-build script: ${POST_BUILD_SCRIPT}"
    [ ! -f "${POST_BUILD_SCRIPT}" ] && error "Not found: ${POST_BUILD_SCRIPT}"
    [ ! -x "${POST_BUILD_SCRIPT}" ] && warn "Making executable..." && chmod +x "${POST_BUILD_SCRIPT}"

    export MOUNT_POINT="${MOUNT_POINT}"
    export PI_PASSWORD="${PI_PASSWORD}"
    export IMAGE_WORK_DIR="${WORK_DIR}"

    local script_name=$(basename "${POST_BUILD_SCRIPT}")
    cp "${POST_BUILD_SCRIPT}" "${MOUNT_POINT}/tmp/${script_name}"
    chmod +x "${MOUNT_POINT}/tmp/${script_name}"

    info "Environment: MOUNT_POINT=${MOUNT_POINT}, IMAGE_WORK_DIR=${IMAGE_WORK_DIR}"
    chroot "${MOUNT_POINT}" /bin/bash -c "cd /tmp && ./${script_name}" || error "Post-build script failed"
    rm -f "${MOUNT_POINT}/tmp/${script_name}"
    log "Post-build script complete"
}

purge_build_dependencies() {
    # Only run in incremental mode
    [ "$MODE" != "incremental" ] && info "Skipping build dependency purge (base mode)" && return 0

    [ -z "$BUILDDEP_PACKAGE" ] && info "No build dependencies to purge" && return 0

    log "Purging build dependencies from: ${BUILDDEP_PACKAGE}"

    local pkgs=$(grep -v '^#' "${BUILDDEP_PACKAGE}" | grep -v '^[[:space:]]*$' | tr '\n' ' ')
    [ -z "$pkgs" ] && warn "Build dependency file is empty, nothing to purge" && return 0

    info "Removing packages: ${pkgs}"

    chroot "${MOUNT_POINT}" /bin/bash <<CHROOT_EOF
set -e
apt-get purge -y ${pkgs}
apt-get autoremove -y
apt-get clean
CHROOT_EOF

    log "Build dependencies purged successfully"
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
    echo "Mode:  ${MODE}"
    echo "Image: ${WORK_DIR}/${IMAGE_NAME}"
    echo "Size:  $(du -h ${WORK_DIR}/${IMAGE_NAME} | cut -f1)"
    echo ""
    echo "Write to SD: sudo dd if=${WORK_DIR}/${IMAGE_NAME} of=/dev/sdX bs=8M status=progress"
    echo ""
    info "First boot will auto-expand root"

    if [ "$MODE" = "base" ]; then
        [ -z "$RUNTIME_PACKAGE" ] && warn "No runtime packages installed"
        [ -z "$BUILDDEP_PACKAGE" ] && warn "No build dependencies installed"
    fi

    if [ "$MODE" = "incremental" ]; then
        [ ${#SETUP_HOOKS[@]} -eq 0 ] && warn "No setup hooks executed"
        [ -z "$POST_BUILD_SCRIPT" ] && warn "No post-build script executed"
        [ -n "$BUILDDEP_PACKAGE" ] && info "Build dependencies purged"
    fi

    echo ""
}

# Parse arguments first (so --help works without sudo)
parse_arguments "$@"

# Now check if root is needed for actual operations
[ "$EUID" -ne 0 ] && error "Run as root (use sudo)"

# Set trap for cleanup
trap cleanup EXIT

main() {
    log "Starting Custom Pi Imager..."
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
    install_packages           # Base mode only
    run_setup_hooks            # Incremental mode only
    run_post_build_script      # Incremental mode only
    purge_build_dependencies   # Incremental mode only
    verify_image
    remove_qemu
    show_summary
}

main
