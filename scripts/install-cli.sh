#!/usr/bin/env bash
# Installs the official Filen CLI release pinned by this plugin version.
#
# Run by the panel inside Omarchy's floating terminal, so every step is
# visible and nothing happens without the user confirming it.
#
# It downloads the prebuilt binary from Filen's own GitHub release
# (FilenCloudDienste/filen-cli-releases) and installs it only if its SHA-256
# equals the value pinned below. A newer CLI only ever arrives with a new
# plugin commit, which goes through the plugin's own review. No root: the
# binary goes to ~/.filen-cli/bin/filen, the same place Filen's own installer
# uses, and nothing outside that folder is touched (no shell rc edits).
set -euo pipefail

VERSION=0.2.7
BASE="https://github.com/FilenCloudDienste/filen-cli-releases/releases/download/$VERSION"
DEST_DIR="$HOME/.filen-cli/bin"
DEST="$DEST_DIR/filen"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

case "$(uname -m)" in
  x86_64)
    ASSET="filen-cli-$VERSION-x86_64-unknown-linux-gnu"
    SHA256=d05c3a4a7585cbbfe936da7a479738982928df49576bd2374c8b608b4d889189
    ;;
  aarch64 | arm64)
    ASSET="filen-cli-$VERSION-aarch64-unknown-linux-gnu"
    SHA256=ecda8d36056e51d8894c703400f745baa07075419c3cdc058164cc277088b2c7
    ;;
  *) fail "No official Filen CLI build for $(uname -m). Nothing changed." ;;
esac

if [[ -x "$DEST" ]] && [[ "$("$DEST" --version 2>/dev/null)" == "Filen CLI $VERSION" ]]; then
  say "Filen CLI $VERSION is already installed at ~/.filen-cli/bin/filen."
  exit 0
fi

say "Install the official Filen CLI $VERSION"
printf '  from   %s\n' "github.com/FilenCloudDienste/filen-cli-releases"
printf '  file   %s\n' "$ASSET"
printf '  sha256 %s\n' "$SHA256"
printf '  to     %s\n' "~/.filen-cli/bin/filen"
printf '\nThe download is checked against the pinned SHA-256 before anything is\ninstalled. No admin password is needed.\n'

read -r -p $'\nInstall now? [Y/n] ' answer
[[ -z "$answer" || "$answer" =~ ^[Yy] ]] || fail "Cancelled. Nothing changed."

command -v curl >/dev/null || fail "curl is missing. Nothing changed."
command -v sha256sum >/dev/null || fail "sha256sum is missing. Nothing changed."

mkdir -p -- "$DEST_DIR"
tmp=$(mktemp "$DEST_DIR/.filen.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT

say "Downloading…"
curl --proto '=https' --tlsv1.2 -fL --progress-bar -o "$tmp" "$BASE/$ASSET" \
  || fail "Download failed. Nothing changed."

say "Verifying…"
echo "$SHA256  $tmp" | sha256sum -c --status \
  || fail "Checksum mismatch: the download is not the pinned release. Nothing changed."
printf 'SHA-256 matches the pinned release.\n'

chmod 755 -- "$tmp"
mv -f -- "$tmp" "$DEST"
trap - EXIT

installed=$("$DEST" --version 2>/dev/null || true)
[[ "$installed" == "Filen CLI $VERSION" ]] || fail "The installed binary did not run. Check $DEST."

say "$installed is installed."
printf 'Open the Filen panel and press Sign in.\n'
printf '\nTo use `filen` in your own shell too, add it to your PATH:\n'
printf '  export PATH="$HOME/.filen-cli/bin:$PATH"\n'
