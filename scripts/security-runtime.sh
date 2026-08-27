#!/usr/bin/env bash
# Runtime security check: while the plugin is actively working, snapshot the
# process table and environment of every process it spawns, and prove no
# credential material is exposed there.
#
# argv (/proc/PID/cmdline) is world-readable on Linux, so anything the plugin
# puts in a command line is visible to every local user. This asserts it
# doesn't.
set -uo pipefail

PASS=0; FAIL=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "── driving the plugin so it spawns processes ──"
omarchy-shell filen open  >/dev/null 2>&1; sleep 2
omarchy-shell filen goto / >/dev/null 2>&1
omarchy-shell filen refresh >/dev/null 2>&1

# Kick off a transfer so a long-lived child exists to inspect.
IDX=$(omarchy-shell filen rows 2>/dev/null | python3 -c "
import json,sys
try:
    rows=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for i,r in enumerate(rows):
    if not r['dir'] and (r.get('size') or 0) > 1000000: print(i); break
" 2>/dev/null)
if [ -n "${IDX:-}" ]; then
  omarchy-shell filen select "$IDX" >/dev/null 2>&1
  omarchy-shell filen downloadSelected >/dev/null 2>&1
fi
sleep 3

SNAP=$(mktemp); ENVS=$(mktemp)
trap 'rm -f "$SNAP" "$ENVS"' EXIT
ps -eo pid,args > "$SNAP"

# Collect the environment of every filen/rclone process we can read.
for pid in $(pgrep -f "filen|rclone-v" 2>/dev/null); do
  tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null >> "$ENVS"
done

echo
echo "── argv exposure (world-readable via /proc) ──"
grep -iE 'filen|rclone' "$SNAP" | grep -vE 'security-runtime|grep' > /tmp/.filen-argv || true
if [ -s /tmp/.filen-argv ]; then
  echo "  observed command lines:"
  sed 's/^/    /' /tmp/.filen-argv | head -6
fi

grep -qiE '\-\-password|\-\-email|\-p [^ ]|FILEN_CLI_PASSWORD=' /tmp/.filen-argv 2>/dev/null \
  && bad "credential flags visible in argv" || ok "no credential flags in any argv"

grep -qE 'master_keys|api_key|private_key' /tmp/.filen-argv 2>/dev/null \
  && bad "key material visible in argv" || ok "no key material in argv"

echo
echo "── environment exposure ──"
if [ -s "$ENVS" ]; then
  grep -qE '^FILEN_CLI_PASSWORD=.' "$ENVS" && bad "FILEN_CLI_PASSWORD set in a child env" \
    || ok "FILEN_CLI_PASSWORD not set in any child environment"
  grep -qE '^FILEN_CLI_EMAIL=.' "$ENVS" && bad "FILEN_CLI_EMAIL set in a child env" \
    || ok "FILEN_CLI_EMAIL not set in any child environment"
else
  ok "no readable child environments to leak (none spawned or already exited)"
fi

echo
echo "── credential file posture ──"
CONF="$HOME/.config/filen-cli/rclone/rclone.conf"
if [ -f "$CONF" ]; then
  MODE=$(stat -c %a "$CONF")
  case "$MODE" in
    600|400) ok "rclone.conf is $MODE (owner-only)" ;;
    *)       bad "rclone.conf is $MODE — readable by other local users" ;;
  esac
else
  ok "no rclone.conf present"
fi

if [ -f "$HOME/.filen-cli/filen-cli-auth-config.txt" ]; then
  M2=$(stat -c %a "$HOME/.filen-cli/filen-cli-auth-config.txt")
  case "$M2" in 600|400) ok "auth-config is $M2 (owner-only)" ;; *) bad "auth-config is $M2" ;; esac
else
  ok "no plaintext auth-config on disk (keyring only)"
fi

echo
echo "── downloaded filenames are safe on disk ──"
DL="${1:-$HOME/Downloads}"
BAD_NAMES=$(find "$DL" -maxdepth 1 -name '*' -printf '%f\n' 2>/dev/null \
  | grep -P '[\x{202A}-\x{202E}\x{2066}-\x{2069}\x{200E}\x{200F}\x{0000}-\x{001F}]' || true)
if [ -n "$BAD_NAMES" ]; then
  bad "download dir contains names with bidi/control characters:"
  printf '    %s\n' "$BAD_NAMES"
else
  ok "no bidi/control characters in any downloaded filename"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
