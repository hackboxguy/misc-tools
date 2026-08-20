#!/bin/bash
# Trim the authored micropanel-touch image before the A/B layout is built.
#
# Why this exists as its own stage rather than as a setup hook: the imager
# purges build dependencies and then re-asserts the runtime packages, and that
# re-assert runs `apt-get update`, which repopulates /var/lib/apt/lists with
# ~147 MiB the appliance can never use. Anything that trims has to run after
# the last apt command in the pipeline, and this is the first place that is.
#
# What it does not do: it never decides *what* to remove. The removal list is
# board policy in slim-remove.txt; this script is the mechanism that applies
# it, checks the runtime set survived, and asserts the result against the
# board's declared ceiling.
#
# Environment (supplied by build-image.sh):
#   IMAGE_PATH        authored two-partition image (p1 boot, p2 root)
#   SLIM_REMOVE       path to the removal list
#   RUNTIME_DEPS      path to runtime-deps.txt, re-checked after the purge
#   SLIM_MAX_ROOT_MB  fail if the trimmed rootfs still exceeds this many MiB
set -euo pipefail

image_path=${IMAGE_PATH:?IMAGE_PATH is required}
remove_list=${SLIM_REMOVE:?SLIM_REMOVE is required}
runtime_deps=${RUNTIME_DEPS:-none}
max_root_mb=${SLIM_MAX_ROOT_MB:-0}
qemu=${QEMU_STATIC:-/usr/bin/qemu-aarch64-static}

[ "$(id -u)" -eq 0 ] || { echo 'ERROR: run as root to mount the image' >&2; exit 1; }
[ -f "$image_path" ] || { echo "ERROR: image not found: $image_path" >&2; exit 1; }
[ -f "$remove_list" ] || { echo "ERROR: removal list not found: $remove_list" >&2; exit 1; }
[ -x "$qemu" ] || { echo "ERROR: qemu-aarch64-static not found at $qemu" >&2; exit 1; }
for tool in losetup mount umount blockdev df awk sed; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool" >&2; exit 1; }
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

loop=$(losetup --find --show --partscan "$image_path")
for _ in $(seq 1 50); do [ -b "${loop}p2" ] && break; sleep 0.1; done
[ -b "${loop}p2" ] || { echo "ERROR: image partitions did not appear for $loop" >&2; exit 1; }
[ -b "${loop}p3" ] && { echo 'ERROR: slimming expects the authored two-partition image' >&2; exit 1; }

root_mount=$(mktemp -d)
mount "${loop}p2" "$root_mount"
# The kernel maintainer scripts rewrite /boot/firmware when a kernel package
# goes; without the boot partition mounted they would silently leave the
# removed kernel's kernel8.img and initramfs behind, and the boot tree the A/B
# finalizer clones is exactly that directory.
mount "${loop}p1" "$root_mount/boot/firmware"

before_root=$(used_mb "$root_mount")
before_boot=$(used_mb "$root_mount/boot/firmware")

cp "$qemu" "$root_mount$qemu"; copied_qemu=1
mount --bind /dev "$root_mount/dev"
mount -t proc proc "$root_mount/proc"
mount -t sysfs sys "$root_mount/sys"
mounted_extra=1

# Expand the policy list against what is actually installed. A pattern that
# matches nothing is reported rather than fatal: after a base-image bump the
# pinned kernel versions *should* stop matching, and that is the list doing its
# job, not failing. The size assertion at the end is the gate that notices when
# something meant to go stayed.
mapfile -t patterns < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$remove_list" | sed '/^$/d')
[ "${#patterns[@]}" -gt 0 ] || { echo 'ERROR: removal list is empty' >&2; exit 1; }

installed=$(chroot "$root_mount" dpkg-query -W -f '${Package} ${Status}\n' 2>/dev/null \
    | awk '$4 == "installed" {print $1}')

targets=()
unmatched=()
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

if [ "${#unmatched[@]}" -gt 0 ]; then
    echo "NOTE: removal list entries matched nothing installed: ${unmatched[*]}"
fi
[ "${#targets[@]}" -gt 0 ] || { echo 'ERROR: removal list matched no installed package' >&2; exit 1; }

echo "Slimming: purging ${#targets[@]} packages named by $(basename "$remove_list")"
chroot "$root_mount" env DEBIAN_FRONTEND=noninteractive \
    apt-get purge -y --autoremove "${targets[@]}"

# Documentation, translations and package indexes on a read-only appliance
# root: nothing on the device reads them, and nothing on the device can apt.
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

# The purge cascade reaches further than the list names - that is expected and
# recorded - but it must never reach a package the board declared it needs.
#
# The satisfied set is package names *plus* what installed packages Provide,
# because a declared name is not always an installed name: runtime-deps.txt
# asks for libssl3, apt resolves that to libssl3t64, and dpkg only ever hears
# about the latter. Comparing names alone would report a package as missing
# that is installed and working.
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
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        printf '%s\n' "$satisfied" | grep -Fqx "$pkg" || missing="$missing $pkg"
    done < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$runtime_deps" | sed '/^$/d')
    [ -z "$missing" ] || {
        echo "ERROR: the purge cascade removed declared runtime packages:$missing" >&2
        exit 1
    }
fi

umount "$root_mount/sys" "$root_mount/proc" "$root_mount/dev"
mounted_extra=0
rm -f "$root_mount$qemu"; copied_qemu=0

after_root=$(used_mb "$root_mount")
after_boot=$(used_mb "$root_mount/boot/firmware")
sync

printf 'Slimming result: rootfs %s MiB -> %s MiB, boot %s MiB -> %s MiB\n' \
    "$before_root" "$after_root" "$before_boot" "$after_boot"

if [ "$max_root_mb" != 0 ] && [ "$after_root" -gt "$max_root_mb" ]; then
    echo "ERROR: trimmed rootfs is ${after_root} MiB, above the board ceiling of ${max_root_mb} MiB" >&2
    exit 1
fi
