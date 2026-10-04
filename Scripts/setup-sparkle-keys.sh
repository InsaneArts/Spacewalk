#!/bin/bash
#
# Prints the Sparkle EdDSA public key this Mac signs updates with, generating the key pair on
# first run, and checks that version.env carries the same key.
#
#   Scripts/setup-sparkle-keys.sh          # show the public key
#   Scripts/setup-sparkle-keys.sh --export # write the private key to a file
#
# Sparkle keeps the private key in the login Keychain, associated with your user account, and one
# key covers every app you ship. The public half belongs in version.env as SPARKLE_PUBLIC_KEY and
# is safe to commit.
#
# Losing the private key means existing installs can never update again: they only trust updates
# signed by the key their copy was built with. Export it once and keep it somewhere safe.

set -euo pipefail
umask 077

fail() { echo "error: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/version.env"
TOOLS="${SPARKLE_BIN:-$REPO_ROOT/.build/artifacts/sparkle/Sparkle/bin}/generate_keys"
[[ -x "$TOOLS" ]] || fail "Sparkle's tools are missing. Run 'swift build' once so SwiftPM fetches the package."

if [[ "${1:-}" == "--export" ]]; then
  OUT="$HOME/spacewalk-sparkle-private-key.txt"
  [[ -e "$OUT" ]] && fail "$OUT already exists; move it aside first"
  "$TOOLS" -x "$OUT"
  chmod 600 "$OUT"
  echo "Private key written to $OUT"
  echo "Store it in your password manager, then delete the file."
  exit 0
fi

# -p prints the public key and never overwrites an existing private key.
PUBLIC_KEY="$("$TOOLS" -p 2>/dev/null || true)"
if [[ -z "$PUBLIC_KEY" ]]; then
  echo "No signing key found. Generating one in the login Keychain…"
  "$TOOLS"
  PUBLIC_KEY="$("$TOOLS" -p)"
fi
echo "Public key: $PUBLIC_KEY"

IN_ENV="$(sed -n 's/^SPARKLE_PUBLIC_KEY=//p' "$ENV_FILE" | head -1)"
if [[ "$IN_ENV" == "$PUBLIC_KEY" ]]; then
  echo "version.env already carries this key."
else
  echo
  echo "version.env has: ${IN_ENV:-<nothing>}"
  echo "Update it so the two match, or updates will fail verification:"
  echo "  sed -i '' 's|^SPARKLE_PUBLIC_KEY=.*|SPARKLE_PUBLIC_KEY=$PUBLIC_KEY|' version.env"
  exit 1
fi
