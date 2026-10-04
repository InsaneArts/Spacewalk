#!/usr/bin/env bash
# Build from source, install to /Applications, link the CLI, relaunch.
# End users: install.sh at the repository root downloads a signed release instead.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME=Spacewalk
DEST=/Applications/${APP_NAME}.app
CLI_LINK=${CLI_LINK:-$HOME/.local/bin/spacewalk}

"$ROOT/Scripts/package_app.sh" "${1:-release}"

pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.3
rm -rf "$DEST"
cp -R "$ROOT/${APP_NAME}.app" "$DEST"
mkdir -p "$(dirname "$CLI_LINK")"
ln -sf "$DEST/Contents/MacOS/spacewalk-cli" "$CLI_LINK"
open "$DEST"
for _ in {1..10}; do
  if pgrep -x "$APP_NAME" >/dev/null; then echo "OK: $APP_NAME running from $DEST (cli: $CLI_LINK)"; exit 0; fi
  sleep 0.3
done
echo "ERROR: $APP_NAME did not start" >&2; exit 1
