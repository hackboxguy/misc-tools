#!/bin/bash
# ==============================================================================
# build-image.sh - single-command custom Raspberry Pi 4 SD-card image builder
# ==============================================================================
# Builds a fully customized RaspiOS-lite image for a given board config in
# three cached stages:
#
#   sources : clone/update dependent repos into <workspace>/sources
#   base    : vanilla img.xz -> extended image + apt runtime/build deps
#             (custom-pi-imager.sh --mode=base)
#   kernel  : cross-compile kernel + out-of-tree drivers, install into image
#             (custom-pi-kernel-builder/scripts/00-build-all.sh)  [KERNEL=1]
#   apps    : run setup hooks in QEMU chroot, purge build deps
#             (custom-pi-imager.sh --mode=incremental)
#
# Each stage records a hash of its inputs; unchanged stages are skipped
# automatically on re-runs. Board configs live in board-configs/<name>/board.conf.
#
# Usage:
#   sudo ./build-image.sh --board=NAME [OPTIONS]
#   sudo ./build-image.sh --base-profile=NAME   (no --board: build only the
#                                                shared base-profile image)
#   ./build-image.sh --list-boards
#   ./build-image.sh --board=NAME --dry-run     (no root needed)
#
# Options:
#   --board=NAME        Board config from board-configs/ (required)
#   --variant=NAME      Board variant (per-variant overrides in board.conf)
#   --version=VER       Image version string (default: DEFAULT_VERSION)
#   --password=PASS     'pi' user password (default: DEFAULT_PASSWORD)
#   --extend-size-mb=N  Image extension applied by sdm in the base stage
#                       (default: EXTEND_SIZE_MB from board.conf; changing
#                       it rebuilds base and everything after it)
#   --base-profile=NAME Override the board's BASE_PROFILE (base-configs/NAME);
#                       'none' disables the profile. A profile may pin its own
#                       IMAGE_URL so the matching vanilla image is used
#                       automatically. Precedence: CLI --image-url > profile
#                       IMAGE_URL > board IMAGE_URL.
#   --workspace=DIR     Workspace directory (default: ~/pi-image-workspace)
#   --sources-dir=DIR   Where dependent repos are cloned/updated
#                       (default: <workspace>/sources); also the default
#                       location for ${REPOBINS} hook sources
#   --output-dir=DIR    Where the final image is placed
#                       (default: <workspace>/out/<board>[-variant])
#   --baseimage=FILE    Use this local vanilla image (.img.xz/.img), no download
#   --image-url=URL     Download this vanilla image instead of board default
#   --start-from=FILE   Existing prepared base (or base+kernel) image; skips
#                       the base and kernel stages entirely
#   --repobins=DIR      Directory for file:// hook sources (default:
#                       <workspace>/sources); use e.g. ~/repobins to build
#                       from local checkouts instead of fresh clones
#   --skip-base --skip-kernel --skip-apps
#                       Skip a stage even if its inputs changed
#   --force-base --force-kernel --force-apps
#                       Re-run a stage even if its inputs are unchanged
#   --dry-run           Preflight checks + build plan only, change nothing
#   --offline           No downloads/clones/fetches; fail if anything is missing
#   --flash=/dev/sdX    Write the final image to a block device (asks first)
#   --keep-build-deps   Pass through to imager (skip build-dep purge)
#   --debug             Pass --debug to imager (keep mounted on error)
#   --list-boards       List available board configs and exit
#   --help
#
# Environment:
#   GIT_USERNAME + GIT_TOKEN   One-shot GitHub credentials (PAT) for private
#                              source repos on machines without a stored git
#                              credential helper; used only for the sources
#                              stage via a 0600 temp credential file.
#                              sudo GIT_USERNAME=you GIT_TOKEN=ghp_xxx ./build-image.sh ...
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGER="$SCRIPT_DIR/custom-pi-imager/custom-pi-imager.sh"
KERNEL_BUILDER="$SCRIPT_DIR/custom-pi-kernel-builder/scripts/00-build-all.sh"
BOARD_CONFIGS_DIR="$SCRIPT_DIR/board-configs"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $*"; }
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
stage_banner() { echo ""; echo "=============================================================="; echo " $*"; echo "=============================================================="; }

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
BOARD="" VARIANT="" VERSION="" PASSWORD="" WORKSPACE=""
ARG_BASEIMAGE="" ARG_IMAGE_URL="" ARG_START_FROM="" ARG_REPOBINS="" ARG_FLASH=""
ARG_SOURCES_DIR="" ARG_OUTPUT_DIR="" ARG_EXTEND_SIZE="" ARG_BASE_PROFILE=""
SKIP_BASE=0 SKIP_KERNEL=0 SKIP_APPS=0
FORCE_BASE=0 FORCE_KERNEL=0 FORCE_APPS=0
DRY_RUN=0 OFFLINE=0 KEEP_BUILD_DEPS=0 DEBUG=0 LIST_BOARDS=0

usage() { sed -n '/^# Usage:/,/^# ====/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d'; exit 0; }

for arg in "$@"; do
    case "$arg" in
        --board=*)      BOARD="${arg#*=}" ;;
        --variant=*)    VARIANT="${arg#*=}" ;;
        --version=*)    VERSION="${arg#*=}" ;;
        --password=*)   PASSWORD="${arg#*=}" ;;
        --workspace=*)  WORKSPACE="${arg#*=}" ;;
        --sources-dir=*) ARG_SOURCES_DIR="${arg#*=}" ;;
        --output-dir=*)  ARG_OUTPUT_DIR="${arg#*=}" ;;
        --extend-size-mb=*) ARG_EXTEND_SIZE="${arg#*=}" ;;
        --base-profile=*)   ARG_BASE_PROFILE="${arg#*=}" ;;
        --baseimage=*)  ARG_BASEIMAGE="${arg#*=}" ;;
        --image-url=*)  ARG_IMAGE_URL="${arg#*=}" ;;
        --start-from=*) ARG_START_FROM="${arg#*=}" ;;
        --repobins=*)   ARG_REPOBINS="${arg#*=}" ;;
        --flash=*)      ARG_FLASH="${arg#*=}" ;;
        --skip-base)    SKIP_BASE=1 ;;
        --skip-kernel)  SKIP_KERNEL=1 ;;
        --skip-apps)    SKIP_APPS=1 ;;
        --force-base)   FORCE_BASE=1 ;;
        --force-kernel) FORCE_KERNEL=1 ;;
        --force-apps)   FORCE_APPS=1 ;;
        --dry-run)      DRY_RUN=1 ;;
        --offline)      OFFLINE=1 ;;
        --keep-build-deps) KEEP_BUILD_DEPS=1 ;;
        --debug)        DEBUG=1 ;;
        --list-boards)  LIST_BOARDS=1 ;;
        --help|-h)      usage ;;
        *) die "Unknown option: $arg (use --help)" ;;
    esac
done

# ------------------------------------------------------------------------------
# Board config handling
# ------------------------------------------------------------------------------
list_boards() {
    echo "Available boards (board-configs/):"
    local conf name desc
    for conf in "$BOARD_CONFIGS_DIR"/*/board.conf; do
        [ -f "$conf" ] || continue
        name="$(basename "$(dirname "$conf")")"
        desc="$(sed -n 's/^BOARD_DESCRIPTION="\(.*\)"$/\1/p' "$conf" | head -1)"
        printf "  %-18s %s\n" "$name" "$desc"
    done
    exit 0
}
[ $LIST_BOARDS -eq 1 ] && list_boards

# Profile-only mode: --base-profile without --board builds just the shared
# base image (no kernel/apps stage) - useful to pre-build the slow base.
PROFILE_ONLY=0
if [ -z "$BOARD" ] && [ -n "$ARG_BASE_PROFILE" ] && [ "$ARG_BASE_PROFILE" != "none" ]; then
    PROFILE_ONLY=1
    BOARD="profile-only"
    SKIP_KERNEL=1 SKIP_APPS=1
fi

[ -z "$BOARD" ] && die "Missing --board=NAME (use --list-boards; or --base-profile=NAME alone to build just a base image)"

# Defaults a board.conf may override
BOARD_DESCRIPTION="" IMAGE_URL="" IMAGE_SHA256="" EXTEND_SIZE_MB=0
DEFAULT_PASSWORD="" DEFAULT_VERSION="01.00"
RUNTIME_DEPS="none" BUILD_DEPS="none" HOOK_LIST=""
KERNEL=0 KERNEL_BRANCH="" KERNEL_CONFIG="" DRIVERS_DIR="" SOURCES=""
BASE_PROFILE="" APPS_EXTEND_SIZE_MB=0
if [ $PROFILE_ONLY -eq 0 ]; then
    BOARD_DIR="$BOARD_CONFIGS_DIR/$BOARD"
    BOARD_CONF="$BOARD_DIR/board.conf"
    [ -f "$BOARD_CONF" ] || die "No board config: $BOARD_CONF"
    # shellcheck disable=SC1090
    source "$BOARD_CONF"
else
    BOARD_DIR="$BOARD_CONFIGS_DIR"   # unused; kept non-empty for path resolution
fi

# Per-variant override: VAR_<variant> (dashes become underscores) wins over VAR.
resolve_cfg() {
    local var="$1"
    if [ -n "$VARIANT" ]; then
        local vkey="${var}_${VARIANT//-/_}"
        if [ -n "${!vkey+x}" ]; then printf '%s' "${!vkey}"; return; fi
    fi
    printf '%s' "${!var}"
}
RUNTIME_DEPS="$(resolve_cfg RUNTIME_DEPS)"
BUILD_DEPS="$(resolve_cfg BUILD_DEPS)"
HOOK_LIST="$(resolve_cfg HOOK_LIST)"
EXTEND_SIZE_MB="$(resolve_cfg EXTEND_SIZE_MB)"
APPS_EXTEND_SIZE_MB="$(resolve_cfg APPS_EXTEND_SIZE_MB)"
IMAGE_URL_CFG="$(resolve_cfg IMAGE_URL)"

# Base profile: several boards can share one base image (vanilla + common apt
# packages + optional profile hooks for heavy compiled deps). The profile owns
# the base-stage parameters (deps, extend size, password); the board keeps its
# own runtime deps (re-asserted in the apps stage) and hook list.
if [ -n "$ARG_BASE_PROFILE" ]; then
    if [ "$ARG_BASE_PROFILE" = "none" ]; then BASE_PROFILE=""; else BASE_PROFILE="$ARG_BASE_PROFILE"; fi
fi
PROFILE_DIR="" BASE_HOOK_LIST=""
BASE_RUNTIME_DEPS="" BASE_BUILD_DEPS=""
if [ -n "$BASE_PROFILE" ]; then
    PROFILE_DIR="$SCRIPT_DIR/base-configs/$BASE_PROFILE"
    [ -f "$PROFILE_DIR/profile.conf" ] || die "No profile config: $PROFILE_DIR/profile.conf"
    # shellcheck disable=SC1090
    source "$PROFILE_DIR/profile.conf"   # EXTEND_SIZE_MB, DEFAULT_PASSWORD, optionally IMAGE_URL (profile-owned)
    IMAGE_URL_CFG="$(resolve_cfg IMAGE_URL)"   # re-resolve: profile may pin its own vanilla image
    [ -f "$PROFILE_DIR/runtime-deps.txt" ] && BASE_RUNTIME_DEPS="$PROFILE_DIR/runtime-deps.txt" || BASE_RUNTIME_DEPS="none"
    [ -f "$PROFILE_DIR/build-deps.txt" ] && BASE_BUILD_DEPS="$PROFILE_DIR/build-deps.txt" || BASE_BUILD_DEPS="none"
    [ -f "$PROFILE_DIR/hooks.txt" ] && BASE_HOOK_LIST="$PROFILE_DIR/hooks.txt"

    # Board files may carry per-profile overrides: VAR_<profile> with dashes
    # as underscores (e.g. RUNTIME_DEPS_qt_trixie=runtime-deps-trixie.txt) -
    # needed when board-level package pins are OS-release-specific (boost
    # runtime lib names differ between bookworm and trixie).
    for _v in RUNTIME_DEPS BUILD_DEPS HOOK_LIST; do
        _pkey="${_v}_${BASE_PROFILE//-/_}"
        if [ -n "${!_pkey+x}" ]; then
            declare "$_v=${!_pkey}"
            info "Using board ${_v,,} override for profile $BASE_PROFILE: ${!_pkey}"
        fi
    done
    unset _v _pkey
fi

[ -n "$ARG_EXTEND_SIZE" ] && EXTEND_SIZE_MB="$ARG_EXTEND_SIZE"
[ -n "$ARG_IMAGE_URL" ] && IMAGE_URL_CFG="$ARG_IMAGE_URL"
VERSION="${VERSION:-$DEFAULT_VERSION}"
PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"

# Resolve deps/hook-list paths relative to the board dir; "none" stays literal.
resolve_board_file() {
    local f="$1"
    [ -z "$f" ] || [ "$f" = "none" ] && { printf '%s' "$f"; return; }
    [[ "$f" == /* ]] && { printf '%s' "$f"; return; }
    printf '%s' "$BOARD_DIR/$f"
}
RUNTIME_DEPS="$(resolve_board_file "$RUNTIME_DEPS")"
BUILD_DEPS="$(resolve_board_file "$BUILD_DEPS")"
HOOK_LIST="$(resolve_board_file "$HOOK_LIST")"
[ -n "$KERNEL_CONFIG" ] && [[ "$KERNEL_CONFIG" != /* ]] && KERNEL_CONFIG="$SCRIPT_DIR/$KERNEL_CONFIG"

# Which deps drive the base stage and the apps-stage build-dep purge:
# with a profile, the profile's lists (a superset of the board's) so the purge
# removes everything the shared base installed; without, the board's own.
if [ -n "$BASE_PROFILE" ]; then
    BASE_STAGE_RUNTIME="$BASE_RUNTIME_DEPS"
    BASE_STAGE_BUILDDEPS="$BASE_BUILD_DEPS"
    APPS_BUILD_DEPS="$BASE_BUILD_DEPS"
else
    BASE_STAGE_RUNTIME="$RUNTIME_DEPS"
    BASE_STAGE_BUILDDEPS="$BUILD_DEPS"
    APPS_BUILD_DEPS="$BUILD_DEPS"
fi

# ------------------------------------------------------------------------------
# User / workspace resolution
# ------------------------------------------------------------------------------
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
REAL_GROUP="$(id -gn "$REAL_USER")"
WORKSPACE="${WORKSPACE:-$REAL_HOME/pi-image-workspace}"
[[ "$WORKSPACE" != /* ]] && WORKSPACE="$(pwd)/$WORKSPACE"

BUILD_ID="$BOARD${VARIANT:+-$VARIANT}"
DL_DIR="$WORKSPACE/downloads"
SRC_DIR="${ARG_SOURCES_DIR:-$WORKSPACE/sources}"
[[ "$SRC_DIR" != /* ]] && SRC_DIR="$(pwd)/$SRC_DIR"
KBUILD_DIR="$WORKSPACE/kernel-build"
# Profile bases are shared across boards; per-board bases stay separate.
if [ -n "$BASE_PROFILE" ]; then
    BASE_DIR="$WORKSPACE/base/profile-$BASE_PROFILE"
else
    BASE_DIR="$WORKSPACE/base/$BUILD_ID"
fi
KERNEL_DIR="$WORKSPACE/kernel/$BUILD_ID"
OUT_DIR="${ARG_OUTPUT_DIR:-$WORKSPACE/out/$BUILD_ID}"
[[ "$OUT_DIR" != /* ]] && OUT_DIR="$(pwd)/$OUT_DIR"
TMP_DIR="$WORKSPACE/tmp"

export REPOBINS="${ARG_REPOBINS:-$SRC_DIR}"
[[ "$REPOBINS" != /* ]] && REPOBINS="$(pwd)/$REPOBINS"

as_user() { if [ "$(id -u)" -eq 0 ] && [ "$REAL_USER" != "root" ]; then sudo -u "$REAL_USER" -H "$@"; else "$@"; fi; }
own_by_user() { [ "$(id -u)" -eq 0 ] && chown -R "$REAL_USER:$REAL_GROUP" "$@" 2>/dev/null || true; }

# ------------------------------------------------------------------------------
# Vanilla image resolution
# ------------------------------------------------------------------------------
if [ -n "$ARG_START_FROM" ]; then
    # Prepared image supplied directly: base/kernel stages and the vanilla
    # image are not needed at all.
    [[ "$ARG_START_FROM" != /* ]] && ARG_START_FROM="$(pwd)/$ARG_START_FROM"
    VANILLA_XZ=""
    VANILLA_NAME="$(basename "$ARG_START_FROM")"
elif [ -n "$ARG_BASEIMAGE" ]; then
    [[ "$ARG_BASEIMAGE" != /* ]] && ARG_BASEIMAGE="$(pwd)/$ARG_BASEIMAGE"
    VANILLA_XZ="$ARG_BASEIMAGE"
    VANILLA_NAME="$(basename "$VANILLA_XZ")"; VANILLA_NAME="${VANILLA_NAME%.xz}"
else
    [ -z "$IMAGE_URL_CFG" ] && die "Board config has no IMAGE_URL and no --baseimage given"
    VANILLA_XZ="$DL_DIR/$(basename "$IMAGE_URL_CFG")"
    VANILLA_NAME="$(basename "$VANILLA_XZ")"; VANILLA_NAME="${VANILLA_NAME%.xz}"
fi
VANILLA_STEM="${VANILLA_NAME%.img}"

BASE_IMG="$BASE_DIR/$VANILLA_STEM-${BASE_PROFILE:-$BUILD_ID}-base.img"
KERNEL_IMG="$KERNEL_DIR/$VANILLA_STEM-$BUILD_ID-base-kernel.img"
if [ -n "$ARG_START_FROM" ]; then
    # start-from image names usually carry the board already
    FINAL_IMG="$OUT_DIR/$VANILLA_STEM-$VERSION.img"
else
    FINAL_IMG="$OUT_DIR/$VANILLA_STEM-$BUILD_ID-$VERSION.img"
fi

# ------------------------------------------------------------------------------
# Hook-list parsing (for preflight + stamps)
# ------------------------------------------------------------------------------
expand_line_vars() {
    local line="$1" varname
    while [[ "$line" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
        varname="${BASH_REMATCH[1]}"
        [ -z "${!varname+x}" ] && die "Undefined variable \${$varname} in hook list line: $1"
        line="${line//\$\{${varname}\}/${!varname}}"
    done
    printf '%s\n' "$line"
}

# Parses a hook list file into the HOOK_* arrays. Defaults to the board's
# apps-stage list ($HOOK_LIST); pass a file argument for other lists (profile
# base hooks).
HOOK_SCRIPTS=() HOOK_LOCAL_DIRS=() HOOK_GIT_REPOS=()
parse_hook_list() {
    local list="${1:-$HOOK_LIST}"
    HOOK_SCRIPTS=() HOOK_LOCAL_DIRS=() HOOK_GIT_REPOS=()
    [ -z "$list" ] || [ "$list" = "none" ] && return 0
    [ -f "$list" ] || die "Hook list not found: $list"
    local line hook_script git_repo git_tag rest hooks_dir
    hooks_dir="$(dirname "$list")"
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        line="$(expand_line_vars "$line")"
        IFS='|' read -r hook_script git_repo git_tag rest <<< "$line"
        [[ "$hook_script" != /* ]] && hook_script="$hooks_dir/$hook_script"
        HOOK_SCRIPTS+=("$hook_script")
        if [ -n "$git_repo" ]; then
            if [[ "$git_repo" == file://* ]]; then
                HOOK_LOCAL_DIRS+=("${git_repo#file://}")
            else
                HOOK_GIT_REPOS+=("$git_repo${git_tag:+|$git_tag}")
            fi
        fi
    done < "$list"
}

# Is DIR one that the sources stage will create? (matches a SOURCES entry name)
dir_is_declared_source() {
    local d="$1" name url branch
    while IFS='|' read -r name url branch; do
        [ -z "${name// }" ] && continue
        [[ "$name" =~ ^[[:space:]]*# ]] && continue
        [ "$d" = "$SRC_DIR/$name" ] || [ "$d" = "$REPOBINS/$name" ] && return 0
    done <<< "$SOURCES"
    return 1
}

# ------------------------------------------------------------------------------
# Stamps: a stage re-runs when the hash of its inputs changes
# ------------------------------------------------------------------------------
dir_rev() {
    local d="$1"
    if git -C "$d" rev-parse HEAD >/dev/null 2>&1; then
        echo "$(git -C "$d" rev-parse HEAD)-$(git -C "$d" status --porcelain 2>/dev/null | sha256sum | cut -d' ' -f1)"
    else
        find "$d" -type f -printf '%P %s %T@\n' 2>/dev/null | sort | sha256sum | cut -d' ' -f1
    fi
}

# Reads one input token per line on stdin ("file:<path>", "dir:<path>" or a
# literal string) and prints a single combined sha256.
hash_lines() {
    local t
    while IFS= read -r t; do
        case "$t" in
            file:*) sha256sum "${t#file:}" 2>/dev/null | cut -d' ' -f1 || echo "missing:${t#file:}" ;;
            dir:*)  if [ -d "${t#dir:}" ]; then dir_rev "${t#dir:}"; else echo "missing:${t#dir:}"; fi ;;
            *)      printf '%s\n' "$t" ;;
        esac
    done | sha256sum | cut -d' ' -f1
}
base_hash()   { base_stamp_inputs   | hash_lines; }
kernel_hash() { kernel_stamp_inputs | hash_lines; }
apps_hash()   { apps_stamp_inputs   | hash_lines; }

base_stamp_inputs() {
    local in=("base-v2" "profile:$BASE_PROFILE" "$VANILLA_NAME" "extend:$EXTEND_SIZE_MB" "pw:$PASSWORD")
    [ "$BASE_STAGE_RUNTIME" != "none" ] && [ -n "$BASE_STAGE_RUNTIME" ] && in+=("file:$BASE_STAGE_RUNTIME")
    [ "$BASE_STAGE_BUILDDEPS" != "none" ] && [ -n "$BASE_STAGE_BUILDDEPS" ] && in+=("file:$BASE_STAGE_BUILDDEPS")
    if [ -n "$BASE_HOOK_LIST" ]; then
        parse_hook_list "$BASE_HOOK_LIST"
        in+=("file:$BASE_HOOK_LIST")
        local h d entry url ref
        for h in "${HOOK_SCRIPTS[@]}"; do in+=("file:$h"); done
        for d in "${HOOK_LOCAL_DIRS[@]}"; do in+=("dir:$d"); done
        for entry in "${HOOK_GIT_REPOS[@]}"; do
            url="${entry%%|*}"; ref="${entry#*|}"; [ "$ref" = "$entry" ] && ref="HEAD"
            in+=("git:$url@$(git_remote_rev "$url" "$ref")")
        done
    fi
    printf '%s\n' "${in[@]}"
}

kernel_stamp_inputs() {
    local in=("kernel-v1" "branch:$KERNEL_BRANCH" "base:$(cat "$BASE_DIR/.stamp" 2>/dev/null || echo none)")
    [ -n "$KERNEL_CONFIG" ] && [ "$KERNEL_CONFIG" != "defconfig" ] && in+=("file:$KERNEL_CONFIG")
    [ -n "$DRIVERS_DIR" ] && in+=("dir:$SRC_DIR/$DRIVERS_DIR")
    printf '%s\n' "${in[@]}"
}

# Resolve the current commit of a remote ref (branch or tag); for pinned
# commit ids or unreachable remotes, fall back to the literal ref so the
# stamp stays stable instead of erroring.
git_remote_rev() {
    local url="$1" ref="${2:-HEAD}" out=""
    if [ $OFFLINE -eq 0 ]; then
        out=$(git_probe ls-remote "$url" "$ref" "refs/heads/$ref" "refs/tags/$ref" 2>/dev/null | head -1 | cut -f1)
    fi
    [ -n "$out" ] && printf '%s\n' "$out" || printf '%s\n' "$ref"
}

apps_stamp_inputs() {
    parse_hook_list "$HOOK_LIST"
    local in=("apps-v1" "version:$VERSION" "input:$APPS_INPUT_STAMP" "apps-extend:$APPS_EXTEND_SIZE_MB")
    [ "$HOOK_LIST" != "none" ] && [ -n "$HOOK_LIST" ] && in+=("file:$HOOK_LIST")
    local h d entry url ref
    for h in "${HOOK_SCRIPTS[@]}"; do in+=("file:$h"); done
    for d in "${HOOK_LOCAL_DIRS[@]}"; do in+=("dir:$d"); done
    # Git-source hooks clone inside the chroot at build time; track their
    # remote revision so a moved branch re-triggers the apps stage.
    for entry in "${HOOK_GIT_REPOS[@]}"; do
        url="${entry%%|*}"; ref="${entry#*|}"; [ "$ref" = "$entry" ] && ref="HEAD"
        in+=("git:$url@$(git_remote_rev "$url" "$ref")")
    done
    [ "$RUNTIME_DEPS" != "none" ] && in+=("file:$RUNTIME_DEPS")
    [ "$BUILD_DEPS" != "none" ] && in+=("file:$BUILD_DEPS")
    printf '%s\n' "${in[@]}"
}

stamp_matches() { # $1=stamp-file $2=hash -> 0 if unchanged
    [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]
}

# Will the base stage actually run? The vanilla image is only consumed by the
# base stage, so its download is skipped whenever this returns false.
base_will_run() {
    [ -n "$ARG_START_FROM" ] && return 1
    [ $SKIP_BASE -eq 1 ] && return 1
    [ $FORCE_BASE -eq 1 ] && return 0
    stamp_matches "$BASE_DIR/.stamp" "$(base_hash)" && [ -f "$BASE_IMG" ] && return 1
    return 0
}

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------
PREFLIGHT_ERRORS=0
pf_fail() { echo -e "  ${RED}✗${NC} $*"; PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1)); }
pf_ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
pf_warn() { echo -e "  ${YELLOW}!${NC} $*"; }

preflight() {
    stage_banner "Preflight: $BOARD${VARIANT:+ (variant: $VARIANT)}"

    # Host tools
    local tool
    for tool in sdm unxz losetup git wget sha256sum; do
        command -v "$tool" >/dev/null 2>&1 && pf_ok "$tool" || pf_fail "$tool not found"
    done
    command -v qemu-aarch64-static >/dev/null 2>&1 && pf_ok "qemu-aarch64-static" \
        || pf_fail "qemu-aarch64-static not found (pacman -S qemu-user-static qemu-user-static-binfmt)"
    [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] && pf_ok "arm64 binfmt registered" \
        || pf_fail "arm64 binfmt not registered (systemctl restart systemd-binfmt.service)"
    if [ "$KERNEL" = "1" ] && [ $SKIP_KERNEL -eq 0 ] && [ -z "$ARG_START_FROM" ]; then
        for tool in aarch64-linux-gnu-gcc dtc bc bison flex; do
            command -v "$tool" >/dev/null 2>&1 && pf_ok "$tool" \
                || pf_fail "$tool not found (run custom-pi-kernel-builder/scripts/01-setup-arch-deps.sh)"
        done
    fi

    # Board files
    [ "$RUNTIME_DEPS" = "none" ] || { [ -f "$RUNTIME_DEPS" ] && pf_ok "runtime deps: $RUNTIME_DEPS" || pf_fail "runtime deps missing: $RUNTIME_DEPS"; }
    if [ -z "$BASE_PROFILE" ]; then
        [ "$BUILD_DEPS" = "none" ] || { [ -f "$BUILD_DEPS" ] && pf_ok "build deps: $BUILD_DEPS" || pf_fail "build deps missing: $BUILD_DEPS"; }
    fi

    # Base profile files and hooks
    if [ -n "$BASE_PROFILE" ]; then
        pf_ok "base profile: $BASE_PROFILE ($PROFILE_DIR)"
        [ "$BASE_STAGE_RUNTIME" = "none" ] || { [ -f "$BASE_STAGE_RUNTIME" ] && pf_ok "profile runtime deps" || pf_fail "profile runtime deps missing: $BASE_STAGE_RUNTIME"; }
        [ "$BASE_STAGE_BUILDDEPS" = "none" ] || { [ -f "$BASE_STAGE_BUILDDEPS" ] && pf_ok "profile build deps" || pf_fail "profile build deps missing: $BASE_STAGE_BUILDDEPS"; }
        if [ -n "$BASE_HOOK_LIST" ]; then
            parse_hook_list "$BASE_HOOK_LIST"
            local bh bd bentry burl bhd
            for bh in "${HOOK_SCRIPTS[@]}"; do
                bhd="$(realpath -m "$bh")"
                [ -f "$bh" ] && pf_ok "profile hook: ${bhd#"$SCRIPT_DIR"/}" || pf_fail "profile hook missing: $bh"
            done
            for bd in "${HOOK_LOCAL_DIRS[@]}"; do
                if [ -d "$bd" ]; then pf_ok "profile local source: $bd"
                elif [ $OFFLINE -eq 0 ] && dir_is_declared_source "$bd"; then pf_warn "profile local source will be cloned: $bd"
                else pf_fail "profile local source missing: $bd"; fi
            done
            if [ $DRY_RUN -eq 1 ] && [ $OFFLINE -eq 0 ]; then
                for bentry in "${HOOK_GIT_REPOS[@]}"; do
                    burl="${bentry%%|*}"
                    git_probe ls-remote --exit-code "$burl" HEAD >/dev/null 2>&1 && pf_ok "git reachable: $burl" || pf_fail "git unreachable: $burl (private repo? set up gh auth or GIT_USERNAME/GIT_TOKEN)"
                done
            fi
        fi
    fi
    if [ "$KERNEL" = "1" ]; then
        [ -n "$KERNEL_CONFIG" ] && [ "$KERNEL_CONFIG" != "defconfig" ] && { [ -f "$KERNEL_CONFIG" ] && pf_ok "kernel config: $(basename "$KERNEL_CONFIG")" || pf_fail "kernel config missing: $KERNEL_CONFIG"; }
    fi

    # Vanilla image
    if [ -n "$ARG_START_FROM" ]; then
        : # not needed, checked below
    elif [ -n "$ARG_BASEIMAGE" ]; then
        [ -f "$VANILLA_XZ" ] && pf_ok "vanilla image (local): $VANILLA_XZ" || pf_fail "vanilla image not found: $VANILLA_XZ"
    elif [ -f "$VANILLA_XZ" ]; then
        pf_ok "vanilla image cached: $VANILLA_XZ"
    elif ! base_will_run; then
        pf_ok "vanilla image not needed (base stage cached/skipped)"
    elif [ $OFFLINE -eq 1 ]; then
        pf_fail "vanilla image not cached and --offline set: $VANILLA_XZ"
    else
        pf_warn "vanilla image will be downloaded: $IMAGE_URL_CFG"
    fi

    # Start-from image
    if [ -n "$ARG_START_FROM" ]; then
        [ -f "$ARG_START_FROM" ] && pf_ok "start-from image: $ARG_START_FROM" || pf_fail "start-from image not found: $ARG_START_FROM"
    fi

    # Hook list: scripts + local sources + git reachability
    parse_hook_list
    local h d entry url hd
    for h in "${HOOK_SCRIPTS[@]}"; do
        hd="$(realpath -m "$h")"
        [ -f "$h" ] && pf_ok "hook: ${hd#"$SCRIPT_DIR"/}" || pf_fail "hook script missing: $h"
    done
    for d in "${HOOK_LOCAL_DIRS[@]}"; do
        if [ -d "$d" ]; then
            pf_ok "local source: $d"
        elif [ $OFFLINE -eq 0 ] && dir_is_declared_source "$d"; then
            pf_warn "local source will be cloned by sources stage: $d"
        else
            pf_fail "local source missing (not in SOURCES): $d"
        fi
    done
    if [ $DRY_RUN -eq 1 ] && [ $OFFLINE -eq 0 ]; then
        for entry in "${HOOK_GIT_REPOS[@]}"; do
            url="${entry%%|*}"
            git_probe ls-remote --exit-code "$url" HEAD >/dev/null 2>&1 && pf_ok "git reachable: $url" || pf_fail "git unreachable: $url (private repo? set up gh auth or GIT_USERNAME/GIT_TOKEN)"
        done
    fi

    # sp6bins specific: the compat cmake option must exist in the checkout
    # (cmake silently ignores unknown -D options, which would produce an image
    # with missing /home/pi/micropanel/fpga files).
    for d in "${HOOK_LOCAL_DIRS[@]}"; do
        [[ "$d" == */sp6bins ]] || continue
        [ -d "$d" ] || continue
        if grep -q "SP6BINS_MICROPANEL_COMPAT" "$HOOK_LIST" && ! grep -q "SP6BINS_MICROPANEL_COMPAT" "$d/CMakeLists.txt" 2>/dev/null; then
            pf_fail "sp6bins checkout at $d lacks the SP6BINS_MICROPANEL_COMPAT cmake option (update/merge the sp6bins branch that provides it, or use --repobins with an updated checkout)"
        fi
    done

    # git-lfs repos (e.g. media-files) need the lfs filters, otherwise a clone
    # silently yields tiny pointer files instead of the real assets.
    if grep -q "media-files" "$HOOK_LIST" 2>/dev/null; then
        command -v git-lfs >/dev/null 2>&1 && pf_ok "git-lfs" || pf_fail "git-lfs not found (pacman -S git-lfs; then run: git lfs install)"
    fi

    # Disk space (workspace parent + host root for sdm/nspawn)
    local avail_root avail_ws ws_probe="$WORKSPACE"
    while [ ! -d "$ws_probe" ]; do ws_probe="$(dirname "$ws_probe")"; done
    avail_root=$(df -BM --output=avail / | tail -1 | tr -d ' M')
    avail_ws=$(df -BM --output=avail "$ws_probe" | tail -1 | tr -d ' M')
    [ "$avail_root" -ge 2048 ] && pf_ok "host / free: ${avail_root}MB" || pf_fail "host / has only ${avail_root}MB free (sdm needs >=2GB)"
    [ "$avail_ws" -ge 15000 ] && pf_ok "workspace free: ${avail_ws}MB" || pf_warn "workspace has only ${avail_ws}MB free (a full build can need ~15GB)"

    [ $PREFLIGHT_ERRORS -gt 0 ] && die "Preflight failed with $PREFLIGHT_ERRORS error(s)"
    log "Preflight OK"
}

# ------------------------------------------------------------------------------
# Stage: sources
# ------------------------------------------------------------------------------
# One-shot GitHub credentials for private source repos on machines without a
# stored credential helper: GIT_USERNAME + GIT_TOKEN (a PAT, not the account
# password) are written to a 0600 credential-store file used only for the
# sources stage, and removed afterwards. Example:
#   sudo GIT_USERNAME=you GIT_TOKEN=ghp_xxx ./build-image.sh --board=...
GIT_CRED_FILE="" GIT_CRED_ARGS=()
setup_git_credentials() {
    [ -n "$GIT_CRED_FILE" ] && return 0   # already set up
    [ -n "${GIT_USERNAME:-}" ] && [ -n "${GIT_TOKEN:-}" ] || return 0
    GIT_CRED_FILE="$(mktemp -t build-image-gitcred.XXXXXX)"
    printf 'https://%s:%s@github.com\n' "$GIT_USERNAME" "$GIT_TOKEN" > "$GIT_CRED_FILE"
    chmod 600 "$GIT_CRED_FILE"; own_by_user "$GIT_CRED_FILE"
    GIT_CRED_ARGS=(-c "credential.helper=store --file=$GIT_CRED_FILE")
    trap 'rm -f "$GIT_CRED_FILE"' EXIT
    info "Using one-shot git credentials for user '$GIT_USERNAME'"
}

# All remote git probes (reachability checks, remote-revision stamping) and
# source clones run as the INVOKING user - that's whose credential helper
# (gh auth setup-git) is configured, even when the build runs under sudo.
# GIT_TERMINAL_PROMPT=0 makes a missing credential a clean failure instead of
# an interactive hang.
git_probe() {
    as_user env GIT_TERMINAL_PROMPT=0 git "${GIT_CRED_ARGS[@]}" "$@"
}

fetch_sources() {
    [ -z "${SOURCES// /}" ] && return 0
    stage_banner "Stage 0: Sources"
    mkdir -p "$SRC_DIR"; own_by_user "$SRC_DIR"
    setup_git_credentials
    local name url branch dest drivers_root="${DRIVERS_DIR%%/*}"
    while IFS='|' read -r name url branch; do
        [ -z "${name// }" ] && continue
        [[ "$name" =~ ^[[:space:]]*# ]] && continue
        dest="$SRC_DIR/$name"
        # A source already provided via --repobins needs no workspace clone,
        # except the drivers repo, which the kernel stage reads from sources/.
        if [ "$REPOBINS" != "$SRC_DIR" ] && [ -d "$REPOBINS/$name" ] && [ "$name" != "$drivers_root" ]; then
            info "Source '$name' provided by --repobins ($REPOBINS/$name), skipping clone"
            continue
        fi
        if [ ! -d "$dest" ]; then
            [ $OFFLINE -eq 1 ] && die "Source '$name' missing and --offline set: $dest"
            log "Cloning $name (${branch:-default})..."
            as_user git "${GIT_CRED_ARGS[@]}" clone ${branch:+-b "$branch"} "$url" "$dest"
        elif [ $OFFLINE -eq 0 ]; then
            log "Updating $name..."
            as_user git "${GIT_CRED_ARGS[@]}" -C "$dest" fetch --quiet 2>/dev/null || warn "fetch failed for $name (continuing with local copy)"
            if [ -n "$branch" ]; then
                as_user git -C "$dest" checkout --quiet "$branch" 2>/dev/null || warn "cannot checkout $branch in $name"
            fi
            as_user git "${GIT_CRED_ARGS[@]}" -C "$dest" pull --ff-only --quiet 2>/dev/null || true
        fi
    done <<< "$SOURCES"
}

# ------------------------------------------------------------------------------
# Stage: download vanilla image
# ------------------------------------------------------------------------------
download_vanilla() {
    [ -n "$ARG_START_FROM" ] && return 0
    [ -n "$ARG_BASEIMAGE" ] && return 0
    if ! base_will_run && [ ! -f "$VANILLA_XZ" ]; then
        info "Base stage is cached/skipped - vanilla image download not needed"
        return 0
    fi
    mkdir -p "$DL_DIR"; own_by_user "$DL_DIR"
    if [ ! -f "$VANILLA_XZ" ]; then
        [ $OFFLINE -eq 1 ] && die "Vanilla image not cached and --offline set"
        stage_banner "Downloading vanilla image"
        as_user wget -O "$VANILLA_XZ.part" "$IMAGE_URL_CFG"
        as_user mv "$VANILLA_XZ.part" "$VANILLA_XZ"
    fi
    if [ -n "$IMAGE_SHA256" ]; then
        log "Verifying image checksum..."
        echo "$IMAGE_SHA256  $VANILLA_XZ" | sha256sum -c - >/dev/null || die "Checksum mismatch: $VANILLA_XZ"
    fi
}

# ------------------------------------------------------------------------------
# Stage: base
# ------------------------------------------------------------------------------
run_stage_base() {
    local hash; hash=$(base_hash)
    if [ $SKIP_BASE -eq 1 ]; then
        [ -f "$BASE_IMG" ] || die "--skip-base but no base image at $BASE_IMG"
        warn "Stage base: SKIPPED (--skip-base)"; return 0
    fi
    if [ $FORCE_BASE -eq 0 ] && stamp_matches "$BASE_DIR/.stamp" "$hash" && [ -f "$BASE_IMG" ]; then
        log "Stage base: up-to-date (stamp match) -> $BASE_IMG"; return 0
    fi
    stage_banner "Stage 1: Base OS image${BASE_PROFILE:+ (profile: $BASE_PROFILE)}"
    local work="$TMP_DIR/base"; rm -rf "$work"; mkdir -p "$work"
    "$IMAGER" \
        --mode=base \
        --baseimage="$VANILLA_XZ" \
        --output="$work" \
        ${PASSWORD:+--password="$PASSWORD"} \
        --extend-size-mb="$EXTEND_SIZE_MB" \
        ${BASE_STAGE_RUNTIME:+$([ "$BASE_STAGE_RUNTIME" != "none" ] && echo "--runtime-package=$BASE_STAGE_RUNTIME")} \
        --builddep-package="$([ "$BASE_STAGE_BUILDDEPS" != "none" ] && [ -n "$BASE_STAGE_BUILDDEPS" ] && echo "$BASE_STAGE_BUILDDEPS" || echo none)" \
        $([ -n "$BASE_HOOK_LIST" ] && echo "--setup-hook-list=$BASE_HOOK_LIST") \
        --version="$VERSION"
    mkdir -p "$BASE_DIR"
    mv "$work/$VANILLA_NAME" "$BASE_IMG"
    rm -rf "$work"
    echo "$hash" > "$BASE_DIR/.stamp"
    own_by_user "$BASE_DIR"
    log "Base image ready: $BASE_IMG"
}

# ------------------------------------------------------------------------------
# Stage: kernel
# ------------------------------------------------------------------------------
run_stage_kernel() {
    [ "$KERNEL" != "1" ] && { info "Stage kernel: not enabled for this board"; return 0; }
    if [ $SKIP_KERNEL -eq 1 ]; then
        warn "Stage kernel: SKIPPED (--skip-kernel)"; return 0
    fi
    local hash; hash=$(kernel_hash)
    if [ $FORCE_KERNEL -eq 0 ] && stamp_matches "$KERNEL_DIR/.stamp" "$hash" && [ -f "$KERNEL_IMG" ]; then
        log "Stage kernel: up-to-date (stamp match) -> $KERNEL_IMG"; return 0
    fi
    stage_banner "Stage 2: Kernel + drivers"
    [ -f "$BASE_IMG" ] || die "Base image missing: $BASE_IMG"
    mkdir -p "$KERNEL_DIR" "$KBUILD_DIR"; own_by_user "$KBUILD_DIR"
    log "Copying base image (kernel stage works on its own copy)..."
    cp --sparse=auto "$BASE_IMG" "$KERNEL_IMG.tmp"
    "$KERNEL_BUILDER" \
        --branch "$KERNEL_BRANCH" \
        ${KERNEL_CONFIG:+--config "$KERNEL_CONFIG"} \
        ${DRIVERS_DIR:+--drivers "$SRC_DIR/$DRIVERS_DIR"} \
        --image "$KERNEL_IMG.tmp" \
        --build-dir "$KBUILD_DIR" \
        --backup
    mv "$KERNEL_IMG.tmp" "$KERNEL_IMG"
    echo "$hash" > "$KERNEL_DIR/.stamp"
    own_by_user "$KERNEL_DIR"
    log "Kernel image ready: $KERNEL_IMG"
}

# ------------------------------------------------------------------------------
# Stage: apps
# ------------------------------------------------------------------------------
resolve_apps_input() {
    if [ -n "$ARG_START_FROM" ]; then
        APPS_INPUT="$ARG_START_FROM"
        APPS_INPUT_STAMP="start-from:$(sha256sum "$ARG_START_FROM" 2>/dev/null | cut -d' ' -f1 || echo missing)"
    elif [ "$KERNEL" = "1" ] && [ -f "$KERNEL_IMG" ] && [ $SKIP_KERNEL -eq 0 ]; then
        APPS_INPUT="$KERNEL_IMG"
        APPS_INPUT_STAMP="kernel:$(cat "$KERNEL_DIR/.stamp" 2>/dev/null || echo none)"
    elif [ "$KERNEL" = "1" ] && [ -f "$KERNEL_IMG" ]; then
        APPS_INPUT="$KERNEL_IMG"
        APPS_INPUT_STAMP="kernel:$(cat "$KERNEL_DIR/.stamp" 2>/dev/null || echo none)"
    else
        APPS_INPUT="$BASE_IMG"
        APPS_INPUT_STAMP="base:$(cat "$BASE_DIR/.stamp" 2>/dev/null || echo none)"
    fi
}

run_stage_apps() {
    resolve_apps_input
    if [ $SKIP_APPS -eq 1 ]; then
        warn "Stage apps: SKIPPED (--skip-apps)"; return 0
    fi
    parse_hook_list
    local hash; hash=$(apps_hash)
    if [ $FORCE_APPS -eq 0 ] && stamp_matches "$OUT_DIR/.stamp" "$hash" && [ -f "$FINAL_IMG" ]; then
        log "Stage apps: up-to-date (stamp match) -> $FINAL_IMG"; return 0
    fi
    stage_banner "Stage 3: Apps & services"
    [ -f "$APPS_INPUT" ] || die "Input image for apps stage missing: $APPS_INPUT"
    local work="$TMP_DIR/apps"; rm -rf "$work"; mkdir -p "$work"
    local extra=()
    [ $KEEP_BUILD_DEPS -eq 1 ] && extra+=(--keep-build-deps)
    [ $DEBUG -eq 1 ] && extra+=(--debug)
    "$IMAGER" \
        --mode=incremental \
        --baseimage="$APPS_INPUT" \
        --output="$work" \
        --extend-size-mb="$APPS_EXTEND_SIZE_MB" \
        --builddep-package="$([ "$APPS_BUILD_DEPS" != "none" ] && [ -n "$APPS_BUILD_DEPS" ] && echo "$APPS_BUILD_DEPS" || echo none)" \
        ${RUNTIME_DEPS:+$([ "$RUNTIME_DEPS" != "none" ] && echo "--runtime-package=$RUNTIME_DEPS")} \
        $([ "$HOOK_LIST" != "none" ] && [ -n "$HOOK_LIST" ] && echo "--setup-hook-list=$HOOK_LIST") \
        --version="$VERSION" \
        "${extra[@]}"
    mkdir -p "$OUT_DIR"
    mv "$work/$(basename "$APPS_INPUT")" "$FINAL_IMG"
    rm -rf "$work"
    echo "$hash" > "$OUT_DIR/.stamp"
    own_by_user "$OUT_DIR"
    log "Final image ready: $FINAL_IMG"
}

# ------------------------------------------------------------------------------
# Flash
# ------------------------------------------------------------------------------
flash_image() {
    [ -z "$ARG_FLASH" ] && return 0
    [ -f "$FINAL_IMG" ] || die "No final image to flash: $FINAL_IMG"
    [ -b "$ARG_FLASH" ] || die "Not a block device: $ARG_FLASH"
    stage_banner "Flashing $FINAL_IMG -> $ARG_FLASH"
    lsblk -o NAME,SIZE,MODEL,MOUNTPOINTS "$ARG_FLASH"
    echo ""
    read -r -p "ALL DATA on $ARG_FLASH will be destroyed. Type 'yes' to continue: " reply
    [ "$reply" = "yes" ] || die "Flash aborted"
    dd if="$FINAL_IMG" of="$ARG_FLASH" bs=8M status=progress conv=fsync
    sync
    log "Flash complete. You can remove the SD card."
}

# ------------------------------------------------------------------------------
# Dry-run plan
# ------------------------------------------------------------------------------
plan_stage() { # $1=name $2=skip-flag $3=force-flag $4=stamp-file $5=hash $6=output
    local state
    if [ "$2" -eq 1 ]; then state="SKIP (flag)"
    elif [ "$3" -eq 1 ]; then state="RUN  (forced)"
    elif stamp_matches "$4" "$5" && [ -f "$6" ]; then state="SKIP (up-to-date)"
    else state="RUN"
    fi
    printf "  %-8s %-18s -> %s\n" "$1" "$state" "$6"
}

show_plan() {
    stage_banner "Build plan (dry run)"
    echo "  board:     $BOARD${VARIANT:+ ($VARIANT)}"
    echo "  version:   $VERSION"
    echo "  workspace: $WORKSPACE"
    echo "  vanilla:   $VANILLA_XZ"
    echo "  repobins:  $REPOBINS"
    echo ""
    parse_hook_list
    if [ -n "$ARG_START_FROM" ]; then
        printf "  %-8s %-18s\n" "base" "SKIP (start-from)"
        printf "  %-8s %-18s\n" "kernel" "SKIP (start-from)"
    else
        plan_stage "base" "$SKIP_BASE" "$FORCE_BASE" "$BASE_DIR/.stamp" "$(base_hash)" "$BASE_IMG"
        if [ "$KERNEL" = "1" ]; then
            plan_stage "kernel" "$SKIP_KERNEL" "$FORCE_KERNEL" "$KERNEL_DIR/.stamp" "$(kernel_hash)" "$KERNEL_IMG"
        else
            printf "  %-8s %-18s\n" "kernel" "N/A (KERNEL=0)"
        fi
    fi
    resolve_apps_input
    plan_stage "apps" "$SKIP_APPS" "$FORCE_APPS" "$OUT_DIR/.stamp" "$(apps_hash)" "$FINAL_IMG"
    echo ""
    info "Dry run complete - nothing was changed"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
    log "misc-tools unified image builder"
    info "board=$BOARD${VARIANT:+ variant=$VARIANT} version=$VERSION workspace=$WORKSPACE"

    setup_git_credentials   # one-shot GIT_USERNAME/GIT_TOKEN, if provided
    preflight
    if [ $DRY_RUN -eq 1 ]; then
        show_plan
        exit 0
    fi

    [ "$(id -u)" -eq 0 ] || die "Run as root: sudo $0 --board=$BOARD ... (--dry-run works without root)"

    mkdir -p "$WORKSPACE" "$TMP_DIR"
    own_by_user "$WORKSPACE"

    fetch_sources
    download_vanilla

    if [ -n "$ARG_START_FROM" ]; then
        info "Using --start-from image, skipping base and kernel stages"
    else
        run_stage_base
        run_stage_kernel
    fi
    run_stage_apps

    stage_banner "Build complete"
    echo "  Final image: $FINAL_IMG"
    [ -f "$FINAL_IMG" ] && echo "  Size:        $(du -h "$FINAL_IMG" | cut -f1)"
    echo ""
    echo "  Write to SD card:"
    echo "    sudo dd if=$FINAL_IMG of=/dev/sdX bs=8M status=progress conv=fsync"
    echo "  or re-run with --flash=/dev/sdX"
    echo ""

    flash_image
}

main
