#!/bin/bash
# Build and install jsonrpc-tcp-srv (xmproxysrv XMPP IoT endpoint + sysmgr)
# into the MicroPanel Touch image. Runs inside the ARM64 chroot.
#
# Hook-list line:
#   packages/jsonrpc-tcp-srv-hook.sh|${JSONRPC_TCP_SRV_REPO}|${JSONRPC_TCP_SRV_REVISION}|/opt/xmproxy|
#
# What it does:
#  - recursive clone pinned to the requested revision (or HOOK_LOCAL_SOURCE)
#  - the repo's own services/xmproxy/deploy/build-from-source.sh builds gloox
#    with OpenSSL (distribution gloox links GnuTLS and cannot authenticate
#    against Snikket) and the daemons into the prefix
#  - account via sysusers.d, units enabled by path, no daemon-reload
#  - durable state lives under /data/xmproxy (etc + state), created and
#    seeded on every boot by xmproxy-seed.service from the read-only defaults
#    in <prefix>/share/xmproxy/etc; the rootfs overlay is never written
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

: "${HOOK_GIT_REPO:?HOOK_GIT_REPO is required}"
: "${HOOK_GIT_TAG:?HOOK_GIT_TAG is required}"
: "${HOOK_INSTALL_DEST:?HOOK_INSTALL_DEST is required}"
destination=$HOOK_INSTALL_DEST
revision=$HOOK_GIT_TAG
case "$destination" in /*) ;; *) echo "ERROR: install destination must be absolute: $destination" >&2; exit 1 ;; esac
data_root=/data/xmproxy

echo "======================================"
echo "  jsonrpc-tcp-srv (xmproxy) Setup Hook"
echo "======================================"
echo "  repo:     $HOOK_GIT_REPO"
echo "  revision: $revision"
echo "  dest:     $destination"

# --- sources -----------------------------------------------------------------
if [ -n "${HOOK_LOCAL_SOURCE:-}" ]; then
    source_root=$HOOK_LOCAL_SOURCE
    [ -d "$source_root" ] || { echo "ERROR: local source missing: $source_root" >&2; exit 1; }
    resolved_revision=$(git -C "$source_root" rev-parse HEAD 2>/dev/null || echo "local")
else
    source_root=/tmp/jsonrpc-tcp-srv-src
    rm -rf "$source_root"
    git clone --recursive "$HOOK_GIT_REPO" "$source_root"
    git -C "$source_root" checkout --detach "$revision" 2>/dev/null || {
        git -C "$source_root" fetch origin "$revision"
        git -C "$source_root" checkout --detach FETCH_HEAD
    }
    git -C "$source_root" submodule update --init --recursive
    resolved_revision=$(git -C "$source_root" rev-parse HEAD)
    if [ "${#revision}" = 40 ] && [ "$resolved_revision" != "$revision" ]; then
        echo "ERROR: pinned revision $revision resolved to $resolved_revision" >&2
        exit 1
    fi
fi
echo "  resolved: $resolved_revision"

# --- build (gloox with OpenSSL + daemons) ------------------------------------
deploy="$source_root/services/xmproxy/deploy"
"$deploy/build-from-source.sh" --src "$source_root" --prefix "$destination" --jobs "$(nproc)"

# --- read-only defaults shipped in the slot ----------------------------------
install -d -m0755 "$destination/share/xmproxy/etc"
install -m0644 "$deploy/xmproxy.env" "$destination/share/xmproxy/etc/xmproxy.env"
install -m0644 "$source_root/services/xmproxy/helpers/configs/manifest-pi.json" \
    "$destination/share/xmproxy/etc/manifest.json"
install -m0640 "$source_root/services/xmproxy/srv/xmpp-login.txt" \
    "$destination/share/xmproxy/etc/xmpp-login.txt"
install -m0755 "$deploy/xmproxy-seed.sh" "$destination/bin/xmproxy-seed.sh"
# the prefix-installed legacy units (User=pi, /home/pi paths) are not used
rm -f "$destination/etc/systemd/system/xmproxysrv.service" \
      "$destination/etc/systemd/system/sysmgr.service" \
      "$destination/etc/init.d/"*XmproxyStartupScr* "$destination/etc/init.d/"*SysmgrStartupScr* 2>/dev/null || true

# --- account -------------------------------------------------------------------
install -Dm0644 "$deploy/sysusers-xmproxy.conf" /usr/lib/sysusers.d/xmproxy.conf
systemd-sysusers /usr/lib/sysusers.d/xmproxy.conf
getent passwd xmproxy > /dev/null || { echo "ERROR: xmproxy account was not created" >&2; exit 1; }

# --- units: config and state under /data/xmproxy -------------------------------
for unit in sysmgr.service xmproxysrv.service xmproxy-seed.service; do
    sed -e "s|/opt/xmproxy|$destination|g" \
        -e "s|/etc/xmproxy|$data_root/etc|g" \
        -e "s|/var/lib/xmproxy|$data_root/state|g" \
        "$deploy/$unit" > "/etc/systemd/system/$unit"
    chmod 0644 "/etc/systemd/system/$unit"
done
# the seed unit runs before the daemons and needs /data mounted; keep the
# rootfs overlay untouched by the daemons
sed -i "s|^ReadWritePaths=.*|ReadWritePaths=$data_root/state /tmp|" /etc/systemd/system/xmproxysrv.service
systemctl enable /etc/systemd/system/xmproxy-seed.service
systemctl enable /etc/systemd/system/sysmgr.service
systemctl enable /etc/systemd/system/xmproxysrv.service

# --- image manifest -------------------------------------------------------------
manifest_dir="/opt/micropanel-touch/share/micropanel-touch"
if [ -d "$manifest_dir" ]; then
    grep -v '^JSONRPC_TCP_SRV_REVISION=' "$manifest_dir/image-manifest.env" > "$manifest_dir/image-manifest.env.new" 2>/dev/null || true
    echo "JSONRPC_TCP_SRV_REVISION=$resolved_revision" >> "$manifest_dir/image-manifest.env.new"
    mv "$manifest_dir/image-manifest.env.new" "$manifest_dir/image-manifest.env"
fi
install -d -m0755 "$destination/share/xmproxy"
echo "JSONRPC_TCP_SRV_REVISION=$resolved_revision" > "$destination/share/xmproxy/revision.env"

# --- cleanup -------------------------------------------------------------------
rm -rf "$source_root"
echo "======================================"
echo "  jsonrpc-tcp-srv installed in $destination"
echo "  config: $data_root/etc  state: $data_root/state (seeded at boot)"
echo "======================================"
