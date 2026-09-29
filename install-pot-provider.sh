#!/bin/bash
# Installs the bgutil PO token provider, which is what lets YouTube serve its
# audio-only formats instead of answering 403 to them. With it, an MP3 downloads
# ~180MB of audio rather than ~1GB of video it immediately throws away.
#
# Two pieces, both third-party, from github.com/Brainicism/bgutil-ytdlp-pot-provider:
#
#   1. a yt-dlp plugin  -> ~/.config/yt-dlp/plugins/
#   2. a Node generator -> ~/Library/Application Support/EasyDL/pot-provider/
#
# The plugin goes in yt-dlp's own plugin folder rather than being pip-installed,
# because this machine's yt-dlp is a Homebrew venv that `brew upgrade` replaces.
#
# Script mode is used, not the HTTP server: nothing runs in the background, there
# is no port to collide, and nothing needs restarting after a reboot.
#
#   ./install-pot-provider.sh            install or update
#   ./install-pot-provider.sh --remove   take it all back out
set -euo pipefail

VERSION="2.0.0"
REPO="https://github.com/Brainicism/bgutil-ytdlp-pot-provider"

# Pinned by content, not by name. A git tag is a movable label: whoever controls the
# upstream repository can re-point 2.0.0 at a different commit at any time, and a
# release asset can be replaced in place. A commit id and a file hash cannot be
# forged. Bump these together when you deliberately upgrade, after reading the diff.
COMMIT="37169ee2656e08c5c2e5dc9df4c598c0cb4c88a8"
PLUGIN_SHA256="bce874dfa25896c2798e0f4f8147b7b22e785479eb1e459ab232bf2506c95016"
HOME_DIR="$HOME/Library/Application Support/EasyDL/pot-provider"
PLUGIN_DIR="$HOME/.config/yt-dlp/plugins/bgutil-ytdlp-pot-provider"

if [ "${1:-}" = "--remove" ]; then
  rm -rf "$HOME_DIR" "$PLUGIN_DIR"
  echo "Removed the provider and the plugin. EasyDL falls back to the progressive"
  echo "stream again, which still works — it just downloads more."
  exit 0
fi

command -v node >/dev/null || { echo "Needs Node. Try: brew install node"; exit 1; }
command -v git  >/dev/null || { echo "Needs git."; exit 1; }

echo "==> Fetching the generator ($VERSION, pinned to $COMMIT)"
rm -rf "$HOME_DIR"
mkdir -p "$(dirname "$HOME_DIR")"
git clone --quiet --single-branch --branch "$VERSION" "$REPO.git" "$HOME_DIR"

GOT="$( cd "$HOME_DIR" && git rev-parse HEAD )"
if [ "$GOT" != "$COMMIT" ]; then
  echo "    REFUSING TO CONTINUE."
  echo "    Tag $VERSION now points at $GOT, not the reviewed commit $COMMIT."
  echo "    Upstream moved the tag. Read the diff before changing COMMIT in this script."
  rm -rf "$HOME_DIR"
  exit 1
fi
( cd "$HOME_DIR" && git checkout --quiet "$COMMIT" )

# npm runs install scripts from the whole dependency tree, which is arbitrary code
# execution on this Mac from packages neither of us has read. That is inherent to npm,
# not specific to this project; it is the main reason the provider is optional.
echo "==> Building it (npm ci, tsc) — this runs third-party install scripts"
( cd "$HOME_DIR/server" && npm ci --silent && npx tsc )

echo "==> Installing the yt-dlp plugin"
rm -rf "$PLUGIN_DIR"; mkdir -p "$PLUGIN_DIR"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/p.zip" "$REPO/releases/download/$VERSION/bgutil-ytdlp-pot-provider.zip"

# yt-dlp imports and runs this Python on every single invocation, so verify the bytes
# before they land anywhere near the plugin folder.
GOT_SHA="$( shasum -a 256 "$TMP/p.zip" | cut -d" " -f1 )"
if [ "$GOT_SHA" != "$PLUGIN_SHA256" ]; then
  echo "    REFUSING TO INSTALL."
  echo "    Plugin archive does not match the reviewed copy."
  echo "      expected $PLUGIN_SHA256"
  echo "      got      $GOT_SHA"
  rm -rf "$PLUGIN_DIR"
  exit 1
fi
unzip -q -o "$TMP/p.zip" -d "$PLUGIN_DIR"

echo "==> Checking yt-dlp picks it up"
# Deliberately offline, against a URL that cannot be extracted: yt-dlp prints its
# plugin directories at startup, before it touches the network. The obvious check —
# piping a real YouTube extraction into grep — needs cookies to get far enough, and
# under "set -o pipefail" it reports failure from yt-dlp's own non-zero exit even
# when the grep matched.
CHECK="$( yt-dlp --ignore-config -v --simulate "https://example.invalid/none" 2>&1 || true )"
if echo "$CHECK" | grep -q "Plugin directories:.*bgutil"; then
  echo "    yt-dlp loads the plugin."
else
  echo "    WARNING: yt-dlp did not load the plugin. Check $PLUGIN_DIR."
  exit 1
fi

if [ -f "$HOME_DIR/server/build/generate_once.js" ] || [ -f "$HOME_DIR/server/src/generate_once.ts" ]; then
  echo "    Generator built."
else
  echo "    WARNING: the generator did not build. Check the npm output above."
  exit 1
fi

echo ""
echo "Done. EasyDL finds this automatically — nothing to configure."
echo "Settings ▸ Tools shows it as installed."
