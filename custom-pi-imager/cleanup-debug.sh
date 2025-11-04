#!/bin/bash

# Cleanup Debug Session Helper Script
# Usage: sudo ./cleanup-debug.sh /tmp/custom

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root (use sudo)${NC}"
    exit 1
fi

if [ $# -lt 1 ]; then
    echo "Usage: sudo $0 <OUTPUT_DIR>"
    echo ""
    echo "Example:"
    echo "  sudo $0 /tmp/custom"
    echo ""
    exit 1
fi

WORK_DIR="$1"
MOUNT_POINT="${WORK_DIR}/mnt"

if [ ! -d "$WORK_DIR" ]; then
    echo -e "${RED}Error: Directory not found: ${WORK_DIR}${NC}"
    exit 1
fi

echo -e "${YELLOW}Cleaning up debug session for: ${WORK_DIR}${NC}"
echo ""

# Check if mount point file exists
if [ -f "${WORK_DIR}/.mount-point" ]; then
    MOUNT_POINT=$(cat "${WORK_DIR}/.mount-point")
    echo "Using saved mount point: ${MOUNT_POINT}"
fi

# Unmount all chroot bind mounts
echo "Unmounting chroot filesystems..."
umount -l "${MOUNT_POINT}/dev/pts" 2>/dev/null || true
umount -l "${MOUNT_POINT}/dev" 2>/dev/null || true
umount -l "${MOUNT_POINT}/sys" 2>/dev/null || true
umount -l "${MOUNT_POINT}/proc" 2>/dev/null || true
umount -l "${MOUNT_POINT}/boot/firmware" 2>/dev/null || true

# Unmount root filesystem
echo "Unmounting root filesystem..."
umount -l "${MOUNT_POINT}" 2>/dev/null || true

sleep 2

# Detach loop device
if [ -f "${WORK_DIR}/loop_device" ]; then
    LOOP_DEVICE=$(cat "${WORK_DIR}/loop_device")
    if [ -n "$LOOP_DEVICE" ]; then
        echo "Detaching loop device: ${LOOP_DEVICE}"
        losetup -d "${LOOP_DEVICE}" 2>/dev/null || true
        rm -f "${WORK_DIR}/loop_device"
    fi
elif [ -f "${WORK_DIR}/.loop-device" ]; then
    LOOP_DEVICE=$(cat "${WORK_DIR}/.loop-device")
    if [ -n "$LOOP_DEVICE" ]; then
        echo "Detaching loop device: ${LOOP_DEVICE}"
        losetup -d "${LOOP_DEVICE}" 2>/dev/null || true
        rm -f "${WORK_DIR}/.loop-device"
    fi
fi

# Remove mount point directory if empty
if [ -d "${MOUNT_POINT}" ] && [ -z "$(ls -A ${MOUNT_POINT})" ]; then
    echo "Removing empty mount point directory..."
    rmdir "${MOUNT_POINT}" 2>/dev/null || true
fi

# Remove debug marker files
rm -f "${WORK_DIR}/.mount-point" 2>/dev/null || true
rm -f "${WORK_DIR}/.loop-device" 2>/dev/null || true
rm -f "${WORK_DIR}/cleanup.sh" 2>/dev/null || true

echo ""
echo -e "${GREEN}✓ Cleanup complete!${NC}"
echo ""
echo "The image file is still available at:"
echo "  ${WORK_DIR}/*.img"
echo ""
echo "You can now:"
echo "  1. Re-run the build with fixes"
echo "  2. Use the .img file if the build was successful"
echo "  3. Delete the work directory: rm -rf ${WORK_DIR}"
echo ""
