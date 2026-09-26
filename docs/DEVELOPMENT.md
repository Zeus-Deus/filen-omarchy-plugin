# Development notes

Omarchy Quattro shell plugin for [Filen](https://filen.io), an end-to-end
encrypted cloud drive. Browse, download, open, upload and manage transfers
from the bar.

## Layout

- `manifest.json` — id `io.github.zeus-deus.filen`, kind `bar-widget`,
  entry `Panel.qml`.
- `Panel.qml` — bar button + `KeyboardPanel`; cursor model, browser rows,
  transfers view, delete `ConfirmDialog`, `IpcHandler` target `filen`.
- `Service.qml` — all `filen` CLI processes, auth/offline state, listing,
  quota, transfers with progress and cancel.
- `FilenIcon.qml` — the mark drawn natively on a `Canvas` (no bundled image).
- `Model.js` — pure helpers: parsing, sanitisation, formatting, error
  classification. No Qt imports, Node-testable.
- `tests/model.test.js` — 99 tests, `node --test tests/model.test.js`.
- `tests/mock-filen` — fake CLI for states that are hard to reproduce live,
  and the demo drive behind `preview.png` / `docs/images/`.
- `scripts/install-cli.sh` — pinned, SHA-256-checked CLI installer, run in
  Omarchy's floating terminal from the panel's Install button. Bump
  `VERSION` + both digests together when the CLI moves.
- `scripts/dev-reload.sh` — sync → test → restart shell → check log → IPC.
- `scripts/security-audit.sh` — 29 static checks.
- `scripts/security-runtime.sh` — 7 live-process checks.

## Hard-won facts about the Filen CLI (v0.2.7)

Verified by reading `filen-rs/filen-cli/src/*.rs` and testing on this machine.
Re-verify if the CLI version moves.

1. **The TypeScript CLI is sunset.** Target the Rust rewrite. Its release
   repo is `filen-cli-releases`; source lives in `filen-rs/filen-cli`.
2. **Errors go to STDOUT, not stderr.** stderr is usually empty. Always
   classify on `stdout + stderr` combined (`Service.combinedOutput`).
   Getting this wrong reports a signed-out account as signed in.
3. **There is no `whoami`** and no `--json` on most commands. `--json` is
   implemented in only a handful of places.
4. **No `upload` / `download` subcommand exists in 0.2.7.** They are on git
   `main` only. Use the managed rclone.
5. **`--` works on native verbs** (ls/stat/mkdir/rm) but **not** on the
   `rclone` passthrough — rclone parses its own argv.
6. **`filen rclone lsjson filen:<path>`** is the good listing source:
   `{Path,Name,Size,MimeType,ModTime,IsDir,ID}` per entry. `Size` is `-1`
   for directories. `ModTime` is RFC3339, not epoch ms.
7. **`filen rclone about filen: --json`** gives `{total,used,free}`.
8. **Offline == signed out, textually.** Both print `Failed to read input
   from terminal`. You MUST probe connectivity before concluding the session
   is gone, or every Wi-Fi blip shows a login button.
9. **Every `filen rclone` run rewrites `~/.config/filen-cli/rclone/
   rclone.conf`.** Concurrent runs can read it mid-write and fail with
   `didn't find section in config file`. Serialise metadata calls; retry.
10. **`filen` forks rclone as a child in the CALLER's process group.**
    Signalling the `filen` pid alone leaves rclone running. Each transfer is
    launched under `setsid` so cancel can signal the whole group
    (`kill -TERM -- -PID`, then `-KILL` after 3s).
11. **rclone.conf is created 0644** and contains `master_keys`, `api_key`,
    `private_key` in plaintext (upstream: filen-rs#16). Omarchy homes are
    0700, so it is only exposed when every directory above it is
    traversable; `Model.credentialExposed` checks exactly that. The fix
    locks `~/.config/filen-cli` to 0700, which survives the CLI recreating
    the file on sign-in.
12. `--quiet` suppresses the failure text we classify on. Don't pass it.
13. Progress: `--use-json-log --stats 1s --stats-log-level NOTICE` emits one
    JSON object per line on stderr with a `stats` block. Read it with
    `SplitParser`, not `StdioCollector`, or the UI only updates at exit.

## Security invariants

These are enforced by `scripts/security-audit.sh`; keep them true.

- No password field in QML. Sign-in is a terminal running the CLI's prompt.
- Never set `FILEN_CLI_PASSWORD` / `FILEN_CLI_EMAIL`.
- Never call `export-api-key` or `export-auth-config`.
- Never read `filen-cli-auth-config.txt` or `rclone.conf` contents (stat only).
- Never build a shell string from untrusted data. `Process.command` is always
  an argv array; `bash -c` bodies are fixed literals with values passed as
  `$1`.
- Remote names keep their exact bytes for CLI calls; **local** filenames are
  sanitized with `Model.safeLocalName` before being written to disk.
  A drive file named `ev<U+202E>gnp.exe` must never land as that name — it
  displays as `evexe.gnp` and hides the real extension.
- All CLI output is size-capped and sanitized before display, and rendered as
  `Text.PlainText`. The cap is enforced **at ingestion**: a `StdioCollector`
  buffers the whole stream until the child exits, so every collected command
  runs through `Model.boundedArgv` (listing 4 MB, everything else 64 KB,
  stderr 8 KB), which cuts the pipe mid-stream and exits
  `OUTPUT_LIMIT_EXIT` (90). Checking the size after exit is too late.
  A test pins that every `*Process.command` in `Service.qml` is bounded.
- Every call carries `--skip-update`.
- Deletes go to the Filen trash and are confirmation-gated. Never
  `--permanent`, never `empty-trash`.
- Downloads never overwrite: a free local name is claimed on disk first
  (`freeNameScript`: `mkdir`, or a noclobber `O_EXCL` create for a file).
  Never replace that with an in-memory list of reserved names; resolvers
  run asynchronously, so a list snapshot races. A failed or canceled
  download removes its placeholder only if it is still empty
  (`discardPlaceholderScript`). `xdg-open` is only used for `Model.isSafeToOpen`
  types; launchers/scripts/HTML are revealed, never opened.
- No literal elevation-command names anywhere in tracked source — the
  marketplace security baseline greps for them, even in this audit script.

## Plugin conventions (from the shell + installed 3p plugins)

- Single `Panel.qml` as `entryPoints.barWidget`, built on `qs.Ui` `Panel` +
  `BarIconButton` + `KeyboardPanel` + `PanelKeyCatcher`; pure logic in
  `Model.js`.
- Colours/spacing from `qs.Commons` (`Color`, `Style`), never hard-coded.
- Clipboard: `wl-copy` / `wl-paste`. Open URL: `omarchy-launch-browser`.
  Open a local file: `xdg-open` (respects the user's imv/mpv/evince choice).
  Terminal: `omarchy-launch-terminal`.
- Bind polling timers to `opened` so a closed panel costs nothing.

## Traps

- **QML `\uXXXX` only takes 4 hex digits.** Nerd Font glyphs are 5-digit
  (U+F0552). Paste the literal character; a surrogate pair like
  `\udb81\udd52` renders as the wrong glyph. Verify a codepoint exists with
  fontTools against `JetBrainsMonoNerdFont-Regular.ttf` before using it.
- `NumberAnimation on <prop> { ... }` cannot take `onRunningChanged`. Use a
  `SequentialAnimation` with an explicit `running:` binding.
- `KeyboardPanel` doesn't scroll — wrap content in a `Flickable`.
- `escape()` is a reserved method name; `h` can't be a text shortcut (it's
  the left-arrow binding in `PanelKeyCatcher`).
- `qmllint` can't parse `qs.Ui` imports. The real gates are
  `omarchy plugin validate .` and
  `qs log -p /usr/share/omarchy/shell --tail 60`.
- `Panel.qml` edits need `omarchy-restart-shell` (use `scripts/dev-reload.sh`).
- A grep-based audit must strip `//` comments first — this codebase documents
  its own threat model in prose, and a naive grep flags the comment describing
  a protection as a violation of it.

## Dev loop

```bash
./scripts/dev-reload.sh            # validate, sync, test, restart, check log
omarchy-shell filen status         # JSON state
omarchy-shell filen rows           # what the panel is showing
omarchy-shell filen goto /Pictures # deterministic navigation for tests
omarchy-shell filen select 3       # move the cursor to a row
omarchy-shell filen downloadSelected
omarchy-shell filen cancel
```

Prefer these IPC verbs over `wtype` key injection when testing: key timing
races produce flaky, misleading results.

## References

- Shell runtime contract: `/usr/share/omarchy/shell/README.md`
- Built-in plugin examples: `/usr/share/omarchy/shell/plugins/`
- Plugin dev guide: https://omarchyplugins.com/develop.html
- Filen CLI source: https://github.com/FilenCloudDienste/filen-rs/tree/main/filen-cli
- Filen CLI docs: https://docs.filen.io/docs/cli-rs/readme
