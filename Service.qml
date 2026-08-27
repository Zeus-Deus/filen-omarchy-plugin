import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Drives the official Filen CLI (`filen`, the Rust rewrite) as a child
// process and exposes its state as plain QML properties.
//
// ── Security model ────────────────────────────────────────────────────────
// * The plugin NEVER handles the account password. Sign-in happens in a real
//   terminal running the CLI's own prompt; the CLI stores the session in the
//   system keyring (gnome-keyring / org.freedesktop.secrets). We only ever
//   observe whether a command succeeded.
// * No secret is ever passed in argv. /proc/<pid>/cmdline is world-readable,
//   so argv is a public channel. We pass nothing sensitive at all.
// * FILEN_CLI_PASSWORD / FILEN_CLI_EMAIL are never set. Environment is
//   inherited as-is; we do not inject credentials into any child.
// * Every command runs WITHOUT a shell: `command` is an argv array, so
//   filenames containing ;, $(), backticks, newlines etc. are inert data.
//   `--` terminates option parsing so a name starting with '-' can never be
//   read as a flag.
// * The CLI's auth config file (master keys + private key + API key in
//   plaintext) is never read, copied, or displayed by this plugin.
// * `export-api-key` / `export-auth-config` are never invoked.
// * --skip-update on every call: the CLI's auto-updater replaces its own
//   binary, and that must be a deliberate user action, never a side effect
//   of opening a panel.
// * All CLI output is treated as attacker-influenced (shared folders can be
//   named anything) and is size-capped + sanitized in Model.js before display.
Item {
  id: root

  property var settings: ({})

  // ── availability / auth ────────────────────────────────────────────────
  property bool cliChecked: false
  property bool cliInstalled: false
  property string cliPath: ""
  property string cliVersion: ""
  property bool signedIn: false
  property bool authChecked: false

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

  // ── focused-entry detail (lazy stat) ───────────────────────────────────
  property string detailPath: ""
  property var detailData: null

  // ── transfers ──────────────────────────────────────────────────────────
  property var transfers: []
  property int transferSeq: 0

  // ── transient feedback ─────────────────────────────────────────────────
  property string actionStatus: ""
  property string actionError: ""

  // Invalidates in-flight responses whose context has changed (path change,
  // sign-out, etc.) so a late reply can never repaint a newer view.
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
  // Every invocation goes through here. No shell, ever. `--` separates flags
  // from operands so a path beginning with '-' is treated as a path.
  function cliArgs(args) {
    var base = [root.cliPath, "--skip-update", "--quiet"]
    return base.concat(args)
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
  }

  function refreshQuota() {
    if (!cliInstalled || quotaProcess.running) return
    quotaProcess.generation = generation
    quotaProcess.command = cliArgs(["--json", "stat", "--", "/"])
    quotaProcess.running = true
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
    listProcess.command = cliArgs(["--json", "ls", "--", target])
    listProcess.running = true
  }

  function enterDirectory(entry) {
    if (!entry || !entry.dir) return
    var next = Model.joinPath(currentPath, entry.name)
    if (next === null) { showError("Unsupported folder name"); return }
    generation++
    detailPath = ""
    detailData = null
    list(next, true)
    navigated(next)
  }

  function goUp() {
    if (atRoot) return
    var parent = Model.parentPath(currentPath)
    generation++
    detailPath = ""
    detailData = null
    list(parent, true)
    navigated(parent)
  }

  function goTo(path) {
    var target = Model.normalizePath(path)
    if (target === currentPath) return
    generation++
    detailPath = ""
    detailData = null
    list(target, true)
    navigated(target)
  }

  // ── lazy detail for the focused row ────────────────────────────────────

  function loadDetail(entry) {
    if (!entry || entry.dir || !cliInstalled) { detailData = null; detailPath = ""; return }
    var p = Model.joinPath(currentPath, entry.name)
    if (p === null) return
    if (p === detailPath) return
    detailPath = p
    detailData = null
    if (detailProcess.running) return
    detailProcess.generation = generation
    detailProcess.wantPath = p
    detailProcess.command = cliArgs(["--json", "stat", "--", p])
    detailProcess.running = true
  }

  // ── transfers ──────────────────────────────────────────────────────────

  function remotePathFor(entry) {
    return entry ? Model.joinPath(currentPath, entry.name) : null
  }

  // Download to the configured directory. The CLI writes into a destination
  // DIRECTORY, so the local filename is chosen by the CLI from the remote
  // name — we validate the name first and refuse anything unusable.
  function download(entry, thenOpen) {
    if (!entry || entry.dir === undefined) return
    var remote = remotePathFor(entry)
    if (remote === null) { showError("Unsupported name"); return }
    if (Model.localTargetName(entry.name) === null) { showError("Unsupported name"); return }

    var id = "t" + (++transferSeq)
    var local = downloadDir + "/" + entry.name
    var t = Model.makeTransfer(id, "download", entry.display, remote, local)
    t.openWhenDone = thenOpen === true
    t.kindHint = entry.kind
    pushTransfer(t)

    var proc = transferComponent.createObject(root, {
      transferId: id,
      argv: cliArgs(["download", "--", remote, downloadDir])
    })
    if (!proc) { finishTransfer(id, 1, "Could not start download") ; return }
    proc.running = true
  }

  function upload(localPath) {
    var p = String(localPath || "")
    if (p === "" || p.charAt(0) !== "/") { showError("Pick a file to upload"); return }
    var name = p.slice(p.lastIndexOf("/") + 1)
    var id = "t" + (++transferSeq)
    var t = Model.makeTransfer(id, "upload", name, currentPath, p)
    pushTransfer(t)

    var proc = transferComponent.createObject(root, {
      transferId: id,
      argv: cliArgs(["upload", "--", p, currentPath])
    })
    if (!proc) { finishTransfer(id, 1, "Could not start upload"); return }
    proc.running = true
  }

  function pushTransfer(t) {
    var next = transfers.slice()
    next.unshift(t)
    if (next.length > 40) next = next.slice(0, 40)
    transfers = next
    transfersUpdated()
  }

  function transferById(id) {
    for (var i = 0; i < transfers.length; i++) if (transfers[i].id === id) return transfers[i]
    return null
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

  function finishTransfer(id, exitCode, stderr) {
    var ok = exitCode === 0
    var t = updateTransfer(id, {
      state: ok ? "done" : (exitCode === 143 || exitCode === 130 ? "canceled" : "failed"),
      error: ok ? "" : Model.errorMessage(exitCode, stderr)
    })
    if (!ok && Model.isAuthError(stderr)) { signedIn = false; authChecked = true }
    if (ok && t) {
      if (t.kind === "download") {
        showStatus("Downloaded " + t.label)
        if (t.openWhenDone) openLocal(t.localPath)
      } else {
        showStatus("Uploaded " + t.label)
        list(currentPath, true)
        refreshQuota()
      }
    } else if (t && t.state === "failed") {
      showError(t.error)
    }
  }

  function cancelTransfer(id) {
    var kids = root.children
    for (var i = 0; i < kids.length; i++) {
      var k = kids[i]
      if (k && k.transferId === id && k.running) { k.signal(15); return }
    }
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
  // plugin never hardcodes a viewer. Path travels as argv[1] of a fixed
  // command — no shell, no interpolation.
  function openLocal(path) {
    var p = String(path || "")
    if (p === "" || p.charAt(0) !== "/") return
    Quickshell.execDetached(["xdg-open", p])
  }

  function revealLocal(path) {
    var p = String(path || "")
    if (p === "" || p.charAt(0) !== "/") return
    Quickshell.execDetached(["xdg-open", p.slice(0, p.lastIndexOf("/")) || "/"])
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

  // ── delete ─────────────────────────────────────────────────────────────

  function removeEntry(entry) {
    if (!entry || rmProcess.running) return
    var remote = remotePathFor(entry)
    if (remote === null) { showError("Unsupported name"); return }
    rmProcess.generation = generation
    rmProcess.label = entry.display
    // -y skips the CLI's own confirmation; the panel already confirmed.
    // Items go to the Filen trash (no --no-trash) so this is recoverable.
    rmProcess.command = cliArgs(["rm", "-y", "--", remote])
    rmProcess.running = true
  }

  function makeDirectory(name) {
    if (!Model.isUsableName(name) || mkdirProcess.running) { showError("Invalid folder name"); return }
    var p = Model.joinPath(currentPath, name)
    if (p === null) { showError("Invalid folder name"); return }
    mkdirProcess.generation = generation
    mkdirProcess.command = cliArgs(["mkdir", "--", p])
    mkdirProcess.running = true
  }

  // ── processes ──────────────────────────────────────────────────────────

  // Locate the binary. Uses a login shell only to resolve PATH the way the
  // user's own shell would (the installer appends ~/.filen-cli/bin there);
  // the command text is a fixed literal with no interpolation.
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
      // First real call doubles as the auth probe.
      root.refreshQuota()
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
      var err = String(quotaErr.text || "")
      if (exitCode !== 0) {
        if (Model.isAuthError(err)) { root.signedIn = false; root.quotaLoaded = false; return }
        root.signedIn = true
        return
      }
      root.signedIn = true
      var s = Model.parseStat(quotaOut.text)
      if (s && s.type === "drive") {
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
      var err = String(listErr.text || "")
      if (exitCode !== 0) {
        if (Model.isAuthError(err)) {
          root.signedIn = false
          root.authChecked = true
          root.entries = []
          root.listError = ""
          return
        }
        root.listError = Model.errorMessage(exitCode, err)
        root.entries = []
        root.entriesUpdated()
        return
      }
      root.signedIn = true
      root.authChecked = true
      var parsed = Model.parseListing(listOut.text)
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
    id: detailProcess
    property int generation: 0
    property string wantPath: ""
    running: false
    command: []
    stdout: StdioCollector { id: detailOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (generation !== root.generation) return
      if (wantPath !== root.detailPath) return
      if (exitCode !== 0) { root.detailData = null; return }
      root.detailData = Model.parseStat(detailOut.text)
    }
  }

  Process {
    id: rmProcess
    property int generation: 0
    property string label: ""
    running: false
    command: []
    stderr: StdioCollector { id: rmErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.showStatus("Moved " + label + " to Filen trash")
        root.list(root.currentPath, true)
        root.refreshQuota()
      } else {
        root.showError(Model.errorMessage(exitCode, rmErr.text))
      }
    }
  }

  Process {
    id: mkdirProcess
    property int generation: 0
    running: false
    command: []
    stderr: StdioCollector { id: mkdirErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.showStatus("Folder created")
        root.list(root.currentPath, true)
      } else {
        root.showError(Model.errorMessage(exitCode, mkdirErr.text))
      }
    }
  }

  // One Process per transfer, created on demand so several can run at once.
  Component {
    id: transferComponent
    Process {
      property string transferId: ""
      property var argv: []
      running: false
      command: argv
      stderr: StdioCollector { waitForEnd: true }
      onExited: function(exitCode) {
        root.finishTransfer(transferId, exitCode, stderr ? stderr.text : "")
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
  // flips to signed-in the moment they finish, without them reopening it.
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

  // Background quota refresh keeps the bar honest while the panel is closed.
  Timer {
    interval: root.refreshIntervalSec * 1000
    running: root.cliInstalled && root.signedIn
    repeat: true
    onTriggered: root.refreshQuota()
  }

  Component.onCompleted: start()
}
