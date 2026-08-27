# Filen for Omarchy

An [Omarchy Quattro](https://omarchy.org) shell plugin that puts your
[Filen](https://filen.io) end-to-end encrypted drive in the bar: browse it,
download and open files in your normal viewers, upload into it, and watch
transfers — without a browser or memorising CLI flags.

Built for the Quickshell-based Omarchy 4 shell. Tested against Omarchy
`4.0.0` and Filen CLI `0.2.7`.

## What it does

**Bar widget** — the Filen mark, dimmed when idle, with a count of running
transfers and a dot when something needs attention.

**Panel** (click, or `omarchy-shell filen toggle`)

- Drive quota meter with used/total
- File browser with breadcrumb, folders first, natural sort, real sizes
- Type-aware icons; `Enter` on an image/video/PDF downloads it and opens it
  in **your** configured viewer (imv, mpv, evince — via `xdg-open`)
- Filter within a folder (`/`)
- Upload via the desktop file chooser (`u`) or from the clipboard (`p`)
- Create folders (`n`), delete to Filen trash with confirmation (`x`)
- Transfers view (`t`) with live percentage, speed, ETA and working cancel

### Keys

| Key | Browser | Transfers |
|---|---|---|
| `↑ ↓` / `j k` | move cursor | move cursor |
| `→` / `l` | enter folder | — |
| `←` / `h` / `Backspace` | up a folder | — |
| `Enter` | folder: open · file: download & open | open finished download |
| `o` | download and open | — |
| `d` | download only | — |
| `u` | upload via file chooser | — |
| `p` | upload paths from clipboard | — |
| `n` | new folder | — |
| `y` | copy the remote path | — |
| `x` | delete (to trash, confirmed) | cancel transfer |
| `/` | filter this folder | — |
| `r` | refresh | refresh |
| `t` | transfers view | back to files |
| `w` | open the web drive | — |
| `c` | — | clear finished |
| `Esc` | clear filter / close | back to files |

## Install

Requires the Filen CLI. Install it yourself — the plugin never downloads or
updates anything on your behalf:

```bash
# review first: https://github.com/FilenCloudDienste/filen-cli-releases
curl -sL https://raw.githubusercontent.com/FilenCloudDienste/filen-rs/refs/heads/main/filen-cli/install.sh -o /tmp/filen-install.sh
less /tmp/filen-install.sh
bash /tmp/filen-install.sh
```

Sign in once, in a terminal. The CLI stores the session in your system
keyring; the plugin never sees your password:

```bash
filen stat /      # prompts for email/password, answer "y" to stay signed in
```

Then add the plugin:

```bash
omarchy plugin add https://github.com/<you>/filen-omarchy-plugin --enable --yes
```

## Settings

Configurable in `Setup > Plugins`, stored inline in `~/.config/omarchy/shell.json`.

| Setting | Default | Meaning |
|---|---|---|
| `refreshIntervalSec` | 300 | Background quota refresh (60–3600) |
| `downloadDir` | `~/Downloads` | Where downloads land; validated |
| `confirmDelete` | `true` | Confirm before moving to Filen trash |
| `bandwidthLimit` | *(empty)* | e.g. `2M`, `500K`; empty = unlimited |

## Security

Filen is zero-knowledge, and this plugin runs **unsandboxed inside the
Omarchy shell process**. The design follows from those two facts.

- **Your password never touches the plugin.** There is no password field.
  Sign-in happens in a real terminal running the CLI's own prompt; the CLI
  stores the session in the system keyring.
- **No secrets in argv.** `/proc/<pid>/cmdline` is world-readable. Verified
  at runtime during a live transfer: the command lines contain only paths
  and flags.
- **No credential env vars.** `FILEN_CLI_PASSWORD` / `FILEN_CLI_EMAIL` are
  never set, so nothing leaks into child processes.
- **The auth config is never read.** `filen-cli-auth-config.txt` holds master
  keys, the private key and the API key in plaintext. The plugin never reads,
  copies or displays it, and never calls `export-api-key` /
  `export-auth-config`.
- **No shell.** Every command is an argv array, so a filename containing
  `;`, `$()`, backticks or newlines is inert data. Native verbs get `--` so a
  name starting with `-` can't become a flag.
- **Remote output is treated as hostile.** Names come from shared folders and
  can be anything. Responses are size-capped, JSON is parsed defensively, and
  displayed text is stripped of control characters and bidi overrides, then
  rendered as `PlainText`.
- **Downloads are written under a sanitized name.** The remote path stays
  byte-exact so the right object is fetched, but the local filename has bidi
  and control characters removed. Without this, a drive file called
  `ev<U+202E>gnp.exe` lands on your disk displaying as `evexe.gnp` — a real
  bug this plugin had, found by testing against a hostile fixture.
- **The updater never fires on its own.** Every call passes `--skip-update`;
  updating the CLI is your decision.
- **Deletes go to the Filen trash** and are confirmation-gated by default.
  The plugin can never empty the trash or permanently delete.
- **It warns about the CLI's own credential cache.** The Filen CLI writes
  `~/.config/filen-cli/rclone/rclone.conf` — containing `master_keys`,
  `api_key` and `private_key` in plaintext — as mode **0644**, readable by
  every local user. The panel detects this and offers to `chmod 600` it.
  *(Worth reporting upstream.)*

Run the audits:

```bash
./scripts/security-audit.sh    # 21 static checks over the source
./scripts/security-runtime.sh  # 7 checks against live processes
```

## Notes on the Filen CLI

Findings from reading the source and testing v0.2.7 — useful if you extend
this:

- The **TypeScript CLI is sunset**; this targets the Rust rewrite
  (`filen-rs/filen-cli`), currently public beta.
- **Failures print to stdout, not stderr.** Classify on both or a signed-out
  account reads as signed in.
- v0.2.7 has **no `upload`/`download` subcommand** — those exist only on git
  `main`. Transfers go through the bundled rclone (`filen rclone copyto`).
- Native `ls --json` returns **names only**. `filen rclone lsjson` returns
  name + size + mtime + MIME + IsDir in one call, so the browser uses that
  instead of one `stat` per row.
- **Offline is indistinguishable from signed-out** by message alone; both
  produce `Failed to read input from terminal`. The plugin probes
  connectivity before claiming your session is gone.
- Each `filen rclone` run **rewrites `rclone.conf`** as it starts. Two
  overlapping runs can catch it mid-write (`didn't find section in config
  file`), so metadata calls are serialised and retried.
- `filen` spawns rclone as a **child in the caller's process group**, so
  cancelling requires `setsid` + a group signal.

## Development

```bash
node --test tests/model.test.js   # 79 unit tests, no Qt needed
omarchy plugin validate .
./scripts/dev-reload.sh           # sync, test, restart shell, check for errors
```

`tests/mock-filen` is a fake CLI for exercising states that are hard to
reproduce live (signed out, empty drive, garbage JSON, huge listings, slow
transfers). Point the plugin at it by putting it earlier in `PATH`.

Architecture, conventions and traps: see [AGENTS.md](AGENTS.md).

## Licence

MIT
