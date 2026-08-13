#!/bin/bash
# Host-side post-image hook. It appends the fixed persistent partition after
# the authored root partition, then initializes its ownership and fstab entry.
set -euo pipefail

export LC_ALL=C

image_path=${IMAGE_PATH:?IMAGE_PATH is required}
data_partition_mb=${DATA_PARTITION_MB:?DATA_PARTITION_MB is required}
data_label=MICROPANEL_DATA
alignment_sectors=2048

for tool in sfdisk fdisk losetup partx mkfs.ext4 blkid mount umount; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: required host tool is missing: $tool" >&2
        exit 1
    }
done

[ "$(id -u)" -eq 0 ] || { echo "ERROR: post-image layout must run as root" >&2; exit 1; }
[ -f "$image_path" ] || { echo "ERROR: image does not exist: $image_path" >&2; exit 1; }
[[ "$data_partition_mb" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: DATA_PARTITION_MB must be a positive integer" >&2
    exit 1
}

loop_device=""
root_mount=""
data_mount=""
cleanup() {
    local status=$?
    if [ -n "$data_mount" ] && mountpoint -q "$data_mount"; then umount "$data_mount"; fi
    if [ -n "$root_mount" ] && mountpoint -q "$root_mount"; then umount "$root_mount"; fi
    if [ -n "$loop_device" ]; then losetup -d "$loop_device" 2>/dev/null || true; fi
    [ -n "$data_mount" ] && rmdir "$data_mount" 2>/dev/null || true
    [ -n "$root_mount" ] && rmdir "$root_mount" 2>/dev/null || true
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

partition_lines=$(sfdisk --dump "$image_path" | awk '/:[[:space:]]*start=/{print}')
partition_count=$(printf '%s\n' "$partition_lines" | sed '/^$/d' | wc -l)
[ "$partition_count" -eq 2 ] || {
    echo "ERROR: expected exactly boot and root partitions before adding data; found $partition_count" >&2
    exit 1
}
root_partition=$(printf '%s\n' "$partition_lines" | tail -n 1)
root_start=$(printf '%s\n' "$root_partition" | sed -n 's/.*start=[[:space:]]*\([0-9][0-9]*\).*/\1/p')
root_size=$(printf '%s\n' "$root_partition" | sed -n 's/.*size=[[:space:]]*\([0-9][0-9]*\).*/\1/p')
[[ "$root_start" =~ ^[0-9]+$ && "$root_size" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: unable to parse root partition geometry" >&2
    exit 1
}
sector_size=$(fdisk -l "$image_path" | sed -n 's/^Sector size (logical\/physical): \([0-9][0-9]*\).*/\1/p')
[[ "$sector_size" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: unable to determine image sector size" >&2; exit 1; }

# Reserve an extra alignment window, then allocate all new tail space to p3.
data_bytes=$((data_partition_mb * 1024 * 1024))
truncate -s "+$((data_bytes + alignment_sectors * sector_size))" "$image_path"
total_sectors=$(( $(stat -c %s "$image_path") / sector_size ))
root_end=$((root_start + root_size))
data_start=$(( (root_end + alignment_sectors - 1) / alignment_sectors * alignment_sectors ))
data_size=$((total_sectors - data_start))
[ "$data_size" -gt 0 ] && [ $((data_size * sector_size)) -ge "$data_bytes" ] || {
    echo "ERROR: image tail is too small for ${data_partition_mb}MiB data partition" >&2
    exit 1
}

printf 'start=%s, size=%s, type=83\n' "$data_start" "$data_size" | sfdisk --append "$image_path"

loop_device=$(losetup --find --show --partscan "$image_path")
partx --update "$loop_device" || true
data_device="${loop_device}p3"
root_device="${loop_device}p2"
for _attempt in $(seq 1 20); do
    [ -b "$data_device" ] && [ -b "$root_device" ] && break
    sleep 1
done
[ -b "$data_device" ] && [ -b "$root_device" ] || {
    echo "ERROR: loop partitions did not appear for $loop_device" >&2
    exit 1
}

mkfs.ext4 -F -L "$data_label" "$data_device" >/dev/null
root_mount=$(mktemp -d)
data_mount=$(mktemp -d)
mount "$root_device" "$root_mount"
mount "$data_device" "$data_mount"

account=$(awk -F: '$1 == "micropanel-touch" { print $3 ":" $4; exit }' "$root_mount/etc/passwd")
[[ "$account" =~ ^[0-9]+:[0-9]+$ ]] || {
    echo "ERROR: micropanel-touch sysuser was not created in the image" >&2
    exit 1
}
install -d -m0750 -o "${account%%:*}" -g "${account##*:}" "$data_mount/micropanel-touch"
install -d -m0750 -o "${account%%:*}" -g "${account##*:}" "$data_mount/micropanel-touch/logs"
install -d -m0700 "$data_mount/micropanel-touch/ssh-host-keys"
# The DHCP server configuration is consumed by a root service but read by the
# HMI only to restore its selector state.  Keep the directory root-owned and
# grant the appliance account group read/execute, never write, access.
install -d -m0750 -o root -g "${account##*:}" "$data_mount/micropanel-touch-network"
install -d -m0750 -o root -g "${account##*:}" \
    "$data_mount/micropanel-touch-network/dhcp-server"
install -d -m0700 "$data_mount/NetworkManager/system-connections"
install -d -m0755 "$root_mount/data"

# NetworkManager's keyfile backend persists connection changes below /etc.
# Seed any image-provided profiles into p3, then bind-mount the directory at
# boot so broker-applied DHCP/static changes survive the read-only root.
network_connections="$root_mount/etc/NetworkManager/system-connections"
if [ -d "$network_connections" ]; then
    cp -a "$network_connections/." "$data_mount/NetworkManager/system-connections/"
fi

data_partuuid=$(blkid -s PARTUUID -o value "$data_device")
[ -n "$data_partuuid" ] || { echo "ERROR: unable to resolve data PARTUUID" >&2; exit 1; }
fstab="$root_mount/etc/fstab"
fstab_tmp="$fstab.micropanel-touch"
grep -vE '[[:space:]](/data|/etc/NetworkManager/system-connections)[[:space:]]' "$fstab" > "$fstab_tmp" || true
printf '\n# MicroPanel Touch persistent state (must not block boot if damaged).\n' >> "$fstab_tmp"
printf 'PARTUUID=%s /data ext4 defaults,nofail,x-systemd.device-timeout=5s 0 2\n' "$data_partuuid" >> "$fstab_tmp"
printf '%s\n' '/data/NetworkManager/system-connections /etc/NetworkManager/system-connections none bind,nofail,x-systemd.requires=data.mount,x-systemd.before=NetworkManager.service 0 0' >> "$fstab_tmp"
mv "$fstab_tmp" "$fstab"

sync
echo "Created ${data_partition_mb}MiB persistent data partition: $data_device ($data_partuuid)"
