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
# - HOOK_DEP_LIST: informational only here (see note below)
#
# Usage in micropanel-packages.txt:
#   packages/disp-report-card-hook.sh|https://github.com/hackboxguy/disp-report-card.git|main|/home/pi/micropanel|python3-matplotlib,python3-numpy
#
# disp-report-card is a one-shot CLI tool (no systemd service): it turns a
# disptool/display-test-framework result folder into a single A4 PNG report card.
#
# NOTE on dependencies: matplotlib + numpy are deliberately NOT installed here.
# The imager runs a build-dep purge AFTER all hooks, and that purge cascade-removes
# matplotlib (it's pulled out via python3-fonttools when the python3-dev/zlib1g-dev
# chain is purged) -- so anything apt-installed in a hook gets wiped. Instead the
# runtime deps live in runtime-deps.txt and the imager reinstalls that list *after*
# the purge (reinstall_runtime_packages). This hook only installs the script itself.

GIT_REPO="${HOOK_GIT_REPO:-https://github.com/hackboxguy/disp-report-card.git}"
GIT_TAG="${HOOK_GIT_TAG:-main}"
INSTALL_DEST="${HOOK_INSTALL_DEST:-/home/pi/micropanel}"

echo "Running inside chroot environment"
echo "  Repo:   ${GIT_REPO}"
echo "  Ref:    ${GIT_TAG}"
echo "  Dest:   ${INSTALL_DEST}"
echo ""

# [1/3] Clone source (git/make are present at hook time; purged later by the imager)
echo "[1/3] Cloning disp-report-card..."
cd /tmp
rm -rf /tmp/disp-report-card
git clone "${GIT_REPO}" disp-report-card
cd disp-report-card
echo "Checking out: ${GIT_TAG}"
git checkout "${GIT_TAG}"

# [2/3] Install via Makefile (module + launcher under the install prefix)
echo "[2/3] Installing to ${INSTALL_DEST}..."
make install PREFIX="${INSTALL_DEST}" PYTHON=python3
# Set correct ownership (pi user is uid:gid 1000:1000)
chown -R 1000:1000 "${INSTALL_DEST}/lib/disp-report-card"
chown 1000:1000 "${INSTALL_DEST}/bin/display-report-card"

# [3/3] Cleanup source clone
echo "[3/3] Cleaning up..."
cd /
rm -rf /tmp/disp-report-card

echo ""
echo "======================================"
echo "  disp-report-card Setup Complete"
echo "======================================"
echo "Command:  ${INSTALL_DEST}/bin/display-report-card"
echo "Module:   ${INSTALL_DEST}/lib/disp-report-card/display_report_card.py"
echo "Repo:     ${GIT_REPO} (ref: ${GIT_TAG})"
echo "Runtime deps (matplotlib/numpy): from runtime-deps.txt, reinstalled post-purge"
echo "======================================"
