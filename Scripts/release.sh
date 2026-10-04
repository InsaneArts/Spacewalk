#!/bin/bash
#
# Cuts a Spacewalk release: builds, signs with Developer ID, packages a notarized DMG, signs the
# Sparkle update, publishes a GitHub release and points the Homebrew cask at it.
#
#   Scripts/release.sh 0.2.0            # build, publish, update the cask
#   Scripts/release.sh 0.2.0 --dry-run  # build and package only, publish nothing
#
# The update-signing public key is compared against the last tagged release before anything is
# built. Changing it orphans every existing install, so a deliberate rotation has to say so:
#   Scripts/release.sh 0.3.0 --confirm-key-rotation
#
# Two copies of the same DMG ship with every release. Spacewalk-vX.Y.Z.dmg is the one people
# download, so the file in their Downloads folder says which version it is. Spacewalk.dmg is a
# byte-identical copy that keeps github.com/<repo>/releases/latest/download/Spacewalk.dmg
# resolving: the cask, install.sh and the README all use that URL.
#
# Notarization uses a notarytool keychain profile:
#   NOTARY_PROFILE   keychain profile name (default: camus-notary)
#   SKIP_NOTARIZE=1  sign and package without notarizing (local testing only)
#   SIGN_IDENTITY    Developer ID Application certificate
#   SPARKLE_BIN      directory holding generate_appcast (default: SwiftPM's artifacts)
#   TAP_REPO         checkout of tornikegomareli/homebrew-tap; the cask is copied there too so
#                    `brew install --cask tornikegomareli/tap/spacewalk` works
#                    (default: ../homebrew-tap; skipped if it is missing)

set -euo pipefail

VERSION="${1:-}"
DRY_RUN=false
CONFIRM_KEY_ROTATION=false
shift || true
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --confirm-key-rotation) CONFIRM_KEY_ROTATION=true ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "usage: Scripts/release.sh <version> [--dry-run] [--confirm-key-rotation]" >&2
  exit 1
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "version must be semver, e.g. 0.2.0 (got '$VERSION')" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

REPO="tornikegomareli/Spacewalk"
TAG="v$VERSION"
APP_NAME="Spacewalk"
BUNDLE_ID="dev.tgomareli.spacewalk"
OUT_DIR="$REPO_ROOT/.build/release-$VERSION"
APP="$REPO_ROOT/$APP_NAME.app"
STAGE_DIR="$OUT_DIR/dmg"
DMG="$OUT_DIR/$APP_NAME-$TAG.dmg"
STABLE_DMG="$OUT_DIR/$APP_NAME.dmg"
# Sparkle needs its own directory holding only the update ZIP.
SPARKLE_DIR="$OUT_DIR/sparkle"
SPARKLE_ZIP="$SPARKLE_DIR/$APP_NAME-$TAG.zip"
APPCAST="$REPO_ROOT/appcast.xml"
# Hand-written release notes for this version, used instead of the commit log.
CURATED_NOTES="$REPO_ROOT/docs/release-notes/$VERSION.md"
CASK="$REPO_ROOT/Casks/spacewalk.rb"
TEAM_ID="539293JFA3"
NOTARY_PROFILE="${NOTARY_PROFILE:-camus-notary}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Techzy LLC ($TEAM_ID)}"
SPARKLE_BIN="${SPARKLE_BIN:-$REPO_ROOT/.build/artifacts/sparkle/Sparkle/bin}"
TAP_REPO="${TAP_REPO:-$REPO_ROOT/../homebrew-tap}"

step() { printf '\n\033[1;33m▸ %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- preflight

step "Preflight"
command -v swift >/dev/null || fail "swift not found"
command -v hdiutil >/dev/null || fail "hdiutil not found"
if ! $DRY_RUN; then
  command -v gh >/dev/null || fail "gh not found. Install the GitHub CLI"
  gh auth status >/dev/null 2>&1 || fail "gh is not authenticated. Run 'gh auth login'"
fi
security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY" \
  || fail "signing identity not in the keychain: $SIGN_IDENTITY"

# Check the notary credentials before spending minutes on a build.
if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
  echo "  SKIP_NOTARIZE=1: the DMG will be signed but not notarized"
elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "  notary profile '$NOTARY_PROFILE' ready"
else
  fail "notarytool profile '$NOTARY_PROFILE' not found. Store it once with:
    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\
      --apple-id <apple-id> --team-id $TEAM_ID --password <app-specific-password>
  or re-run with SKIP_NOTARIZE=1 to skip notarization."
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "main" ]] && ! $DRY_RUN; then
  fail "releases are cut from main (on '$CURRENT_BRANCH')"
fi
if [[ -n "$(git status --porcelain)" ]] && ! $DRY_RUN; then
  fail "working tree is dirty. Commit or stash first"
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
  fail "tag $TAG already exists"
fi
echo "  version $VERSION, tag $TAG, branch $CURRENT_BRANCH"

# The public key every installed copy checks updates against. If it changes, those copies stop
# trusting anything signed with the new one, and a key swapped in by someone else would be
# trusted by every install from here on. Neither is something to discover after publishing.
read_public_key() { sed -n 's/^SPARKLE_PUBLIC_KEY=//p' <<<"$1" | head -1; }
CURRENT_KEY="$(read_public_key "$(cat version.env)")"
[[ -n "$CURRENT_KEY" ]] || fail "version.env has no SPARKLE_PUBLIC_KEY"

PREVIOUS_TAG="$(git tag --list 'v*' --sort=-v:refname | head -1)"
if [[ -z "$PREVIOUS_TAG" ]]; then
  echo "  no previous tag to compare the update key against (first release)"
elif PREVIOUS_ENV="$(git show "$PREVIOUS_TAG:version.env" 2>/dev/null)"; then
  PREVIOUS_KEY="$(read_public_key "$PREVIOUS_ENV")"
  if [[ -z "$PREVIOUS_KEY" ]]; then
    echo "  $PREVIOUS_TAG carried no SPARKLE_PUBLIC_KEY; nothing to compare"
  elif [[ "$CURRENT_KEY" == "$PREVIOUS_KEY" ]]; then
    echo "  update key unchanged since $PREVIOUS_TAG"
  elif $CONFIRM_KEY_ROTATION; then
    echo "  update key CHANGED since $PREVIOUS_TAG, confirmed by flag"
    echo "    was: $PREVIOUS_KEY"
    echo "    now: $CURRENT_KEY"
  else
    fail "SPARKLE_PUBLIC_KEY changed since $PREVIOUS_TAG.
    was: $PREVIOUS_KEY
    now: $CURRENT_KEY
  Every existing install trusts the old key and will refuse updates signed with the new one.
  If this is a deliberate rotation, re-run with --confirm-key-rotation. If it is not, find
  out who changed it."
  fi
else
  echo "  $PREVIOUS_TAG has no version.env; nothing to compare"
fi

# ------------------------------------------------------------------- tests

step "Tests"
swift test 2>&1 | tail -3
echo "  suite passed"

# ------------------------------------------------------------------- build

BUILD_NUMBER="$(git rev-list --count HEAD)"
if $DRY_RUN; then
  step "Building $VERSION ($BUILD_NUMBER) without touching version.env (dry run)"
else
  step "Setting version to $VERSION ($BUILD_NUMBER)"
  /usr/bin/sed -i '' \
    -e "s/^MARKETING_VERSION=.*$/MARKETING_VERSION=$VERSION/" \
    -e "s/^BUILD_NUMBER=.*$/BUILD_NUMBER=$BUILD_NUMBER/" \
    version.env
  grep -E "^(MARKETING_VERSION|BUILD_NUMBER)=" version.env | sed 's/^/  /'
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
MARKETING_VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" CODESIGN_TIMESTAMP=1 \
  APP_IDENTITY="$SIGN_IDENTITY" Scripts/package_app.sh release | sed 's/^/  /'
[[ -d "$APP" ]] || fail "package_app.sh produced no $APP_NAME.app"

BUILT_SHORT="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
[[ "$BUILT_SHORT" == "$VERSION" ]] || fail "the built app reports version '$BUILT_SHORT', not $VERSION"
BUILT_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist")"
[[ "$BUILT_KEY" == "$CURRENT_KEY" ]] || fail "the built app carries a different SUPublicEDKey"

# Every nested binary must carry the team and the hardened runtime, or notarization fails after
# the DMG and the notary round-trip have already been paid for. The output is captured rather
# than piped into grep -q: with pipefail set, grep exiting early kills codesign with SIGPIPE.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for nested in \
  "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
  "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
  "$SPARKLE/Versions/B/Updater.app" \
  "$SPARKLE/Versions/B/Autoupdate" \
  "$SPARKLE" \
  "$APP/Contents/MacOS/spacewalk-cli" \
  "$APP"; do
  [[ -e "$nested" ]] || continue
  INFO="$(codesign -dvv "$nested" 2>&1 || true)"
  [[ "$INFO" == *"TeamIdentifier=$TEAM_ID"* ]] || fail "$(basename "$nested") is not signed with team $TEAM_ID"
  [[ "$INFO" == *"runtime"* ]] || fail "$(basename "$nested") is missing the hardened runtime"
done
echo "  helpers, framework, CLI and app signed with $TEAM_ID"

# --------------------------------------------------------------------- dmg

step "Packaging DMG"
rm -rf "$STAGE_DIR" "$DMG"
mkdir -p "$STAGE_DIR"
cp -R "$APP" "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"
# hdiutil reports "Resource busy" if the freshly copied bundle is still being indexed.
for attempt in 1 2 3 4 5; do
  if hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG" >/dev/null 2>&1; then
    break
  fi
  [[ $attempt == 5 ]] && fail "hdiutil could not create the DMG"
  echo "  hdiutil busy, retrying ($attempt)"
  sleep 3
done
hdiutil verify "$DMG" >/dev/null 2>&1 || fail "the DMG failed verification"

# Sign the container too, so Gatekeeper can vouch for the DMG and not only the app inside. This
# must happen BEFORE notarization: signing a stapled DMG rewrites the file and drops the ticket.
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
echo "  container signed"

# ------------------------------------------------------------- notarization

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
  step "Notarization skipped (SKIP_NOTARIZE=1)"
  echo "  This DMG is signed but NOT notarized: Gatekeeper will refuse to open it."
else
  step "Notarizing with profile '$NOTARY_PROFILE'"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | sed 's/^/  /'
  echo "  notarized and stapled"
fi

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "  $DMG ($(du -h "$DMG" | cut -f1))"
echo "  sha256 $SHA"

# Copied after signing, notarizing and stapling, so the stable-URL asset is the same bytes with
# the same ticket. The cask's checksum covers both.
cp "$DMG" "$STABLE_DMG"
echo "  $STABLE_DMG (copy for the latest-download URL)"

# ----------------------------------------------------------------- sparkle

# Sparkle updates from a ZIP, not the DMG: it unpacks without mounting anything. Notarizing the
# DMG notarized the app inside it, so the app can be stapled straight from Apple's records.
step "Packaging the Sparkle update"
if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  xcrun stapler staple "$APP" && echo "  app stapled"
fi

rm -rf "$SPARKLE_DIR"
mkdir -p "$SPARKLE_DIR"
# ditto keeps the bundle's symlinks and resource forks intact; `zip` does not, and a mangled
# bundle fails its signature check after the update lands.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$SPARKLE_ZIP"
echo "  $(basename "$SPARKLE_ZIP") ($(du -h "$SPARKLE_ZIP" | cut -f1))"

[[ -x "$SPARKLE_BIN/generate_appcast" ]] || fail "generate_appcast not found in $SPARKLE_BIN (run swift build once)"

# The private key lives in the login Keychain (Scripts/setup-sparkle-keys.sh), so the tool finds
# it without a key file on disk. The Keychain prompts for access the first time a new copy of
# the tool asks; choose Always Allow so later releases run unattended.
# Only the ZIP is in SPARKLE_DIR: generate_appcast refuses two archives with the same version.
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO" \
  --full-release-notes-url "https://github.com/$REPO/releases" \
  --maximum-versions 5 \
  -o "$APPCAST" \
  "$SPARKLE_DIR"

[[ -s "$APPCAST" ]] || fail "generate_appcast produced no appcast"
grep -q "sparkle:edSignature" "$APPCAST" || fail "the appcast has no EdDSA signature"
grep -q "$TAG/" "$APPCAST" || fail "the appcast does not point at $TAG"
echo "  appcast written, signature present"

# -------------------------------------------------------------------- cask

step "Updating the Homebrew cask"
[[ -f "$CASK" ]] || fail "missing $CASK"
/usr/bin/sed -i '' \
  -e "s/^  version \".*\"$/  version \"$VERSION\"/" \
  -e "s/^  sha256 \".*\"$/  sha256 \"$SHA\"/" \
  "$CASK"
grep -E "^  (version|sha256)" "$CASK" | sed 's/^/  /'

if $DRY_RUN; then
  step "Dry run: nothing published"
  echo "  DMG:     $DMG"
  echo "  copy:    $STABLE_DMG"
  echo "  ZIP:     $SPARKLE_ZIP"
  echo "  appcast: $APPCAST (modified, uncommitted)"
  echo "  cask:    $CASK (modified, uncommitted)"
  echo "  revert with: git checkout -- appcast.xml Casks/spacewalk.rb"
  exit 0
fi

# ----------------------------------------------------------------- publish

step "Committing and tagging"
git add version.env appcast.xml "$CASK"
if git diff --cached --quiet; then
  echo "  nothing staged; version, appcast and cask already match"
else
  git commit -q -m "Release $VERSION"
  echo "  committed $(git diff --name-only HEAD~1 HEAD | tr '\n' ' ')"
fi
git tag -a "$TAG" -m "$APP_NAME $VERSION"
git push -q origin main
git push -q origin "$TAG"
echo "  pushed $TAG"

step "Publishing the GitHub release"
NOTES_FILE="$OUT_DIR/notes.md"
PREV_TAG="$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)"
{
  echo "## Install"
  echo
  echo '```sh'
  echo "brew install --cask tornikegomareli/tap/spacewalk"
  echo '```'
  echo
  echo "or"
  echo
  echo '```sh'
  echo "curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash"
  echo '```'
  echo
  echo "Or download **$APP_NAME.dmg** below. Requires macOS 26.6 on Apple Silicon."
  echo
  echo "## Changes"
  echo
  # Written notes win when they exist: a commit log says what changed in the code, which is
  # not the same as what changed for the person reading it.
  if [[ -f "$CURATED_NOTES" ]]; then
    cat "$CURATED_NOTES"
  elif [[ -n "$PREV_TAG" ]]; then
    git log --no-merges --pretty='- %s' "$PREV_TAG..$TAG"
  else
    git log --no-merges --pretty='- %s' -20 "$TAG"
  fi
} > "$NOTES_FILE"

# The ZIP ships alongside the DMG because the appcast's enclosure URL points at it. appcast.xml
# goes up too, as the immutable copy of what this tag published.
gh release create "$TAG" "$DMG" "$STABLE_DMG" "$SPARKLE_ZIP" "$APPCAST" \
  --title "$APP_NAME $VERSION" \
  --notes-file "$NOTES_FILE"

step "Verifying the update feed"
FEED="https://raw.githubusercontent.com/$REPO/main/appcast.xml"
if curl -fsS "$FEED" | grep -q "$TAG"; then
  echo "  $FEED serves $TAG"
else
  echo "  WARNING: $FEED does not mention $TAG yet."
  echo "  raw.githubusercontent.com caches for a few minutes, and a private repository never"
  echo "  serves it. Re-check before announcing."
fi
ENCLOSURE="$(grep -o 'url="[^"]*\.zip"' "$APPCAST" | head -1 | cut -d'"' -f2)"
if [[ -n "$ENCLOSURE" ]] && curl -fsSI "$ENCLOSURE" >/dev/null 2>&1; then
  echo "  enclosure reachable"
else
  echo "  WARNING: the appcast enclosure is not reachable: $ENCLOSURE"
fi

# The public tap carries a copy of the cask, so the install line needs no URL. Nothing below is
# fatal: the release is already published, and a tap one version behind is worth less than a
# script that exits non-zero after doing the irreversible part.
step "Updating the public tap"
sync_tap() {
  git -C "$TAP_REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "  no tap checkout at $TAP_REPO; skipping."; return 1; }
  [[ -z "$(git -C "$TAP_REPO" status --porcelain --untracked-files=no)" ]] || { echo "  tap checkout has uncommitted changes; skipping."; return 1; }
  git -C "$TAP_REPO" pull -q --ff-only || { echo "  could not fast-forward the tap checkout; skipping."; return 1; }
  mkdir -p "$TAP_REPO/Casks"
  cp "$CASK" "$TAP_REPO/Casks/spacewalk.rb"
  git -C "$TAP_REPO" add Casks/spacewalk.rb
  if git -C "$TAP_REPO" diff --cached --quiet; then echo "  tap already carries $VERSION"; return 0; fi
  git -C "$TAP_REPO" commit -q -m "spacewalk $VERSION" && git -C "$TAP_REPO" push -q || { echo "  could not push the tap."; return 1; }
  echo "  tornikegomareli/tap now installs $VERSION"
}
if ! sync_tap; then
  echo "  To do it by hand: copy Casks/spacewalk.rb into homebrew-tap/Casks and push."
fi

step "Done"
echo "  release:  $(gh release view "$TAG" --json url -q .url)"
echo "  download: https://github.com/$REPO/releases/latest/download/$APP_NAME.dmg"
echo "  feed:     $FEED"
