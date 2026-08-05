#!/usr/bin/env bash
#
# install-cloudcli-mac.sh
#
# Installs Node.js (if it isn't already installed) and @cloudcli-ai/cloudcli
#
# Usage (download and run directly):
#   curl -fsSL <raw-url-of-this-script> | bash
#
# With options, note the `-s --` that piping into bash requires:
#   curl -fsSL <raw-url-of-this-script> | bash -s -- --cacert /path/to/ca.pem
#   curl -fsSL <raw-url-of-this-script> | bash -s -- --insecure
#
# or download it first and run locally:
#   chmod +x install-cloudcli-mac.sh
#   ./install-cloudcli-mac.sh
#
set -euo pipefail

CLOUDCLI_PKG="@cloudcli-ai/cloudcli"
NODE_DIST_URL="https://nodejs.org/dist"
NODE_INDEX_URL="https://nodejs.org/dist/index.tab"
NODE_DOWNLOAD_PAGE="https://nodejs.org/en/download"

log()  { printf '\n\033[1;34m[cloudcli-installer]\033[0m %s\n' "$1"; }
warn() { printf '\n\033[1;33m[cloudcli-installer] WARNING:\033[0m %s\n' "$1" >&2; }
err()  { printf '\n\033[1;31m[cloudcli-installer] ERROR:\033[0m %s\n' "$1" >&2; }

usage() {
    cat >&2 <<'EOF'

Usage: install-cloudcli-mac.sh [--insecure | --cacert <path-to-ca.pem>]

  --cacert <path>   Verify TLS against an extra root CA in PEM form, such as a
                    corporate TLS-inspection root. Also handed to npm through
                    NODE_EXTRA_CA_CERTS. This is the preferred option.
  --insecure, -k    Skip TLS verification entirely for every download. Only for
                    a network you trust; nothing downloaded can be authenticated.

Both can also be set through the CLOUDCLI_INSECURE and CLOUDCLI_CACERT
environment variables, which is easier when piping this script into bash.
EOF
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
insecure=0
ca_file=""

while [ $# -gt 0 ]; do
    case "$1" in
        --insecure|-k)
            insecure=1
            shift
            ;;
        --cacert)
            if [ $# -lt 2 ]; then
                err "--cacert requires a path."
                usage
                exit 1
            fi
            ca_file="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# `curl ... | bash` cannot forward arguments without `-s --`, so allow the env vars too.
if [ -n "${CLOUDCLI_INSECURE:-}" ]; then insecure=1; fi
if [ -z "$ca_file" ]; then ca_file="${CLOUDCLI_CACERT:-}"; fi

if [ -n "$ca_file" ] && [ "$insecure" = 1 ]; then
    warn "Both --cacert and --insecure were given. Using --cacert and keeping verification on."
    insecure=0
fi
if [ -n "$ca_file" ] && [ ! -f "$ca_file" ]; then
    err "CA file not found: $ca_file"
    exit 1
fi

# curl verifies against the system trust store by default; --cacert points it at an
# extra root instead, and --insecure turns verification off entirely. Node keeps its
# own CA list and ignores the system store, so npm has to be told separately.
curl_tls=()
if [ -n "$ca_file" ]; then
    curl_tls=(--cacert "$ca_file")
    export NODE_EXTRA_CA_CERTS="$ca_file"
fi
if [ "$insecure" = 1 ]; then
    curl_tls=(--insecure)
    export NODE_TLS_REJECT_UNAUTHORIZED=0
fi

# bash 3.2 (the /bin/bash macOS ships) treats "${arr[@]}" on an empty array as an unbound
# variable under `set -u`, so every expansion of these arrays needs the +"..." guard.
fetch() { curl ${curl_tls[@]+"${curl_tls[@]}"} -fsSL "$@"; }

tls_hint() {
    warn "That may be a TLS trust failure rather than a network failure."
    warn "If a proxy inspects TLS here, re-run with: --cacert /path/to/proxy-root-ca.pem"
    warn "npm keeps its own CA list, so it needs NODE_EXTRA_CA_CERTS set to that same file."
    warn "Or, accepting that nothing gets verified, re-run with: --insecure"
}

if [ "$insecure" = 1 ]; then
    warn "--insecure: TLS certificate verification is DISABLED for every download below."
    warn "Anything on the network path can substitute what gets downloaded and then run."
    warn "Prefer --cacert with your proxy's root CA. Continuing in 5 seconds..."
    sleep 5
fi
if [ -n "$ca_file" ]; then
    log "Verifying TLS against extra CA: $ca_file"
fi

# ---------------------------------------------------------------------------
# Node.js
# ---------------------------------------------------------------------------

# Look for Homebrew even if it isn't on PATH yet in this shell (fresh installs of Homebrew
# itself often aren't picked up until a new terminal session starts).
find_brew() {
    if command -v brew >/dev/null 2>&1; then
        command -v brew
        return 0
    fi
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

install_node_via_brew() {
    local brew_bin="$1"
    log "Installing Node.js via Homebrew..."
    "$brew_bin" install node
}

# index.tab is newest-first and tab separated: column 1 is the version and column 10 is
# the LTS codename, which is "-" for non-LTS releases. So the first row whose column 10
# is not "-" is the current LTS. (https://nodejs.org/dist/latest-lts/, which this script
# used to scrape, now returns 404, which made this whole fallback path fail.)
#
# awk is fed by a here-string rather than a pipe on purpose: its `exit` closes the input
# after the first match, which SIGPIPEs whatever is writing and makes the whole pipeline
# return 141 under `set -o pipefail`. A here-string has no writer to kill.
latest_lts_version() {
    local index
    index=$(fetch "$NODE_INDEX_URL") || return 1
    awk 'NR>1 && $10 != "-" { print $1; exit }' <<< "$index"
}

install_node_via_pkg() {
    log "Homebrew not found. Downloading the official Node.js installer from nodejs.org..."

    local version
    version=$(latest_lts_version || true)
    if [ -z "$version" ]; then
        err "Could not determine the latest Node.js LTS version from $NODE_INDEX_URL."
        tls_hint
        err "Please install Node.js manually from $NODE_DOWNLOAD_PAGE and re-run this script."
        exit 1
    fi

    # The macOS .pkg is a universal binary (Intel + Apple Silicon), so no arch selection.
    local pkg_name="node-${version}.pkg"
    local pkg_url="${NODE_DIST_URL}/${version}/${pkg_name}"

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' EXIT
    local tmp_pkg="$tmp_dir/$pkg_name"

    log "Downloading $pkg_name..."
    if ! fetch "$pkg_url" -o "$tmp_pkg"; then
        err "Failed to download $pkg_url."
        tls_hint
        err "Please install Node.js manually from $NODE_DOWNLOAD_PAGE and re-run this script."
        exit 1
    fi

    log "Installing Node.js (you may be asked for your password)..."
    sudo installer -pkg "$tmp_pkg" -target /
}

if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    log "Node.js is already installed ($(node -v)). Skipping Node.js installation."
else
    log "Node.js was not found on this machine."
    if brew_bin=$(find_brew); then
        install_node_via_brew "$brew_bin"
    else
        install_node_via_pkg
    fi

    # Make sure `node`/`npm` are on PATH for the rest of this script, even on a fresh install.
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    hash -r

    if ! command -v node >/dev/null 2>&1; then
        err "Node.js installation finished, but 'node' is still not on PATH."
        err "Please close and reopen your terminal, then re-run this script."
        exit 1
    fi
    log "Node.js installed successfully ($(node -v))."
fi

# ---------------------------------------------------------------------------
# cloudcli
# ---------------------------------------------------------------------------
npm_opts=()
if [ "$insecure" = 1 ]; then
    npm_opts=(--strict-ssl=false)
fi

log "Installing ${CLOUDCLI_PKG} globally via npm..."
if ! npm install -g "$CLOUDCLI_PKG" ${npm_opts[@]+"${npm_opts[@]}"}; then
    err "npm install -g ${CLOUDCLI_PKG} failed."
    tls_hint
    exit 1
fi

log "Done! ${CLOUDCLI_PKG} is installed."
if [ "$insecure" = 1 ]; then
    warn "Reminder: this run skipped TLS verification. Nothing was verified as authentic."
fi
if [ -n "$ca_file" ]; then
    log "Tip: export NODE_EXTRA_CA_CERTS=$ca_file in your shell profile so npm keeps working."
fi
