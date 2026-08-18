#!/bin/bash
# Release signing key custody helper for MicroPanel Touch update bundles.
#
# Build-side signing starts with the first format=2 release, long before the
# device enforces it (plan Stage 4). Every published bundle therefore already
# carries `manifest.sig`, so turning verification on needs no migration
# release. See BUILD.md "Release signing key custody" for the operator rules.
#
# The key lives outside every git checkout on purpose: a private key inside a
# repository is one `git push` away from being public.
set -euo pipefail

export LC_ALL=C

default_dir=/etc/micropanel-touch/release-signing
key_path=${MICROPANEL_RELEASE_KEY:-$default_dir/ed25519-release.key}
public_path="$key_path.pub"

usage() {
    cat >&2 <<'EOF'
Usage: micropanel-touch-release-key.sh ensure
       micropanel-touch-release-key.sh key-path
       micropanel-touch-release-key.sh public-path
       micropanel-touch-release-key.sh sign FILE SIGNATURE
       micropanel-touch-release-key.sh verify FILE SIGNATURE

Override the key location with MICROPANEL_RELEASE_KEY=/path/to/key.
EOF
    exit 2
}

need_openssl() {
    command -v openssl >/dev/null 2>&1 || {
        echo 'ERROR: openssl is required to sign update manifests' >&2
        exit 1
    }
}

ensure_key() {
    need_openssl
    if [ -f "$key_path" ] && [ -f "$public_path" ]; then
        return 0
    fi
    [ ! -e "$key_path" ] || {
        echo "ERROR: $key_path exists without its public half; refusing to overwrite it" >&2
        exit 1
    }
    [ "$(id -u)" -eq 0 ] || {
        echo "ERROR: run as root to create $key_path" >&2
        exit 1
    }
    install -d -m0700 -o root -g root "$(dirname "$key_path")"
    local temporary
    temporary=$(mktemp "$(dirname "$key_path")/.release-key.XXXXXX")
    chmod 0600 "$temporary"
    openssl genpkey -algorithm ed25519 -out "$temporary" >/dev/null
    openssl pkey -in "$temporary" -pubout -out "$public_path" >/dev/null
    chmod 0644 "$public_path"
    mv -f "$temporary" "$key_path"
    sync
    cat >&2 <<EOF
NOTICE: created a new ed25519 release signing key.
  private: $key_path (root, 0600 — never commit it, back it up offline)
  public:  $public_path (baked into every A/B image for Stage 4 verification)
Losing the private key means no already-flashed device will accept a future
signed release, so back it up before publishing anything with it.
EOF
}

sign_file() { # $1=payload $2=signature destination
    need_openssl
    [ -f "$key_path" ] || { echo "ERROR: release signing key is unavailable: $key_path" >&2; exit 1; }
    [ -f "$1" ] || { echo "ERROR: nothing to sign: $1" >&2; exit 1; }
    openssl pkeyutl -sign -inkey "$key_path" -rawin -in "$1" -out "$2"
    [ -s "$2" ] || { echo 'ERROR: manifest signature is empty' >&2; exit 1; }
}

verify_file() { # $1=payload $2=signature
    need_openssl
    [ -f "$public_path" ] || { echo "ERROR: release public key is unavailable: $public_path" >&2; exit 1; }
    openssl pkeyutl -verify -pubin -inkey "$public_path" -rawin -in "$1" -sigfile "$2" >/dev/null
}

[ "$#" -ge 1 ] || usage
case "$1" in
    ensure)      [ "$#" -eq 1 ] || usage; ensure_key ;;
    key-path)    [ "$#" -eq 1 ] || usage; printf '%s\n' "$key_path" ;;
    public-path) [ "$#" -eq 1 ] || usage; printf '%s\n' "$public_path" ;;
    sign)        [ "$#" -eq 3 ] || usage; sign_file "$2" "$3" ;;
    verify)      [ "$#" -eq 3 ] || usage; verify_file "$2" "$3" ;;
    *) usage ;;
esac
