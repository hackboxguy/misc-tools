#!/bin/sh
# pi-ab-update: serve a release directory over HTTP for bench rehearsal.
#
# Stands in for the real release host so an over-the-air update can be proven
# on a bench LAN before anything is published. It serves the three assets a
# device asks for - the manifest, its signature, and the bundle - straight out
# of a payload directory, exactly as produced by `build-image.sh --payload`.
#
# This is a rehearsal tool, not a release host: no TLS, no access control, and
# it serves whatever is in the directory it is given. That is sound here only
# because a device authenticates a release by its pinned signing key and not by
# the transport, so an unauthenticated server cannot make it accept anything it
# would otherwise refuse. Point a shipping image at https.
#
# Usage:
#   ab-serve-release.sh <payload-dir> [port] [bind-address]
#
# Then build the device image so it asks this machine:
#   build-image.sh ... --release-url-template=http://<this-host>:<port>/@ASSET@
set -eu

payload_dir=${1:?usage: ab-serve-release.sh <payload-dir> [port] [bind-address]}
port=${2:-8000}
bind=${3:-0.0.0.0}

[ -d "$payload_dir" ] || { echo "ERROR: not a directory: $payload_dir" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo 'ERROR: python3 is required' >&2; exit 1; }

# Fail loudly now rather than as a puzzling device-side error later. The names
# are version-less by contract: the version lives inside the signed manifest.
missing=0
# Quoted: these are patterns to match inside the payload directory, and must
# not be expanded against whatever directory this script was started from.
for asset in '*.manifest' '*.manifest.sig' '*.mpupdate'; do
    # shellcheck disable=SC2144  # deliberate: any match satisfies the pattern
    if ! ls "$payload_dir"/$asset >/dev/null 2>&1; then
        echo "ERROR: no $asset in $payload_dir" >&2
        missing=1
    fi
done
[ "$missing" -eq 0 ] || {
    echo "HINT: build the payload first: build-image.sh ... --payload" >&2
    exit 1
}

# 0.0.0.0 is the useful default - the device under test has to reach this host
# across the LAN - but it is worth saying plainly what that means.
if [ "$bind" = 0.0.0.0 ]; then
    echo "NOTE: serving to every host on this network, not just the bench device."
    echo "      Pass a bind address as the third argument to narrow it."
fi
echo "serving $payload_dir on http://$bind:$port/"
for asset in "$payload_dir"/*.manifest "$payload_dir"/*.manifest.sig "$payload_dir"/*.mpupdate; do
    printf '  %s  (%s bytes)\n' "$(basename "$asset")" "$(stat -c %s "$asset")"
done
echo 'stop with Ctrl-C'
cd "$payload_dir"
exec python3 -m http.server "$port" --bind "$bind"
