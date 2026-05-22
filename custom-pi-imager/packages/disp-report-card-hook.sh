#!/bin/bash
set -e

echo "======================================"
echo "  disp-report-card Setup Hook"
echo "======================================"
echo ""

# Environment variables available:
# - MOUNT_POINT, PI_PASSWORD, IMAGE_WORK_DIR (always)
# - HOOK_GIT_REPO: git URL (parameterized mode)
# - HOOK_GIT_TAG: branch/tag/commit (parameterized mode)
# - HOOK_INSTALL_DEST: install prefix (parameterized mode)
# - HOOK_DEP_LIST: runtime apt deps, comma separated (parameterized mode)
#
# Usage in micropanel-packages.txt:
#   packages/disp-report-card-hook.sh|https://github.com/hackboxguy/disp-report-card.git|main|/home/pi/micropanel|python3-matplotlib,python3-numpy
#
# disp-report-card is a one-shot CLI tool (no systemd service): it turns a
# disptool/display-test-framework result folder into a single A4 PNG report card.
# Pure Python, so there are NO build dependencies to purge afterwards.

GIT_REPO="${HOOK_GIT_REPO:-https://github.com/hackboxguy/disp-report-card.git}"
GIT_TAG="${HOOK_GIT_TAG:-main}"
INSTALL_DEST="${HOOK_INSTALL_DEST:-/home/pi/micropanel}"
# Runtime deps are KEPT in the image (matplotlib + numpy). numpy<2 is satisfied
# by Debian bookworm's python3-numpy. colour-science (advanced render) is omitted.
RUNTIME_DEPS="${HOOK_DEP_LIST:-python3-matplotlib,python3-numpy}"
RUNTIME_DEPS_SPACE_SEP=$(echo "$RUNTIME_DEPS" | tr ',' ' ')

echo "Running inside chroot environment"
echo "  Repo:   ${GIT_REPO}"
echo "  Ref:    ${GIT_TAG}"
echo "  Dest:   ${INSTALL_DEST}"
echo "  Deps:   ${RUNTIME_DEPS_SPACE_SEP} (kept in image)"
echo ""

# [1/4] Install runtime dependencies (kept; not purged)
echo "[1/4] Installing runtime dependencies..."
apt-get update -qq
apt-get install -y python3 ${RUNTIME_DEPS_SPACE_SEP}

# [2/4] Clone source
echo "[2/4] Cloning disp-report-card..."
cd /tmp
rm -rf /tmp/disp-report-card
git clone "${GIT_REPO}" disp-report-card
cd disp-report-card
echo "Checking out: ${GIT_TAG}"
git checkout "${GIT_TAG}"

# [3/4] Install via Makefile (module + launcher under the install prefix)
echo "[3/4] Installing to ${INSTALL_DEST}..."
make install PREFIX="${INSTALL_DEST}" PYTHON=python3

# Set correct ownership (pi user is uid:gid 1000:1000)
chown -R 1000:1000 "${INSTALL_DEST}/lib/disp-report-card"
chown 1000:1000 "${INSTALL_DEST}/bin/display-report-card"

# [4/4] Verify the runtime deps import (fails the build loudly if missing)
echo "[4/4] Verifying matplotlib/numpy are importable..."
python3 -c "import matplotlib; matplotlib.use('Agg'); import numpy; print('  matplotlib', matplotlib.__version__, '/ numpy', numpy.__version__)"

# Cleanup source clone
echo "Cleaning up..."
cd /
rm -rf /tmp/disp-report-card

echo ""
echo "======================================"
echo "  disp-report-card Setup Complete"
echo "======================================"
echo "Command:  ${INSTALL_DEST}/bin/display-report-card"
echo "Module:   ${INSTALL_DEST}/lib/disp-report-card/display_report_card.py"
echo "Repo:     ${GIT_REPO} (ref: ${GIT_TAG})"
echo "Run e.g.: ${INSTALL_DEST}/bin/display-report-card --input <result-dir> --output <out.png>"
echo "(No systemd service, no build deps to purge)"
echo "======================================"
