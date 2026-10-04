#!/bin/bash
#
# Spacewalk installer.
#
#   curl -fsSL https://raw.githubusercontent.com/tornikegomareli/Spacewalk/main/install.sh | bash
#
# Downloads the latest notarized release from GitHub, checks that Apple's notary service
# accepted it, copies Spacewalk.app into /Applications, links the `spacewalk` command into
# ~/.local/bin and launches the app. Nothing is downloaded from anywhere but
# github.com/tornikegomareli/Spacewalk, and nothing needs sudo.
#
#   --version 0.2.0   install that release instead of the latest
#   --no-launch       install without opening the app
#   --uninstall       remove the app and the command (settings in ~/.config/spacewalk stay)
#
# To build from source instead, clone the repository and run Scripts/install-from-source.sh.

set -euo pipefail

REPO="tornikegomareli/Spacewalk"
APP_NAME="Spacewalk"
CLI_LINK="${SPACEWALK_CLI_LINK:-$HOME/.local/bin/spacewalk}"
VERSION=""
LAUNCH=true
UNINSTALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --no-launch) LAUNCH=false; shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    -h|--help) sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

say() { printf '\033[1m%s\033[0m\n' "$1"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# /Applications when this user may write there, which an administrator can; ~/Applications
# otherwise. Either way no sudo.
if [[ -w /Applications ]]; then APP_DIR=/Applications; else APP_DIR="$HOME/Applications"; fi
DEST="$APP_DIR/$APP_NAME.app"

if $UNINSTALL; then
  say "Removing $APP_NAME"
  osascript -e "tell application id \"dev.tgomareli.spacewalk\" to quit" >/dev/null 2>&1 || true
  sleep 0.5
  for dir in /Applications "$HOME/Applications"; do
    [[ -d "$dir/$APP_NAME.app" ]] && rm -rf "$dir/$APP_NAME.app" && echo "  removed $dir/$APP_NAME.app"
  done
  [[ -L "$CLI_LINK" ]] && rm -f "$CLI_LINK" && echo "  removed $CLI_LINK"
  echo "  kept ~/.config/spacewalk (your settings); delete it yourself if you want a clean slate"
  exit 0
fi

[[ "$(uname -s)" == "Darwin" ]] || fail "Spacewalk runs on macOS only"
[[ "$(uname -m)" == "arm64" ]] || fail "Spacewalk ships for Apple Silicon only"
OS_VERSION="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"
OS_MINOR="$(cut -d. -f2 <<<"$OS_VERSION.0")"
if (( OS_MAJOR < 26 || (OS_MAJOR == 26 && OS_MINOR < 6) )); then
  fail "macOS 26.6 or newer is required (this Mac runs $OS_VERSION). 26.0 to 26.5 blank the screen on a zero-travel Space switch."
fi

if [[ -n "$VERSION" ]]; then
  URL="https://github.com/$REPO/releases/download/v${VERSION#v}/$APP_NAME.dmg"
else
  URL="https://github.com/$REPO/releases/latest/download/$APP_NAME.dmg"
fi

TMP="$(mktemp -d -t spacewalk-install)"
MOUNT="$TMP/mnt"
cleanup() {
  [[ -d "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

say "Downloading $APP_NAME ${VERSION:-(latest)}"
curl -fL --progress-bar -o "$TMP/$APP_NAME.dmg" "$URL" || fail "download failed: $URL"

# The DMG is signed with the developer's Developer ID and notarized by Apple; Gatekeeper's own
# assessment is the check. A build that fails it is not installed.
if ! spctl -a -t open --context context:primary-signature "$TMP/$APP_NAME.dmg" >/dev/null 2>&1; then
  fail "Apple's notarization check rejected the download. Not installing. Please report this at https://github.com/$REPO/issues"
fi
echo "  notarization verified"

say "Installing to $APP_DIR"
mkdir -p "$MOUNT"
hdiutil attach "$TMP/$APP_NAME.dmg" -nobrowse -readonly -quiet -mountpoint "$MOUNT" || fail "could not mount the disk image"
[[ -d "$MOUNT/$APP_NAME.app" ]] || fail "the disk image holds no $APP_NAME.app"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  osascript -e "tell application id \"dev.tgomareli.spacewalk\" to quit" >/dev/null 2>&1 || pkill -x "$APP_NAME" || true
  sleep 0.5
fi
mkdir -p "$APP_DIR"
rm -rf "$DEST"
# ditto keeps the bundle's symlinks and signatures intact; cp -R can break the Sparkle framework.
ditto "$MOUNT/$APP_NAME.app" "$DEST"
hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
rmdir "$MOUNT" 2>/dev/null || true
echo "  $DEST"

mkdir -p "$(dirname "$CLI_LINK")"
ln -sfn "$DEST/Contents/MacOS/spacewalk-cli" "$CLI_LINK"
echo "  $CLI_LINK -> spacewalk-cli"
case ":$PATH:" in
  *":$(dirname "$CLI_LINK"):"*) ;;
  *) echo "  add $(dirname "$CLI_LINK") to your PATH to use the spacewalk command" ;;
esac

if $LAUNCH; then
  say "Launching"
  open "$DEST"
  echo "  Spacewalk asks for Screen Recording (to see your Spaces) and Accessibility (to switch"
  echo "  them) on first launch. Its menu bar item opens Settings."
fi
say "Done"
