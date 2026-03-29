#!/bin/bash
set -e

# kodi-custom-addons-hook.sh
#
# Hook script for custom-pi-imager --setup-hook-list.
# Installs Kodi custom addons (video loop toggle) into the Pi image.
#
# Expected environment variables (set by custom-pi-imager.sh):
#   HOOK_GIT_REPO      - Git repo URL (https://github.com/hackboxguy/kodi-custom-addons.git)
#   HOOK_GIT_TAG       - Branch/tag to checkout
#   HOOK_INSTALL_DEST  - Installation destination (e.g. /home/pi/kodi-custom-addons)
#   HOOK_NAME          - Extracted project name
#   HOOK_DEP_LIST      - Comma-separated dependencies (optional)
#   HOOK_LOCAL_SOURCE   - Path to local source (for file:// repos)

INSTALL_DIR="${HOOK_INSTALL_DEST:-/home/pi/kodi-custom-addons}"
KODI_USER_HOME="/home/pi"
KODI_ADDONS_DIR="${KODI_USER_HOME}/.kodi/addons"
KODI_USERDATA_DIR="${KODI_USER_HOME}/.kodi/userdata"
SYSTEM_SKIN_DIR="/usr/share/kodi/addons/skin.estuary"
USER_SKIN_DIR="${KODI_ADDONS_DIR}/skin.estuary"

echo "======================================"
echo "  Kodi Custom Addons Hook"
echo "======================================"
echo ""

log_step() {
    printf "%-50s " "$1"
}

log_ok() {
    echo "[OK]"
}

#------------------------------------------------------------------------------
# Step 0: Install hook dependencies from HOOK_DEP_LIST
#------------------------------------------------------------------------------
if [ -n "$HOOK_DEP_LIST" ]; then
    log_step "[0/6] Installing dependencies (${HOOK_DEP_LIST})..."
    DEPS_SPACE_SEP=$(echo "$HOOK_DEP_LIST" | tr ',' ' ')
    apt-get install -y $DEPS_SPACE_SEP > /dev/null 2>&1
    log_ok
fi

#------------------------------------------------------------------------------
# Step 1: Get source
#------------------------------------------------------------------------------
log_step "[1/6] Getting source..."
if [ -n "$HOOK_LOCAL_SOURCE" ] && [ -d "$HOOK_LOCAL_SOURCE" ]; then
    SRC_DIR="$HOOK_LOCAL_SOURCE"
elif [ -n "$HOOK_GIT_REPO" ]; then
    cd /tmp
    git clone "$HOOK_GIT_REPO" kodi-custom-addons-src
    cd kodi-custom-addons-src
    if [ -n "$HOOK_GIT_TAG" ] && [ "$HOOK_GIT_TAG" != "local" ]; then
        git checkout "$HOOK_GIT_TAG"
    fi
    SRC_DIR="/tmp/kodi-custom-addons-src"
else
    echo "[FAIL] No source specified"
    exit 1
fi
log_ok

#------------------------------------------------------------------------------
# Step 2: Install addon to ~/.kodi/addons/
#------------------------------------------------------------------------------
log_step "[2/6] Installing video loop toggle addon..."

mkdir -p "${KODI_ADDONS_DIR}"
rm -rf "${KODI_ADDONS_DIR}/script.videoloop.toggle"
cp -r "${SRC_DIR}/addons/script.videoloop.toggle" "${KODI_ADDONS_DIR}/"

# Remove files that go elsewhere (icons for skin, VideoOSD.xml)
# Keep icons in addon dir too as a backup reference
chown -R 1000:1000 "${KODI_ADDONS_DIR}/script.videoloop.toggle"
log_ok

#------------------------------------------------------------------------------
# Step 3: Copy Estuary skin to user directory and patch it
#------------------------------------------------------------------------------
log_step "[3/6] Patching Kodi Estuary skin..."

if [ -d "${SYSTEM_SKIN_DIR}" ] && [ ! -d "${USER_SKIN_DIR}" ]; then
    cp -r "${SYSTEM_SKIN_DIR}" "${USER_SKIN_DIR}"
fi

if [ -d "${USER_SKIN_DIR}" ]; then
    # Copy loop icons to skin buttons directory
    mkdir -p "${USER_SKIN_DIR}/media/osd/fullscreen/buttons"
    cp "${SRC_DIR}/addons/script.videoloop.toggle/loop-off.png" \
       "${USER_SKIN_DIR}/media/osd/fullscreen/buttons/"
    cp "${SRC_DIR}/addons/script.videoloop.toggle/loop-on.png" \
       "${USER_SKIN_DIR}/media/osd/fullscreen/buttons/"

    # Install patched VideoOSD.xml
    cp "${SRC_DIR}/skin-patches/VideoOSD.xml" "${USER_SKIN_DIR}/xml/VideoOSD.xml"

    chown -R 1000:1000 "${USER_SKIN_DIR}"
    log_ok
else
    echo "[SKIP] Kodi skin not found"
fi

#------------------------------------------------------------------------------
# Step 4: Install keymap
#------------------------------------------------------------------------------
log_step "[4/6] Installing keymap (L key)..."

mkdir -p "${KODI_USERDATA_DIR}/keymaps"
cp "${SRC_DIR}/addons/script.videoloop.toggle/resources/keymaps/videoloop.xml" \
   "${KODI_USERDATA_DIR}/keymaps/"
chown -R 1000:1000 "${KODI_USERDATA_DIR}/keymaps"
log_ok

#------------------------------------------------------------------------------
# Step 5: Enable addon in Kodi database
#------------------------------------------------------------------------------
log_step "[5/6] Enabling addon in Kodi database..."

KODI_DB_DIR="${KODI_USERDATA_DIR}/Database"
mkdir -p "${KODI_DB_DIR}"

# If Addons33.db exists, update it; otherwise create a minimal one
ADDONS_DB="${KODI_DB_DIR}/Addons33.db"

if command -v sqlite3 >/dev/null 2>&1; then
    if [ ! -f "${ADDONS_DB}" ]; then
        # Create minimal addons database
        sqlite3 "${ADDONS_DB}" << 'SQL'
CREATE TABLE IF NOT EXISTS installed (
    id INTEGER PRIMARY KEY,
    addonID TEXT UNIQUE,
    enabled INTEGER DEFAULT 1,
    installDate TEXT DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS disabled (
    id INTEGER PRIMARY KEY,
    addonID TEXT UNIQUE
);
SQL
    fi

    # Enable our addon (insert or update)
    sqlite3 "${ADDONS_DB}" << 'SQL'
INSERT OR REPLACE INTO installed (addonID, enabled)
VALUES ('script.videoloop.toggle', 1);
DELETE FROM disabled WHERE addonID = 'script.videoloop.toggle';
SQL

    # Disable version check notifications
    sqlite3 "${ADDONS_DB}" << 'SQL'
INSERT OR REPLACE INTO installed (addonID, enabled)
VALUES ('service.xbmc.versioncheck', 0);
INSERT OR REPLACE INTO disabled (addonID)
VALUES ('service.xbmc.versioncheck');
SQL

    chown 1000:1000 "${ADDONS_DB}"
    log_ok
else
    echo "[SKIP] sqlite3 not available - addon will prompt on first run"
fi

#------------------------------------------------------------------------------
# Step 6: Copy source to install destination (for reference)
#------------------------------------------------------------------------------
log_step "[6/6] Copying source to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
cp -r "${SRC_DIR}/addons" "${INSTALL_DIR}/"
cp -r "${SRC_DIR}/skin-patches" "${INSTALL_DIR}/"
cp -r "${SRC_DIR}/packages" "${INSTALL_DIR}/"
chown -R 1000:1000 "${INSTALL_DIR}"
log_ok

#------------------------------------------------------------------------------
# Cleanup
#------------------------------------------------------------------------------
if [ -d "/tmp/kodi-custom-addons-src" ]; then
    rm -rf "/tmp/kodi-custom-addons-src"
fi

echo ""
echo "======================================"
echo "  Kodi Custom Addons Installed"
echo "======================================"
echo ""
echo "Installed addons:"
echo "  - script.videoloop.toggle (Video Loop Toggle)"
echo ""
echo "Usage:"
echo "  - OSD button: Tap screen during playback -> Loop button"
echo "  - Keyboard: Press 'L' during video playback"
echo "  - API: curl http://<host>:8080/jsonrpc -d '{\"method\":\"Addons.ExecuteAddon\",\"params\":{\"addonid\":\"script.videoloop.toggle\"}}'"
echo "  - API: curl http://<host>:8080/jsonrpc -d '{\"method\":\"Player.SetRepeat\",\"params\":{\"playerid\":1,\"repeat\":\"one\"}}'"
echo "======================================"
