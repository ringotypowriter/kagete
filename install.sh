#!/bin/bash
# install.sh — one-liner installer for kagete
#
#   curl -fsSL https://raw.githubusercontent.com/ringotypowriter/kagete/main/install.sh | bash
#
# Installs the latest release binary to ~/.local/bin. Override the destination
# with KAGETE_INSTALL_DIR=/somewhere/else.

set -euo pipefail

REPO="ringotypowriter/kagete"
INSTALL_DIR="${KAGETE_INSTALL_DIR:-$HOME/.local/bin}"

# --- sanity checks ---------------------------------------------------------

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "✗ kagete is macOS only (got $(uname -s))" >&2
    exit 1
fi

ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" ]]; then
    echo "✗ unsupported CPU arch: $ARCH (only arm64 / Apple Silicon supported)" >&2
    exit 1
fi

for dep in curl tar shasum xattr; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "✗ missing required command: $dep" >&2
        exit 1
    fi
done

# --- discover latest release ----------------------------------------------
# Follow the /releases/latest redirect to /releases/tag/<TAG> — skips the
# GitHub API (60 req/hour unauth limit per IP), just uses HTTP redirects.

TAG_URL="$(curl -sSLo /dev/null -w '%{url_effective}' \
    "https://github.com/$REPO/releases/latest")"
TAG="${TAG_URL##*/}"

if [[ -z "$TAG" || "$TAG" == "latest" ]]; then
    echo "✗ could not determine latest release tag (is there a published release?)" >&2
    exit 1
fi

ASSET="kagete-${TAG}-macos-${ARCH}.tar.gz"
URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"

echo "→ kagete $TAG ($ARCH)"

# --- download + verify ----------------------------------------------------

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ downloading $ASSET"
curl -fsSL -o "$TMP/$ASSET"          "$URL"
curl -fsSL -o "$TMP/$ASSET.sha256"   "$URL.sha256"

echo "→ verifying checksum"
( cd "$TMP" && shasum -a 256 -c "$ASSET.sha256" )

echo "→ extracting"
tar -xzf "$TMP/$ASSET" -C "$TMP"

# --- install --------------------------------------------------------------

mkdir -p "$INSTALL_DIR"
mv -f "$TMP/kagete" "$INSTALL_DIR/kagete"
chmod +x "$INSTALL_DIR/kagete"

echo "→ clearing Gatekeeper quarantine flag"
xattr -dr com.apple.quarantine "$INSTALL_DIR/kagete" 2>/dev/null || true

echo ""
echo "✓ kagete $TAG installed to $INSTALL_DIR/kagete"

# --- PATH check -----------------------------------------------------------

if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo ""
    echo "⚠  $INSTALL_DIR is not on your PATH."
    echo "   Add one of the following to your shell rc:"
    echo ""
    echo "     bash/zsh: export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo "     fish:     fish_add_path \$HOME/.local/bin"
fi

echo ""
echo "Next: run \`kagete doctor --prompt\` to grant Accessibility + Screen Recording."
