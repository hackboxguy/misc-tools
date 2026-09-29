#!/bin/bash
# Trim the authored micropanel image before the A/B layout is built (A/B
# builds only: board.conf sets IMAGE_SLIM_HOOK_ab, never a plain key).
#
# Modelled on micropanel-touch-slim.sh - runs after the imager's last apt
# command, applies a board-authored removal list through a chroot, re-checks
# the declared runtime set, asserts a size ceiling - and extended for this
# board's custom kernel:
#   - the boot partition is pruned to what a Pi 4 booting the custom Image
#     needs, because the A/B layout keeps three copies of it (flat, A/, B/) in
#     one AB_BOOT_PARTITION_MB slot;
#   - every module tree, initrd and kernel config of a kernel that is not the
#     custom one goes, and the custom kernel's files are asserted to survive
#     the stock kernel packages' maintainer scripts, which rewrite /boot/firmware.
#
# Environment (supplied by build-image.sh):
#   IMAGE_PATH            authored two-partition image (p1 boot, p2 root)
#   SLIM_REMOVE           removal list (apt package names or globs)
#   RUNTIME_DEPS          runtime-deps-ab.txt, re-checked after the purge
#   SLIM_MAX_ROOT_MB      fail if the trimmed rootfs still exceeds this many MiB
#   AB_BOOT_PARTITION_MB  fail if three copies of the boot tree cannot fit a slot
set -euo pipefail

image_path=${IMAGE_PATH:?IMAGE_PATH is required}
remove_list=${SLIM_REMOVE:?SLIM_REMOVE is required}
runtime_deps=${RUNTIME_DEPS:-none}
max_root_mb=${SLIM_MAX_ROOT_MB:-0}
boot_slot_mb=${AB_BOOT_PARTITION_MB:-0}
qemu=${QEMU_STATIC:-/usr/bin/qemu-aarch64-static}

say() { echo "[slim] $*"; }
die() { echo "[slim] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die 'run as root to mount the image'
[ -f "$image_path" ] || die "image not found: $image_path"
[ -f "$remove_list" ] || die "removal list not found: $remove_list"
[ -x "$qemu" ] || die "qemu-aarch64-static not found at $qemu"
for tool in losetup mount umount df du awk sed find; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool missing: $tool"
done

loop="" root_mount="" mounted_extra=0 copied_qemu=0

cleanup() {
    set +e
    if [ "$mounted_extra" = 1 ] && [ -n "$root_mount" ]; then
        umount "$root_mount/sys" 2>/dev/null
        umount "$root_mount/proc" 2>/dev/null
        umount "$root_mount/dev" 2>/dev/null
    fi
    [ "$copied_qemu" = 1 ] && [ -n "$root_mount" ] && rm -f "$root_mount$qemu"
    if [ -n "$root_mount" ]; then
        umount "$root_mount/boot/firmware" 2>/dev/null
        umount "$root_mount" 2>/dev/null
        rmdir "$root_mount" 2>/dev/null
    fi
    [ -n "$loop" ] && losetup -d "$loop" 2>/dev/null
    set -e
}
trap cleanup EXIT HUP INT TERM

used_mb() { df -BM --output=used "$1" | awk 'NR==2 {gsub("M",""); print $1}'; }
tree_kib() { du -sk "$1" | cut -f1; }

loop=$(losetup --find --show --partscan "$image_path")
for _ in $(seq 1 50); do [ -b "${loop}p2" ] && break; sleep 0.1; done
[ -b "${loop}p2" ] || die "image partitions did not appear for $loop"
[ -b "${loop}p3" ] && die 'slimming expects the authored two-partition image'

root_mount=$(mktemp -d)
mount "${loop}p2" "$root_mount"
# The kernel packages' maintainer scripts rewrite /boot/firmware; they must see
# the real boot partition, and this hook must see what they leave behind.
mount "${loop}p1" "$root_mount/boot/firmware"
boot="$root_mount/boot/firmware"

before_root=$(used_mb "$root_mount")
before_boot_kib=$(tree_kib "$boot")

# The custom kernel, exactly as the appliance hook derives it: the release the
# Image itself reports, not a directory listing.
release=$(grep -a -o -m1 'Linux version [^ ]*' "$boot/Image" | awk '{print $3}')
[ -n "$release" ] && [ -d "$root_mount/lib/modules/$release" ] && [ ! -L "$root_mount/lib/modules/$release" ] || \
    die "cannot identify the custom kernel's module directory (release '${release:-?}')"
say "custom kernel: $release"
display_file_present=0
[ -f "$boot/micropanel-display.txt" ] && display_file_present=1

cp "$qemu" "$root_mount$qemu"; copied_qemu=1
mount --bind /dev "$root_mount/dev"
mount -t proc proc "$root_mount/proc"
mount -t sysfs sys "$root_mount/sys"
mounted_extra=1

# --- 1. Packages first: their maintainer scripts rewrite /boot/firmware -------
mapfile -t patterns < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$remove_list" | sed '/^$/d')
[ "${#patterns[@]}" -gt 0 ] || die 'removal list is empty'
installed=$(chroot "$root_mount" dpkg-query -W -f '${Package} ${Status}\n' 2>/dev/null \
    | awk '$4 == "installed" {print $1}')
targets=() unmatched=()
for pattern in "${patterns[@]}"; do
    matched=$(printf '%s\n' "$installed" | awk -v p="$pattern" '
        BEGIN { gsub(/[.+]/, "\\\\&", p); gsub(/\*/, ".*", p); p = "^" p "$" }
        $0 ~ p { print }')
    if [ -n "$matched" ]; then
        while IFS= read -r pkg; do targets+=("$pkg"); done <<<"$matched"
    else
        unmatched+=("$pattern")
    fi
done
[ "${#unmatched[@]}" -eq 0 ] || say "NOTE: removal list entries matched nothing installed: ${unmatched[*]}"
if [ "${#targets[@]}" -gt 0 ]; then
    say "purging ${#targets[@]} packages named by $(basename "$remove_list"): ${targets[*]}"
    # Exactly what the list names, no --autoremove: this image carries
    # source-built binaries whose libraries apt does not know they need (the
    # ELF check below), so apt's idea of "no longer needed" is not safe here.
    chroot "$root_mount" env DEBIAN_FRONTEND=noninteractive \
        apt-get purge -y "${targets[@]}"
fi
chroot "$root_mount" /bin/bash -s <<'INNER'
set -eu
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /usr/share/doc/* /usr/share/doc-base/* /usr/share/man/* \
       /usr/share/info/* /usr/share/lintian/*
find /usr/share/locale -mindepth 1 -maxdepth 1 -type d \
     ! -name 'C*' ! -name 'en*' -exec rm -rf {} +
rm -rf /var/cache/man/* /var/log/apt/* /var/log/journal/*
find /var/log -type f -name '*.log' -delete
INNER

# --- 2. Every kernel that is not the custom one -------------------------------
# Module trees the packages did not own (the base's older kernels, left behind
# by its apt upgrade), and every initrd and config of a kernel that is gone.
for module_dir in "$root_mount"/lib/modules/*; do
    name=$(basename "$module_dir")
    [ "$name" = "$release" ] && continue
    if [ -L "$module_dir" ] && [ "$(readlink "$module_dir")" = "$release" ]; then
        continue   # the kernel builder's '<release>+' fallback link
    fi
    rm -rf "$module_dir"
    say "removed /lib/modules/$name"
done
for leftover in "$root_mount"/boot/initrd.img-* "$root_mount"/boot/config-* \
                "$root_mount"/boot/System.map-* "$root_mount"/boot/vmlinuz-*; do
    [ -e "$leftover" ] || continue
    [ "$(basename "$leftover")" = "config-$release" ] && continue
    rm -f "$leftover"
    say "removed /boot/$(basename "$leftover")"
done

# --- 3. The boot partition: what a Pi 4 booting the custom Image reads --------
rm -rf "$boot"/backup-*
rm -f "$boot/kernel8.img" "$boot/kernel_2712.img" "$boot/initramfs8" "$boot/initramfs_2712"
rm -f "$boot"/bcm2710*.dtb "$boot"/bcm2712*.dtb "$boot"/bcm2837*.dtb

# --- 4. What must have survived ------------------------------------------------
for required in "$boot/Image" "$boot/initramfs-custom" "$boot/config.txt" "$boot/cmdline.txt" \
                "$boot/overlays" "$boot/bcm2711-rpi-4-b.dtb" "$boot/start4.elf" "$boot/fixup4.dat" \
                "$root_mount/boot/config-$release"; do
    [ -e "$required" ] || die "slimming removed something the custom kernel boots with: ${required#"$root_mount"}"
done
ls "$root_mount/lib/modules/$release/extra/"hh983-serializer.ko* >/dev/null 2>&1 || \
    die "the custom kernel's hh983-serializer module did not survive"
[ "$display_file_present" = 0 ] || [ -f "$boot/micropanel-display.txt" ] || \
    die 'slimming removed the device display configuration'

# The purge cascade must never reach a package the board declared it needs. The
# satisfied set is package names plus what installed packages Provide (a
# declared name is not always the installed name).
if [ "$runtime_deps" != "none" ] && [ -f "$runtime_deps" ]; then
    satisfied=$(chroot "$root_mount" dpkg-query -W \
        -f '${Status}\t${binary:Package}\t${Provides}\n' 2>/dev/null |
        awk -F'\t' '$1 == "install ok installed" {
            split($2, name, ":"); print name[1]
            n = split($3, provided, ",")
            for (i = 1; i <= n; i++) {
                gsub(/^[ \t]+|[ \t]+$/, "", provided[i])
                split(provided[i], p, " ")
                if (p[1] != "") { split(p[1], q, ":"); print q[1] }
            }
        }')
    missing=""
    # A here-string, not `printf | grep -q`: grep -q exits at the first match,
    # the printf side can then take SIGPIPE, and under pipefail a package that
    # is installed reads as missing (the 2.04 build failed on fxload so).
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        grep -Fqx -- "$pkg" <<< "$satisfied" || missing="$missing $pkg"
    done < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$runtime_deps" | sed '/^$/d')
    [ -z "$missing" ] || die "the purge cascade removed declared runtime packages:$missing"
fi
# micropanel's own binaries are built from source in the apps stage, so apt
# does not know which libraries they need: prove every one still resolves.
unresolved=$(chroot "$root_mount" /bin/bash -s <<'INNER'
for dir in /home/pi/micropanel/bin /home/pi/micropanel/usr/bin /home/pi/micropanel/sbin \
           /home/pi/micropanel/fpga/bin /home/pi/als-dimmer/bin /home/pi/micropanel/lib; do
    [ -d "$dir" ] || continue
    find "$dir" -maxdepth 1 -type f | while read -r file; do
        head -c 4 "$file" 2>/dev/null | grep -q 'ELF' || continue
        ldd "$file" 2>/dev/null | grep -F 'not found' | sed "s#^#$file: #"
    done
done
INNER
)
[ -z "$unresolved" ] || die "slimming left source-built binaries with unresolved libraries:
$unresolved"

umount "$root_mount/sys" "$root_mount/proc" "$root_mount/dev"
mounted_extra=0
rm -f "$root_mount$qemu"; copied_qemu=0
sync

after_root=$(used_mb "$root_mount")
after_boot_kib=$(tree_kib "$boot")
boot_times_three_mb=$(( (after_boot_kib * 3 + 1023) / 1024 ))
say "result: rootfs ${before_root} MiB -> ${after_root} MiB; boot tree $((before_boot_kib / 1024)) MiB -> $((after_boot_kib / 1024)) MiB (x3 = ${boot_times_three_mb} MiB for flat + A/ + B/)"

if [ "$max_root_mb" != 0 ] && [ "$after_root" -gt "$max_root_mb" ]; then
    die "trimmed rootfs is ${after_root} MiB, above the board ceiling of ${max_root_mb} MiB"
fi
# Three copies plus room for the selector files and FAT overhead.
if [ "$boot_slot_mb" != 0 ] && [ $((boot_times_three_mb + 16)) -gt "$boot_slot_mb" ]; then
    die "three copies of the ${after_boot_kib} KiB boot tree need ${boot_times_three_mb} MiB; the boot slot is ${boot_slot_mb} MiB"
fi
