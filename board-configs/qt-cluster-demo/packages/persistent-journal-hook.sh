#!/bin/bash
set -e

# persistent-journal-hook.sh - runs inside the ARM64 chroot.
#
# Make the journal survive a reboot.
#
# Raspberry Pi OS ships Storage=volatile in /etc/systemd/journald.conf, so logs
# live in /run and vanish on every power-cycle. That is a sensible default for a
# generic SD-card image, but it is the wrong trade for this board: the failures
# that matter here happen AT BOOT, on a direct Pi<->AGX cable, where the box is
# unreachable over the network until you move it back to DHCP -- and moving it
# back means power-cycling, which destroyed the only evidence. Diagnosing the
# SOME/IP boot-order bug needed two failed attempts before the logs were kept.
#
# /var/log/journal already exists in the stock image, so creating it is NOT
# enough on its own: Storage=volatile overrides the directory's presence. Set
# Storage explicitly, via a drop-in rather than by editing the distro's file.
#
# The SD-card wear that motivated volatile is real, so keep it small and capped:
# 64 MB total is many boots' worth of this system's log volume (~9 MB/boot).

DROPIN_DIR=/etc/systemd/journald.conf.d
DROPIN="$DROPIN_DIR/10-persistent.conf"

echo "======================================"
echo "  Persistent journal (capped 64M)"
echo "======================================"

mkdir -p "$DROPIN_DIR"
cat > "$DROPIN" <<EOF
# Overrides Storage=volatile from /etc/systemd/journald.conf: this board needs
# boot-time logs to survive the power-cycle that follows a failed bring-up.
[Journal]
Storage=persistent
# Bounded so a long-running board cannot fill the card, and so SD wear stays
# comparable to the volatile default.
SystemMaxUse=64M
SystemMaxFileSize=8M
SystemMaxFiles=8
RuntimeMaxUse=16M
EOF
chmod 644 "$DROPIN"

# Present in the stock image already, but create it so the hook is correct even
# if that ever changes; journald needs it to exist before it will write there.
mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal 2>/dev/null || true

echo "Installed $DROPIN:"
cat "$DROPIN"
echo "journald will store logs under /var/log/journal from first boot."
