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

echo "==> Fetching the generator ($VERSION)"
rm -rf "$HOME_DIR"
mkdir -p "$(dirname "$HOME_DIR")"
git clone --quiet --single-branch --branch "$VERSION" --depth 1 "$REPO.git" "$HOME_DIR"

echo "==> Building it (npm ci, tsc)"
( cd "$HOME_DIR/server" && npm ci --silent && npx tsc )

echo "==> Installing the yt-dlp plugin"
rm -rf "$PLUGIN_DIR"; mkdir -p "$PLUGIN_DIR"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -sL -o "$TMP/p.zip" "$REPO/releases/download/$VERSION/bgutil-ytdlp-pot-provider.zip"
unzip -q -o "$TMP/p.zip" -d "$PLUGIN_DIR"

echo "==> Checking yt-dlp picks it up"
if yt-dlp --ignore-config -v --simulate "https://www.youtube.com/watch?v=jNQXAC9IVRw" 2>&1 \
   | grep -q "PO Token Providers:.*bgutil"; then
  echo "    yt-dlp lists the provider."
else
  echo "    WARNING: yt-dlp did not list the provider. Check ~/.config/yt-dlp/plugins/."
  exit 1
fi

echo ""
echo "Done. EasyDL finds this automatically — nothing to configure."
echo "Settings ▸ Tools shows it as installed."
