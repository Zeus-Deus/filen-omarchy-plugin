#!/usr/bin/env bash
# Sync the working tree into the installed plugin, restart the shell, and
# report any QML load errors. This is the inner dev loop.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ID="io.github.zeus-deus.filen"
DEST="$HOME/.config/omarchy/plugins/$ID"

echo "── validating manifest ──"
omarchy plugin validate "$SRC"

echo "── syncing $SRC -> $DEST ──"
for f in manifest.json Panel.qml Service.qml FilenIcon.qml Model.js; do
  cp -f "$SRC/$f" "$DEST/$f"
done

echo "── unit tests ──"
( cd "$SRC" && node --test tests/model.test.js 2>&1 | tail -6 )

echo "── restarting shell ──"
omarchy-restart-shell >/dev/null 2>&1 || true
sleep 5

echo "── shell health ──"
omarchy-shell shell ping || { echo "SHELL DOWN"; exit 1; }

echo "── plugin errors in log ──"
if qs log -p /usr/share/omarchy/shell --tail 120 2>&1 | grep -iE "filen.*(failed|error)" | head -10 | grep .; then
  echo "!! plugin reported errors above"
  exit 1
else
  echo "clean — no plugin load errors"
fi

echo "── plugin IPC ──"
omarchy-shell filen status || echo "IPC target not reachable"
