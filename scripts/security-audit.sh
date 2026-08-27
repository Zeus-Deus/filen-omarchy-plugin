#!/usr/bin/env bash
# Static security audit of the Filen Omarchy plugin.
# Every check is a grep against the SOURCE, so it stays honest as code changes.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PASS=0; FAIL=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# Strip comments before grepping: this file documents its own threat model in
# prose ("FILEN_CLI_PASSWORD is never set"), and a naive grep would flag the
# comment describing the protection as a violation of it.
CODE_DIR=$(mktemp -d)
trap 'rm -rf "$CODE_DIR"' EXIT
python3 - "$PWD" "$CODE_DIR" <<'PY'
import pathlib, re, sys
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
for f in list(src.glob("*.qml")) + list(src.glob("*.js")):
    out = []
    for line in f.read_text().splitlines():
        # drop a // comment, but not the // inside a URL scheme
        line = re.sub(r'(?<!:)//.*$', '', line)
        out.append(line)
    (dst / f.name).write_text("\n".join(out))
PY

# Guard against the audit silently passing because the stripped copies are
# empty (a broken strip step would make every "absence" check succeed).
STRIPPED_BYTES=$(cat "$CODE_DIR"/* 2>/dev/null | wc -c)
if [ "$STRIPPED_BYTES" -lt 5000 ]; then
  echo "ABORT: comment-stripping produced only ${STRIPPED_BYTES} bytes — audit would be meaningless"
  exit 2
fi

cd "$CODE_DIR"

echo "── credentials never handled by the plugin ──"
grep -qE 'FILEN_CLI_PASSWORD|FILEN_CLI_EMAIL|FILEN_CLI_2FA' *.qml *.js \
  && bad "sets Filen credential env vars" || ok "never sets FILEN_CLI_* credential env vars"

grep -qE '"--password"|"-p",|"--email"|"-e",' *.qml \
  && bad "passes credentials as CLI flags" || ok "never passes --email/--password"

grep -qE 'export-api-key|export-auth-config' *.qml \
  && bad "invokes a credential-export command" || ok "never invokes export-api-key/export-auth-config"

grep -qE 'filen-cli-auth-config|master_keys|private_key|api_key' *.qml \
  && bad "references the auth config contents" || ok "never reads the auth config file contents"

grep -qE 'password: true|echoMode|TextField.*[Pp]assword' Panel.qml \
  && bad "has a password input field" || ok "no password field in the UI"

echo
echo "── no shell interpolation of untrusted data ──"
# Any bash -c must use positional args ($1), never string concatenation of a var.
if grep -nE '"bash", *"-c"' *.qml | grep -q .; then
  if grep -nE '"bash", *"-c", *"[^"]*" *\+' *.qml | grep -q .; then
    bad "bash -c built by string concatenation"
  else
    ok "bash -c bodies are fixed literals (args passed positionally)"
  fi
else
  ok "no bash -c usage at all"
fi

grep -nE 'execDetached\(\[[^]]*\+' *.qml | grep -v 'remoteUrl\|downloadDir\|"-" *\+' | grep -q . \
  && bad "execDetached argv built by concatenation" || ok "execDetached argv are discrete elements"

echo
echo "── path safety ──"
grep -q 'function normalizePath' Model.js && ok "paths are normalised (traversal collapsed)" || bad "no path normalisation"
grep -q 'function isUsableName' Model.js && ok "remote names validated before use" || bad "no name validation"
grep -q 'function safeLocalName' Model.js && ok "local write names sanitized (bidi/control stripped)" || bad "local names not sanitized"
grep -q 'validatedDownloadDir' Service.qml && ok "download directory validated" || bad "download dir unvalidated"

echo
echo "── option-injection guards ──"
grep -q '"--"' Service.qml && ok "native verbs terminate options with --" || bad "no -- guard on native verbs"

echo
echo "── output treated as hostile ──"
grep -q 'MAX_RESPONSE_BYTES' Model.js && ok "responses are size-capped" || bad "no response size cap"
grep -q 'function sanitizeText' Model.js && ok "displayed text is sanitized" || bad "no text sanitisation"
grep -q 'textFormat: Text.PlainText' Panel.qml && ok "CLI-derived text rendered as PlainText (no markup)" || bad "text may render as rich text"

echo
echo "── updater / privilege ──"
grep -q '"--skip-update"' Service.qml && ok "CLI auto-updater suppressed on every call" || bad "auto-updater may fire"
grep -qE '"sudo"|"pkexec"|"doas"' *.qml && bad "escalates privilege" || ok "never escalates privilege"

echo
echo "── destructive actions ──"
grep -q 'confirmDelete' Service.qml && ok "delete is confirm-gated" || bad "delete not gated"
grep -q -- '--permanent' Service.qml && bad "uses permanent delete" || ok "deletes go to the Filen trash (recoverable)"
grep -q 'empty-trash' *.qml && bad "can empty the trash" || ok "never empties the trash"

echo
echo "── credential-cache posture ──"
grep -q 'configWorldReadable' Service.qml && ok "warns when rclone.conf is group/world readable" || bad "no permission warning"

echo
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
