# filen-omarchy-plugin

Design notes for an Omarchy Quattro shell plugin that manages a
[Filen](https://filen.io) end-to-end encrypted drive from the bar.

Mockups: `mockups/index.html`

## Status

Design study only. No plugin code written yet.

## Key research findings

### The CLI landscape changed — target the Rust CLI

- `FilenCloudDienste/filen-cli` (TypeScript, v0.0.36/0.0.39) is **sunset**.
  Its README tells users to move on.
- The replacement is the Rust rewrite at
  `FilenCloudDienste/filen-rs/filen-cli`, distributed via
  `FilenCloudDienste/filen-cli-releases`, currently **public beta v0.2.7**.
- The Rust CLI **dropped** native `sync`, `mount`, `webdav`, `s3`.
  Mounts and servers are now delegated to a **managed rclone**
  (`filen mount`, `filen serve <webdav|ftp|sftp|http>`, `filen rclone <cmd>`).
  Filen also landed an official rclone backend in rclone v1.73.
- **Sync pairs are gone entirely** from the Rust CLI. Do not design for them.

### Verified Rust CLI surface (read from `filen-cli/src/commands.rs` @ main)

Subcommands: `help cd ls cat head tail stat mkdir rm mv cp upload download
search favorite unfavorite list-trash empty-trash export-auth-config rclone
mount serve export-api-key view-html-docs logout exit`

Global flags that matter: `--json`, `--quiet`, `-v`, `--config-dir`,
`--auth-config-path`, `--skip-update`, bandwidth/concurrency caps.

`--json` is implemented in exactly five places (`commands.rs`):

| Command | JSON shape |
|---|---|
| `ls` | `{directories: string[], files: string[]}` — **names only, no sizes** |
| `stat <file>` | `{name, type:"file", size, modified, created, uuid}` |
| `stat <dir>` | `{name, type:"directory", created, uuid}` |
| `stat /` | `{type:"drive", usedStorage, totalStorage}` |
| `export-api-key` | `{email, apiKey}` — **never call this from the plugin** |

Consequence: a file listing with sizes costs `ls` + one `stat` per entry.
Either accept that (batch, cache, lazy-load) or list names first and stat on
cursor focus.

`search` and `list-trash` are **interactive** commands — no scriptable form.

### Auth model (read from `filen-cli/src/auth.rs` @ main)

Resolution order: CLI args → env (`FILEN_CLI_EMAIL` / `FILEN_CLI_PASSWORD` /
`FILEN_CLI_2FA_CODE`) → auth config file → **system keyring** → interactive
prompt.

- Keyring entry name: `sdk-config`. This is the path the plugin should rely on.
- Auth config file `filen-cli-auth-config.txt` (in `./`, `~/.filen-cli/`, or
  the config dir) contains **master keys, private key and API key in
  plaintext**, written mode 0600. The plugin must never read or display it.
- There is no `keyring` write without the interactive "Keep me logged in?"
  prompt — so login must happen in a terminal, not in QML.

### Omarchy Quattro plugin contract (read from the live machine)

- `~/.config/omarchy/plugins/<id>/manifest.json`, `schemaVersion: 1`,
  id must not use the `omarchy.*` prefix.
- Kinds: `bar-widget | panel | overlay | menu | service | bar`.
  Entry via `entryPoints.barWidget` etc.
- Enabled state lives in `~/.config/omarchy/shell.json`; third-party is
  "enabled iff its id appears in the file".
- Install: `omarchy plugin add <git-url> [--enable] [--yes]`.
  Validate: `omarchy plugin validate .`.
  Reload: saving under `~/.config/omarchy/plugins/` hot-reloads;
  `omarchy-shell shell rescanPlugins` forces it; `Panel.qml` edits need
  `omarchy-restart-shell`.
- Plugins run **unsandboxed** in the single long-running `omarchy-shell`
  Quickshell process. Never spawn a second Quickshell.

### Local environment (verified)

- Omarchy `4.0.0.r1846.g946704f-1`, theme `spiderman`, JetBrainsMono Nerd Font,
  bar 26px, `decoration:rounding` = 0.
- Installed reference plugins: `space.passpage.shares`,
  `io.github.zeus-deus.gazelle` — both follow the
  `Panel.qml` / `Service.qml` / `Model.js` / `tests/` shape.
- `filen` is **not installed**. `rclone` is **not installed**.
  `fusermount3`, `gum`, `jq`, `wl-copy`, `node` are present.

## Scope ladder

**v0.1** — glyph + quota badge, browse w/ breadcrumb, stat details, download,
upload, favorites, open web drive. All clean `--json` / exit-code calls.

**v0.2** — transfers list w/ cancel, mounts & servers panel, trash view,
completion notifications.

**Blocked upstream** — search (needs non-interactive flag), public links (not
in Rust CLI yet), notes/chats/contacts (SDK/API only). File these as feature
requests at features.filen.io rather than working around them.

## Security rules

1. No password field in QML. Login via terminal → CLI prompt → keyring.
2. Never read, copy or display `filen-cli-auth-config.txt`.
3. Never call `export-api-key` or `export-auth-config` from the plugin.
4. Never put secrets in argv (`/proc` is world-readable) or in env vars.
5. Treat all CLI output as attacker-controlled — filenames come from shared
   folders. Cap response size, parse JSON strictly, pass paths as positional
   args.
6. Servers bind loopback + read-only by default; public bind is explicit and
   warned.
7. Never trigger the CLI's auto-updater silently; pass `--skip-update` on
   plugin-initiated calls and let the user update deliberately.
8. Destructive actions go through `ConfirmDialog` defaulting to Cancel.

## References

- Shell contract: `/usr/share/omarchy/shell/README.md`
- Plugin catalogue: `/usr/share/omarchy/shell/plugins/README.md`
- Plugin dev guide: https://omarchyplugins.com/develop.html
- Filen CLI (Rust) source: https://github.com/FilenCloudDienste/filen-rs/tree/main/filen-cli
- Filen CLI docs: https://docs.filen.io/docs/cli-rs/readme
- Filen API/SDK docs: https://docs.filen.io/docs/api
