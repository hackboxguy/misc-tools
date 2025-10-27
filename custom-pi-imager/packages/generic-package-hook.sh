#!/bin/bash
set -e

# Environment variables available:
# - MOUNT_POINT: Root filesystem mount point
# - PI_PASSWORD: User password (empty if unchanged)
# - IMAGE_WORK_DIR: Working directory path
# - HOOK_GIT_REPO: Git repository URL or file:// path for local sources
# - HOOK_GIT_TAG: Git tag/branch (ignored for local sources)
# - HOOK_INSTALL_DEST: Installation destination path
# - HOOK_NAME: Extracted from git repo name or local directory name
# - HOOK_DEP_LIST: Comma separated package list (e.g: libftdi1-dev,libhidapi-dev,zlib1g-dev)
# - HOOK_LOCAL_SOURCE: Path to local source in chroot (set only for file:// sources)


echo "======================================"
echo "  $HOOK_NAME Setup Hook"
echo "======================================"
echo ""

echo "Running inside chroot environment"
echo "Building $HOOK_NAME from source..."
echo ""

# Install build dependencies (no-op if already installed)
echo "[1/5] Installing build dependencies..."
apt-get update -qq

# Convert comma-separated HOOK_DEP_LIST to space-separated for apt-get
if [ -n "$HOOK_DEP_LIST" ]; then
    DEPS_SPACE_SEP=$(echo "$HOOK_DEP_LIST" | tr ',' ' ')
    echo "Installing: $DEPS_SPACE_SEP"
    apt-get install -y $DEPS_SPACE_SEP
else
    echo "No additional dependencies specified"
fi

# Get source code (either clone from Git or use local source)
echo "[2/5] Obtaining source code..."
cd /tmp

if [ -n "$HOOK_LOCAL_SOURCE" ]; then
    # Using local source (already copied into chroot)
    echo "Using local source from: $HOOK_LOCAL_SOURCE"
    [ ! -d "$HOOK_LOCAL_SOURCE" ] && echo "ERROR: Local source not found at $HOOK_LOCAL_SOURCE" && exit 1
    cd "$HOOK_LOCAL_SOURCE"
else
    # Clone from Git repository
    echo "Cloning from Git: $HOOK_GIT_REPO (branch: $HOOK_GIT_TAG)"
    git clone --branch $HOOK_GIT_TAG $HOOK_GIT_REPO
    cd $HOOK_NAME
fi

# Create build directory and configure micropanel
echo "[3/5] Configuring CMake..."
mkdir -p build && cd build
cmake -DCMAKE_INSTALL_PREFIX=$HOOK_INSTALL_DEST \
      -DCMAKE_BUILD_TYPE=Release \
      .. > /dev/null

# Build $UTIL_NAME
echo "[4/5] Building $HOOK_NAME (this may take a few minutes)..."
make -j$(nproc) > /dev/null 2>&1

# Install micropanel
echo "[5/5] Installing $HOOK_NAME to $HOOK_INSTALL_DEST..."
make install > /dev/null

# Set correct ownership (pi user is uid:gid 1000:1000)
chown -R 1000:1000 $HOOK_INSTALL_DEST

######finalize the $UTIL_NAME installation######
echo ""
echo "Finalizing $HOOK_NAME installation..."


# Cleanup build artifacts and source
echo "Cleaning up build artifacts..."
cd /

if [ -n "$HOOK_LOCAL_SOURCE" ]; then
    # For local sources, clean up the copied directory
    echo "Removing local source copy: $HOOK_LOCAL_SOURCE"
    rm -rf "$HOOK_LOCAL_SOURCE"
else
    # For Git sources, clean up the cloned repository
    rm -rf /tmp/$HOOK_NAME
fi

# Purge build dependencies installed by this hook
if [ -n "$HOOK_DEP_LIST" ]; then
    echo "Purging build dependencies: $DEPS_SPACE_SEP"
    apt-get purge -y $DEPS_SPACE_SEP
    apt-get autoremove -y
    apt-get clean
else
    echo "No dependencies to purge"
fi

echo ""
echo "======================================"
echo "  $HOOK_NAME Setup Complete"
echo "======================================"
echo "Installation path: $HOOK_INSTALL_DEST"
echo "Repository: $HOOK_GIT_REPO"
echo "Version/Tag: $HOOK_GIT_TAG"
echo ""
echo "Build dependencies purged by this hook"
echo "======================================"
