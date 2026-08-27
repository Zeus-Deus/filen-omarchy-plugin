import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Drives the official Filen CLI (the Rust rewrite, v0.2.x) as a child process
// and exposes its state as plain QML properties.
//
// ── Which CLI surface we use, and why ─────────────────────────────────────
// v0.2.7 ships two families of commands:
//   * native:  ls, stat, mkdir, rm, mv, cp, favorite, cat, head, tail
//   * managed rclone:  `filen rclone <args>` against the "filen:" remote
// The native `ls --json` returns NAMES ONLY (no sizes/dates), and v0.2.7 has
// NO upload/download subcommand at all (those exist only on git main). The
// managed rclone path gives us `lsjson` — one call returning name, size,
// mtime, MIME type and directory flag — plus copy for transfers. So listings
// and transfers go through rclone; small metadata ops use the native verbs.
//
// ── Security model ────────────────────────────────────────────────────────
// * The plugin NEVER handles the account password. Sign-in happens in a real
//   terminal running the CLI's own prompt; the CLI stores the session in the
//   system keyring (gnome-keyring / org.freedesktop.secrets). We only ever
//   observe whether a command succeeded.
// * No secret is ever passed in argv. /proc/<pid>/cmdline is world-readable,
//   so argv is a public channel. We pass nothing sensitive at all.
// * FILEN_CLI_PASSWORD / FILEN_CLI_EMAIL are never set.
// * Every command runs WITHOUT a shell: `command` is an argv array, so
//   filenames containing ;, $(), backticks, newlines etc. are inert data.
// * The CLI's auth config (master keys + private key + API key in plaintext)
//   is never read, copied, or displayed. `export-api-key` and
//   `export-auth-config` are never invoked.
// * --skip-update on every call: the CLI's auto-updater replaces its own
//   binary, which must be a deliberate user action, never a side effect of
//   opening a panel.
// * All CLI output is treated as attacker-influenced (shared folders can be
//   named anything) and is size-capped + sanitized in Model.js before display.
//
// ── CLI quirks (verified against v0.2.7 on this machine) ─────────────────
// * Failure messages go to STDOUT, not stderr; stderr is usually empty.
//   Classify on both streams or a signed-out account reads as signed in.
// * `--` is accepted by ls/stat/mkdir/rm but NOT by the rclone passthrough.
// * The CLI writes ~/.config/filen-cli/rclone/rclone.conf containing the
//   master keys, private key and API key — and creates it mode 0644
//   (world-readable). We detect that and warn; we never read the contents.
Item {
  id: root

  property var settings: ({})

  // Set by the panel so completion toasts are suppressed while the user is
  // already looking at the transfer list.
  property bool panelOpen: false

  // ── availability / auth ────────────────────────────────────────────────
  property bool cliChecked: false
  property bool cliInstalled: false
  property string cliPath: ""
  property string cliVersion: ""
  property bool signedIn: false
  property bool authChecked: false

  // Security posture of the CLI's own credential cache.
  property bool configWorldReadable: false
  property string configPath: ""

  // ── drive ──────────────────────────────────────────────────────────────
  property double usedBytes: 0
  property double totalBytes: 0
  property bool quotaLoaded: false

  // ── listing ────────────────────────────────────────────────────────────
  property string currentPath: "/"
  property var entries: []
  property bool listing: false
  property bool listLoaded: false
  property string listError: ""

  // ── transfers ──────────────────────────────────────────────────────────
  property var transfers: []
  property int transferSeq: 0
  // id -> live Process handle, so cancel always finds its target.
  property var liveProcesses: ({})

  // ── transient feedback ─────────────────────────────────────────────────
  property string actionStatus: ""
  property string actionError: ""

  // Invalidates in-flight responses whose context changed (navigation,
  // sign-out) so a late reply can never repaint a newer view.
  property int generation: 0

  readonly property bool busy: listing || quotaProcess.running
  readonly property real quotaFraction: Model.formatPercent(usedBytes, totalBytes)
  readonly property bool quotaHigh: quotaFraction >= 0.9
  readonly property bool atRoot: currentPath === "/"
  readonly property var transferStats: Model.transferSummary(transfers)
  readonly property bool needsSetup: cliChecked && !cliInstalled
  readonly property bool needsLogin: cliInstalled && authChecked && !signedIn

  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string downloadDir:
    Model.validatedDownloadDir(setting("downloadDir", ""), homeDir)
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 300, 60, 3600)
  readonly property bool confirmDelete: setting("confirmDelete", true) !== false

  signal entriesUpdated()
  signal transfersUpdated()
  signal navigated(string path)
  signal transferFinished(string kind, string label, bool ok)

  function setting(name, fallback) {
    var v = settings ? settings[name] : undefined
    return v === undefined || v === null ? fallback : v
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // ── argv construction ──────────────────────────────────────────────────
  //
  // No shell, ever. `--quiet` is deliberately NOT passed: it suppresses the
  // failure text we classify sign-in state on.
  function cliArgs(args) {
    return [root.cliPath, "--skip-update"].concat(args)
  }

  // Native verbs accept `--` to end option parsing, so a path starting with
  // '-' can never be read as a flag.
  function nativeArgs(args) {
    return cliArgs(args)
  }

  // The rclone passthrough does NOT accept `--`; rclone parses its own argv.
  // Remote paths are prefixed "filen:" and every path is a separate argv
  // element, so no quoting or interpolation is involved.
  function rcloneArgs(args) {
    return cliArgs(["rclone"].concat(args))
  }

  // Transfer invocations additionally ask rclone for machine-readable
  // progress: one JSON object per line on stderr, once per second.
  function rcloneTransferArgs(args) {
    var extra = [
      "--use-json-log", "--stats", "1s", "--stats-log-level", "NOTICE"
    ]
    // Optional bandwidth cap. Empty/0 means unlimited (rclone's default).
    var limit = String(setting("bandwidthLimit", "")).trim()
    if (limit !== "" && /^[0-9]+(\.[0-9]+)?[KMG]?$/.test(limit)) {
      extra.push("--bwlimit", limit)
    }
    return rcloneArgs(args.concat(extra))
  }

  function remoteUrl(path) {
    var p = Model.normalizePath(path)
    return "filen:" + (p === "/" ? "" : p)
  }

  function showStatus(text) {
    actionError = ""
    actionStatus = text
    statusTimer.restart()
  }

  function showError(text) {
    actionStatus = ""
    actionError = text
    statusTimer.restart()
  }

  // The CLI reports failures on stdout; stderr is typically empty.
  function combinedOutput(a, b) {
    return String(a || "") + "\n" + String(b || "")
  }

  // ── lifecycle ──────────────────────────────────────────────────────────

  function start() {
    if (cliChecked) return
    whichProcess.command = ["bash", "-lc",
      "command -v filen || command -v \"$HOME/.filen-cli/bin/filen\" || true"]
    whichProcess.running = true
  }

  function refresh() {
    if (!cliInstalled) { start(); return }
    refreshQuota()
    list(currentPath, true)
    checkConfigPermissions()
  }

  function refreshQuota() {
    if (!cliInstalled || quotaProcess.running) return
    quotaProcess.generation = generation
    quotaProcess.command = rcloneArgs(["about", "filen:", "--json"])
    quotaProcess.running = true
  }

  // Warn if the CLI's credential cache is readable by other local users.
  // We only stat() it — the contents are never read.
  function checkConfigPermissions() {
    if (permProcess.running) return
    permProcess.command = ["bash", "-c",
      "f=\"${XDG_CONFIG_HOME:-$HOME/.config}/filen-cli/rclone/rclone.conf\"; " +
      "if [ -f \"$f\" ]; then printf '%s %s' \"$(stat -c %a -- \"$f\")\" \"$f\"; fi"]
    permProcess.running = true
  }

  function hardenConfigPermissions() {
    if (permFixProcess.running) return
    permFixProcess.command = ["bash", "-c",
      "f=\"${XDG_CONFIG_HOME:-$HOME/.config}/filen-cli/rclone/rclone.conf\"; " +
      "[ -f \"$f\" ] && chmod 600 -- \"$f\""]
    permFixProcess.running = true
  }

  // ── navigation ─────────────────────────────────────────────────────────

  function list(path, force) {
    if (!cliInstalled) return
    var target = Model.normalizePath(path)
    if (listProcess.running && !force) return
    currentPath = target
    listing = true
    listError = ""
    listProcess.generation = generation
    listProcess.targetPath = target
    // lsjson gives name + size + mtime + IsDir + MimeType in ONE call.
    listProcess.command = rcloneArgs(["lsjson", remoteUrl(target)])
    listProcess.running = true
  }

  function enterDirectory(entry) {
    if (!entry || !entry.dir) return
    var next = Model.joinPath(currentPath, entry.name)
    if (next === null) { showError("Unsupported folder name"); return }
    generation++
    list(next, true)
    navigated(next)
  }

  function goUp() {
    if (atRoot) return
    var parent = Model.parentPath(currentPath)
    generation++
    list(parent, true)
    navigated(parent)
  }

  function goTo(path) {
    var target = Model.normalizePath(path)
    if (target === currentPath) return
    generation++
    list(target, true)
    navigated(target)
  }

  // ── transfers ──────────────────────────────────────────────────────────

  function remotePathFor(entry) {
    return entry ? Model.joinPath(currentPath, entry.name) : null
  }

  // Download to the configured directory via `rclone copy`. rclone takes a
  // destination DIRECTORY and preserves the basename.
  function download(entry, thenOpen) {
    if (!entry) return
    var remote = remotePathFor(entry)
    if (remote === null) { showError("Unsupported name"); return }

    // The remote path keeps the exact bytes (we must fetch the right object),
    // but the LOCAL filename is sanitized: writing an attacker-chosen name
    // verbatim would carry a bidi/control-character attack onto our disk,
    // where a file manager would render "ev<RLO>gnp.exe" as "evexe.gnp".
    var localName = Model.safeLocalName(entry.name)
    if (localName === null) { showError("Unsupported name"); return }

    var id = "t" + (++transferSeq)
    var local = downloadDir + "/" + localName
    var t = Model.makeTransfer(id, "download", entry.display, remote, local)
    t.openWhenDone = thenOpen === true
    t.kindHint = entry.kind
    t.isDir = entry.dir === true
    pushTransfer(t)

    if (entry.dir) {
      // `copy` places the source's CONTENTS into dest, so name the dest after
      // the (sanitized) folder to reproduce the remote structure.
      startTransfer(id, rcloneTransferArgs(["copy", remoteUrl(remote), local]))
    } else {
      // `copyto` writes exactly one destination path, which is what lets us
      // choose the sanitized local filename instead of inheriting the remote.
      startTransfer(id, rcloneTransferArgs(["copyto", remoteUrl(remote), local]))
    }
  }

  function upload(localPath) {
    var p = String(localPath || "")
    if (p === "" || p.charAt(0) !== "/") { showError("Pick a file to upload"); return }
    if (/[\u0000-\u001F]/.test(p)) { showError("Unsupported path"); return }
    var name = p.slice(p.lastIndexOf("/") + 1)
    var id = "t" + (++transferSeq)
    var t = Model.makeTransfer(id, "upload", name, currentPath, p)
    pushTransfer(t)
    // copyto preserves the exact destination name for a single file.
    var destRemote = Model.joinPath(currentPath, name)
    if (destRemote === null) { finishTransfer(id, 1, "Unsupported name"); return }
    startTransfer(id, rcloneTransferArgs(["copyto", p, remoteUrl(destRemote)]))
  }

  function startTransfer(id, argv) {
    // `filen rclone ...` forks a separate rclone binary as its child, and both
    // inherit the SHELL's process group — so signalling just the `filen` pid
    // leaves rclone running, and group-killing our own group would take the
    // shell down with it. `setsid` puts each transfer in its own session and
    // process group, so cancel can signal the whole group safely.
    var wrapped = ["setsid"].concat(argv)
    var proc = transferComponent.createObject(root, { transferId: id, argv: wrapped })
    if (!proc) { finishTransfer(id, 1, "Could not start transfer"); return }
    // Keep an explicit handle: scanning root.children for the process is
    // fragile (ordering, destruction timing), and cancel must never miss.
    var reg = liveProcesses
    reg[id] = proc
    liveProcesses = reg
    proc.running = true
  }

  function pushTransfer(t) {
    var next = transfers.slice()
    next.unshift(t)
    if (next.length > 40) next = next.slice(0, 40)
    transfers = next
    transfersUpdated()
  }

  function updateTransfer(id, changes) {
    var next = []
    var hit = null
    for (var i = 0; i < transfers.length; i++) {
      var t = transfers[i]
      if (t.id === id) {
        var copy = {}
        for (var k in t) copy[k] = t[k]
        for (var c in changes) copy[c] = changes[c]
        hit = copy
        next.push(copy)
      } else next.push(t)
    }
    transfers = next
    transfersUpdated()
    return hit
  }

  function finishTransfer(id, exitCode, output) {
    var prev = null
    for (var i = 0; i < transfers.length; i++) if (transfers[i].id === id) prev = transfers[i]
    var ok = exitCode === 0
    // A group kill surfaces as several different codes depending on which
    // process died first, so trust our own intent flag over the exit code.
    var canceled = (prev && prev.canceling === true)
      || exitCode === 143 || exitCode === 130 || exitCode === -15 || exitCode === 137
    var t = updateTransfer(id, {
      state: ok ? "done" : (canceled ? "canceled" : "failed"),
      error: ok || canceled ? "" : Model.errorMessage(exitCode, output),
      canceling: false
    })
    cancelKillTimer.pending = 0
    if (!ok && !canceled && Model.isAuthError(output)) { signedIn = false; authChecked = true }
    if (!t) return
    if (ok) {
      if (t.kind === "download") {
        showStatus("Downloaded " + t.label)
        if (t.openWhenDone && !t.isDir) openLocal(t.localPath)
        // Only notify when the panel is closed — a toast on top of the panel
        // you are already looking at is noise.
        if (!panelOpen) notify("Download finished", t.label)
      } else {
        showStatus("Uploaded " + t.label)
        list(currentPath, true)
        refreshQuota()
        if (!panelOpen) notify("Upload finished", t.label)
      }
      transferFinished(t.kind, t.label, true)
    } else if (!canceled) {
      showError(t.error)
      notify(t.kind === "download" ? "Download failed" : "Upload failed",
             t.label + " \u2014 " + t.error)
      transferFinished(t.kind, t.label, false)
    }
  }

  // Desktop notification through the shell's own notification service.
  // Body text is CLI-derived, so it is sanitized and passed as a positional
  // argument, never interpolated into a command string.
  function notify(title, body) {
    var t = Model.sanitizeText(title, 60)
    var b = Model.sanitizeText(body, 160)
    if (t === "") return
    Quickshell.execDetached(["notify-send", "-a", "Filen", "-i", "folder-remote", "--", t, b])
  }

  function cancelTransfer(id) {
    var proc = liveProcesses[id]
    if (!proc) return
    // Mark intent first: the exit code from a group kill is not reliably
    // distinguishable from a genuine failure.
    updateTransfer(id, { canceling: true })
    // setsid made this process a group leader, so its pid IS the group id.
    // Negative pid = "whole group", which reaches the rclone child too.
    // SIGTERM first so rclone removes its partial file.
    if (proc.processId > 0) {
      Quickshell.execDetached(["kill", "-TERM", "--", "-" + proc.processId])
      cancelKillTimer.pending = proc.processId
      cancelKillTimer.restart()
    }
    try { proc.signal(15) } catch (e) { /* already gone */ }
  }

  // If a transfer ignores SIGTERM, follow up with SIGKILL on the group.
  Timer {
    id: cancelKillTimer
    property int pending: 0
    interval: 3000
    onTriggered: {
      if (pending > 0) Quickshell.execDetached(["kill", "-KILL", "--", "-" + pending])
      pending = 0
    }
  }

  function forgetProcess(id) {
    var reg = liveProcesses
    if (reg[id] !== undefined) { delete reg[id]; liveProcesses = reg }
  }

  function clearFinishedTransfers() {
    var next = []
    for (var i = 0; i < transfers.length; i++) if (transfers[i].state === "running") next.push(transfers[i])
    transfers = next
    transfersUpdated()
  }

  // ── opening things ─────────────────────────────────────────────────────

  // Hand a LOCAL file to the user's configured handler. xdg-open respects the
  // Omarchy defaults (imv for images, mpv for video, evince for PDF), so the
  // plugin never hardcodes a viewer. The path is argv[1] of a fixed command —
  // no shell, no interpolation.
  function openLocal(path) {
    var p = String(path || "")
    if (p === "" || p.charAt(0) !== "/") return
    Quickshell.execDetached(["xdg-open", p])
  }

  function revealLocal(path) {
    var p = String(path || "")
    if (p === "" || p.charAt(0) !== "/") return
    var dir = p.slice(0, p.lastIndexOf("/"))
    Quickshell.execDetached(["xdg-open", dir === "" ? "/" : dir])
  }

  // Sign-in: hand the user a real terminal running the CLI's own prompt.
  // The plugin does not see, transport, or store the password.
  function openLoginTerminal() {
    if (!cliInstalled) return
    Quickshell.execDetached(["omarchy-launch-terminal", "--", cliPath, "stat", "/"])
    loginWatchTimer.restart()
  }

  function openInstallDocs() {
    Quickshell.execDetached(["omarchy-launch-browser", "https://docs.filen.io/docs/cli-rs/readme"])
  }

  function openWebDrive() {
    Quickshell.execDetached(["omarchy-launch-browser", "https://app.filen.io/"])
  }

  function copyText(text) {
    var s = String(text || "")
    if (s === "") return
    // Text as a positional arg, never interpolated into the script body.
    Quickshell.execDetached(["bash", "-c", "printf %s \"$1\" | wl-copy", "wl-copy", s])
  }

  // ── mutations ──────────────────────────────────────────────────────────

  function removeEntry(entry) {
    if (!entry || rmProcess.running) return
    var remote = remotePathFor(entry)
    if (remote === null) { showError("Unsupported name"); return }
    rmProcess.label = entry.display
    // No --permanent: items go to the Filen trash, so this is recoverable.
    rmProcess.command = nativeArgs(["rm", "--", remote])
    rmProcess.running = true
  }

  function makeDirectory(name) {
    if (!Model.isUsableName(name) || mkdirProcess.running) { showError("Invalid folder name"); return }
    var p = Model.joinPath(currentPath, name)
    if (p === null) { showError("Invalid folder name"); return }
    mkdirProcess.command = nativeArgs(["mkdir", "--", p])
    mkdirProcess.running = true
  }

  // ── processes ──────────────────────────────────────────────────────────

  // Locate the binary. A login shell is used only to resolve PATH the way the
  // user's shell would (the installer appends ~/.filen-cli/bin); the command
  // text is a fixed literal with no interpolation.
  Process {
    id: whichProcess
    running: false
    command: []
    stdout: StdioCollector { id: whichOut; waitForEnd: true }
    onExited: function(exitCode) {
      var p = String(whichOut.text || "").split("\n")[0].trim()
      root.cliChecked = true
      if (exitCode === 0 && p !== "" && p.charAt(0) === "/") {
        root.cliPath = p
        root.cliInstalled = true
        versionProcess.command = [p, "--version"]
        versionProcess.running = true
        root.checkConfigPermissions()
      } else {
        root.cliInstalled = false
        root.cliPath = ""
      }
    }
  }

  Process {
    id: versionProcess
    running: false
    command: []
    stdout: StdioCollector { id: versionOut; waitForEnd: true }
    onExited: function() {
      root.cliVersion = Model.sanitizeText(versionOut.text, 40)
      root.refreshQuota()   // first real call doubles as the auth probe
    }
  }

  Process {
    id: permProcess
    running: false
    command: []
    stdout: StdioCollector { id: permOut; waitForEnd: true }
    onExited: function() {
      var parts = String(permOut.text || "").trim().split(" ")
      if (parts.length < 2) { root.configWorldReadable = false; return }
      var mode = parts[0]
      root.configPath = parts.slice(1).join(" ")
      // Any group/other read bit on a file holding master keys is a problem.
      var g = parseInt(mode.charAt(mode.length - 2), 10)
      var o = parseInt(mode.charAt(mode.length - 1), 10)
      root.configWorldReadable = (isFinite(g) && g !== 0) || (isFinite(o) && o !== 0)
    }
  }

  Process {
    id: permFixProcess
    running: false
    command: []
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.showStatus("Credential file locked to your user only")
        root.checkConfigPermissions()
      } else {
        root.showError("Could not change permissions")
      }
    }
  }

  Process {
    id: quotaProcess
    property int generation: 0
    running: false
    command: []
    stdout: StdioCollector { id: quotaOut; waitForEnd: true }
    stderr: StdioCollector { id: quotaErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (generation !== root.generation) return
      root.authChecked = true
      var all = root.combinedOutput(quotaOut.text, quotaErr.text)
      if (exitCode !== 0) {
        if (Model.isAuthError(all)) { root.signedIn = false; root.quotaLoaded = false }
        // A non-auth failure says nothing about credentials; leave signedIn.
        return
      }
      root.signedIn = true
      var s = Model.parseAbout(quotaOut.text)
      if (s) {
        root.usedBytes = s.used
        root.totalBytes = s.total
        root.quotaLoaded = true
      }
    }
  }

  Process {
    id: listProcess
    property int generation: 0
    property string targetPath: "/"
    running: false
    command: []
    stdout: StdioCollector { id: listOut; waitForEnd: true }
    stderr: StdioCollector { id: listErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.listing = false
      if (generation !== root.generation) return
      var all = root.combinedOutput(listOut.text, listErr.text)
      if (exitCode !== 0) {
        if (Model.isAuthError(all)) {
          root.signedIn = false
          root.authChecked = true
          root.entries = []
          root.listError = ""
          return
        }
        root.listError = Model.errorMessage(exitCode, all)
        root.entries = []
        root.entriesUpdated()
        return
      }
      root.signedIn = true
      root.authChecked = true
      var parsed = Model.parseLsJson(listOut.text)
      if (parsed === null) {
        root.listError = "Unexpected response from the Filen CLI"
        root.entries = []
        root.entriesUpdated()
        return
      }
      var sorted = Model.sortEntries(parsed)
      if (!Model.sameEntries(sorted, root.entries)) root.entries = sorted
      root.listLoaded = true
      root.listError = ""
      root.entriesUpdated()
    }
  }

  Process {
    id: rmProcess
    property string label: ""
    running: false
    command: []
    stdout: StdioCollector { id: rmOut; waitForEnd: true }
    stderr: StdioCollector { id: rmErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.showStatus("Moved " + label + " to Filen trash")
        root.list(root.currentPath, true)
        root.refreshQuota()
      } else {
        root.showError(Model.errorMessage(exitCode, root.combinedOutput(rmOut.text, rmErr.text)))
      }
    }
  }

  Process {
    id: mkdirProcess
    running: false
    command: []
    stdout: StdioCollector { id: mkdirOut; waitForEnd: true }
    stderr: StdioCollector { id: mkdirErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.showStatus("Folder created")
        root.list(root.currentPath, true)
      } else {
        root.showError(Model.errorMessage(exitCode, root.combinedOutput(mkdirOut.text, mkdirErr.text)))
      }
    }
  }

  // One Process per transfer so several can run concurrently.
  //
  // Progress: rclone writes one JSON stats object per second to stderr. We
  // read it with SplitParser (line-delimited) rather than StdioCollector so
  // the panel updates DURING the transfer instead of only at exit. stdout is
  // still collected whole for the failure message.
  Component {
    id: transferComponent
    Process {
      id: xfer
      property string transferId: ""
      property var argv: []
      property string tailErr: ""
      running: false
      command: argv

      stdout: StdioCollector { id: xferOut; waitForEnd: true }

      stderr: SplitParser {
        splitMarker: "\n"
        onRead: function(line) {
          // Keep a bounded tail for diagnosing a failure at exit.
          if (xfer.tailErr.length < Model.MAX_STDERR_BYTES) xfer.tailErr += line + "\n"
          var p = Model.parseRcloneProgress(line)
          if (p) root.updateTransfer(xfer.transferId, {
            bytes: p.bytes, totalBytes: p.totalBytes,
            speed: p.speed, eta: p.eta, fraction: p.fraction
          })
        }
      }

      onExited: function(exitCode) {
        root.forgetProcess(transferId)
        root.finishTransfer(transferId, exitCode,
                            root.combinedOutput(xferOut.text, xfer.tailErr))
        destroy()
      }
    }
  }

  // ── timers ─────────────────────────────────────────────────────────────

  Timer {
    id: statusTimer
    interval: 4000
    onTriggered: { root.actionStatus = ""; root.actionError = "" }
  }

  // After sending the user to a login terminal, poll briefly so the panel
  // flips to signed-in the moment they finish.
  Timer {
    id: loginWatchTimer
    interval: 3000
    repeat: true
    property int ticks: 0
    onTriggered: {
      ticks++
      if (root.signedIn || ticks > 40) { stop(); ticks = 0; return }
      root.refreshQuota()
    }
    onRunningChanged: if (running) ticks = 0
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: root.cliInstalled && root.signedIn
    repeat: true
    onTriggered: root.refreshQuota()
  }

  Component.onCompleted: start()
}
