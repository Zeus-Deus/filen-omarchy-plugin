#!/usr/bin/env bash
# End-to-end acceptance test against the LIVE plugin and a real Filen account.
# Every check drives the plugin through its IPC surface and asserts on the
# state it reports back, so a pass means the feature genuinely worked.
set -uo pipefail

PASS=0; FAIL=0
ok(){   printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad(){  printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
S(){ omarchy-shell filen status 2>/dev/null; }
field(){ S | python3 -c "import json,sys;print(json.load(sys.stdin).get('$1',''))" 2>/dev/null; }

echo "── shell + plugin alive ──"
[ "$(omarchy-shell shell ping 2>/dev/null)" = "ok" ] && ok "shell responds" || bad "shell down"
S >/dev/null 2>&1 && ok "plugin IPC target reachable" || { bad "plugin IPC missing"; exit 1; }

echo
echo "── no QML load errors ──"
if qs log -p /usr/share/omarchy/shell --tail 150 2>&1 | grep -iE "filen.*(failed|error)" | grep -q .; then
  bad "plugin reported load errors"
else
  ok "no plugin load errors in the shell log"
fi

echo
echo "── CLI + auth ──"
[ "$(field cliInstalled)" = "True" ] && ok "Filen CLI detected: $(field cliVersion)" || bad "CLI not detected"
[ "$(field signedIn)"    = "True" ] && ok "signed in"                               || bad "not signed in"
[ "$(field quotaLoaded)" = "True" ] && ok "quota loaded ($(field usedBytes) / $(field totalBytes) bytes)" || bad "quota missing"

echo
echo "── browsing ──"
omarchy-shell filen open >/dev/null 2>&1; sleep 2
omarchy-shell filen goto / >/dev/null 2>&1; sleep 3
ROOT_N=$(field entries)
[ "${ROOT_N:-0}" -gt 0 ] && ok "root lists $ROOT_N entries" || bad "root listing empty"

omarchy-shell filen goto /Pictures >/dev/null 2>&1; sleep 3
[ "$(field path)" = "/Pictures" ] && ok "navigated into /Pictures" || bad "navigation failed"

ROWS=$(omarchy-shell filen rows 2>/dev/null)
echo "$ROWS" | grep -q '"kind": *"image"' && ok "image files classified" || bad "no image kind"
echo "$ROWS" | grep -q '"kind": *"video"' && ok "video files classified" || bad "no video kind"
echo "$ROWS" | python3 -c "
import json,sys
rows=json.load(sys.stdin)
sized=[r for r in rows if not r['dir'] and r.get('size')]
sys.exit(0 if sized else 1)" && ok "file sizes present in the listing" || bad "no sizes"

echo
echo "── hostile filename handling ──"
if echo "$ROWS" | python3 -c "
import json,sys
rows=json.load(sys.stdin)
bad=[r['name'] for r in rows if any(ord(c) in range(0x202A,0x202F) or ord(c)<32 for c in r['name'])]
sys.exit(1 if bad else 0)"; then
  ok "no bidi/control characters in any displayed name"
else
  bad "a displayed name still contains bidi/control characters"
fi

echo
echo "── recovery from a vanished folder ──"
omarchy-shell filen goto /Pictures/NoSuchFolder999 >/dev/null 2>&1; sleep 4
RECOVER=$(field path)
[ "$RECOVER" = "/Pictures" ] && ok "bad path recovered to $RECOVER" || bad "stranded at '$RECOVER'"
[ -z "$(field listError)" ] && ok "no raw CLI error left on screen" || bad "listError: $(field listError)"

echo
echo "── download + open in a viewer ──"
omarchy-shell filen goto /Pictures >/dev/null 2>&1; sleep 3
IDX=$(omarchy-shell filen rows 2>/dev/null | python3 -c "
import json,sys
for i,r in enumerate(json.load(sys.stdin)):
    if r['name'].endswith('.png') and not r['dir']: print(i); break" 2>/dev/null)
if [ -n "${IDX:-}" ]; then
  TARGET=$(omarchy-shell filen select "$IDX" 2>/dev/null)
  omarchy-shell filen downloadSelected >/dev/null 2>&1
  sleep 7
  XFER=$(omarchy-shell filen transfers 2>/dev/null)
  if echo "$XFER" | grep -q '"state": *"done"\|"state":"done"'; then
    ok "download completed ($TARGET)"
  else
    bad "download did not complete"
  fi
  # The local filename is deliberately NOT the remote one: safeLocalName
  # strips leading dashes and bidi/control characters. Assert on the path the
  # plugin actually reported, which is the real contract.
  LOCAL=$(echo "$XFER" | python3 -c "
import json,sys
ts=json.load(sys.stdin)
print(ts[0]['local'] if ts else '')" 2>/dev/null)
  if [ -n "$LOCAL" ] && [ -f "$LOCAL" ]; then
    ok "file present on disk at the sanitized path ($(basename "$LOCAL"))"
  else
    bad "file missing at reported path: $LOCAL"
  fi
else
  bad "no png found to download"
fi

echo
echo "── transfers view ──"
omarchy-shell filen transfers >/dev/null 2>&1 && ok "transfers queryable" || bad "transfers IPC broken"

echo
echo "── credential posture ──"
CONF="$HOME/.config/filen-cli/rclone/rclone.conf"
if [ -f "$CONF" ]; then
  M=$(stat -c %a "$CONF")
  case "$M" in 600|400) ok "rclone.conf mode $M (owner-only)" ;;
               *)       bad "rclone.conf mode $M — other users can read your keys" ;; esac
fi
pgrep -af "filen|rclone" 2>/dev/null | grep -qiE 'password|master_key|api_key' \
  && bad "secret visible in a live command line" || ok "no secrets in any live argv"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
