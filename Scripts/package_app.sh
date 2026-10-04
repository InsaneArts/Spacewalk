#!/usr/bin/env bash
# Build with SwiftPM, assemble Spacewalk.app with Sparkle embedded, and sign it.
#
#   Scripts/package_app.sh [release|debug]
#
# Signing:
#   APP_IDENTITY        certificate to sign with; falls back to ad-hoc when it is not in the
#                       keychain, so anyone can build. A stable identity keeps the Screen
#                       Recording grant across rebuilds; ad-hoc signatures lose it every build.
#   SIGNING_MODE=adhoc  force ad-hoc (CI)
#   CODESIGN_TIMESTAMP=1  secure timestamps, needed for notarization (Scripts/release.sh)
#   MARKETING_VERSION / BUILD_NUMBER  override version.env for one build
set -euo pipefail

CONF=${1:-release}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

APP_NAME=Spacewalk
CLI_NAME=spacewalk-cli
BUNDLE_ID=${BUNDLE_ID:-dev.tgomareli.spacewalk}
# 26.0 to 26.5 blank zero-travel switches (a WindowServer bug), so the app refuses to run there.
MACOS_MIN_VERSION=26.6
APP_IDENTITY=${APP_IDENTITY:-"Apple Development: Tornike Gomareli (PVRMHF9AJP)"}

VERSION_OVERRIDE=${MARKETING_VERSION:-}
BUILD_OVERRIDE=${BUILD_NUMBER:-}
source "$ROOT/version.env"
MARKETING_VERSION=${VERSION_OVERRIDE:-$MARKETING_VERSION}
BUILD_NUMBER=${BUILD_OVERRIDE:-$BUILD_NUMBER}

swift build -c "$CONF" --product "$APP_NAME"
swift build -c "$CONF" --product "$CLI_NAME"

BIN_DIR=".build/$CONF"
APP="$ROOT/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>${MACOS_MIN_VERSION}</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>CFBundleIconFile</key><string>Spacewalk</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Tornike Gomareli. MIT License.</string>
    <!-- Sparkle: the feed on main and the public half of the EdDSA signing key (version.env). -->
    <key>SUFeedURL</key><string>${SPARKLE_FEED_URL}</string>
    <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
    <key>SUAllowsAutomaticUpdates</key><true/>
</dict>
</plist>
PLIST

cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/$CLI_NAME" "$APP/Contents/MacOS/$CLI_NAME"
chmod +x "$APP/Contents/MacOS/"*
cp "$ROOT/Resources/AppIcon/Spacewalk.icns" "$APP/Contents/Resources/Spacewalk.icns"

# SwiftPM leaves the framework next to the executable; the bundle needs it in Frameworks, and
# the executable needs an rpath that points there.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
cp -R "$BIN_DIR/Sparkle.framework" "$SPARKLE"
if ! otool -l "$APP/Contents/MacOS/$APP_NAME" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME"
fi

chmod -R u+w "$APP"
xattr -cr "$APP"

if [[ "${SIGNING_MODE:-}" == "adhoc" ]]; then
  IDENTITY="-"
elif security find-identity -v -p codesigning 2>/dev/null | grep -qF "$APP_IDENTITY"; then
  IDENTITY="$APP_IDENTITY"
else
  echo "note: '$APP_IDENTITY' is not in the keychain; signing ad-hoc (set APP_IDENTITY to change)"
  IDENTITY="-"
fi
CODESIGN_ARGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
  # Hardened runtime, as notarization requires; ad-hoc builds skip it so the embedded framework
  # passes library validation.
  CODESIGN_ARGS+=(--options runtime)
  if [[ "${CODESIGN_TIMESTAMP:-0}" == "1" ]]; then CODESIGN_ARGS+=(--timestamp); else CODESIGN_ARGS+=(--timestamp=none); fi
fi

# Sparkle ships prebuilt helpers signed ad-hoc with no team; the app can only load code signed
# with its own identity. codesign seals a bundle by hashing its contents, so this runs strictly
# inside-out: helpers, then the framework, then the executables, then the app.
for target in \
  "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
  "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
  "$SPARKLE/Versions/B/Updater.app" \
  "$SPARKLE/Versions/B/Autoupdate" \
  "$SPARKLE"; do
  [[ -e "$target" ]] || continue
  codesign "${CODESIGN_ARGS[@]}" "$target"
done
codesign "${CODESIGN_ARGS[@]}" "$APP/Contents/MacOS/$CLI_NAME"
codesign "${CODESIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Created $APP ($MARKETING_VERSION build $BUILD_NUMBER, signed: $IDENTITY)"
