// Pure helpers for the Filen plugin. No Qt imports — this file is loaded by
// QML via `import "Model.js" as Model` AND by `node --test tests/model.test.js`.
//
// Threat model: every string that arrives from the `filen` CLI is treated as
// attacker-influenced. A shared folder, a public link someone sent you, or a
// synced device can put arbitrary bytes in a filename: newlines, ANSI escapes,
// leading dashes, "..", NUL, RTL overrides. Nothing here may assume otherwise.

// Ceilings. The CLI is a child process; a hostile or wedged one must never be
// able to grow the shell's heap without bound.
var MAX_RESPONSE_BYTES = 4 * 1024 * 1024;  // one `ls` of a huge directory
var MAX_STDERR_BYTES = 8 * 1024;
var MAX_ENTRIES = 5000;                     // rows kept from a single listing
var MAX_NAME_DISPLAY = 120;                 // chars shown in a row
var MAX_PATH_DEPTH = 64;

// ---------------------------------------------------------------- text safety

// Strip everything that could corrupt the panel or the surrounding terminal
// when a name is rendered or logged. Control chars (including NUL, ESC, CR,
// LF), Unicode bidi overrides, and zero-width joiners are removed rather than
// escaped: the panel shows names, it does not need to round-trip them.
// The real path used for CLI calls is kept separately and never passes here.
function sanitizeText(value, limit) {
  var s = String(value === undefined || value === null ? "" : value);
  // C0 + DEL + C1 -> space, not deletion: "a\nb" must read "a b", never "ab"
  // (deleting would let a newline disguise two words as one identifier).
  s = s.replace(/[\u0000-\u001F\u007F-\u009F]/g, " ");
  // bidi overrides / embedding (RTL filename spoofing) — removed outright
  s = s.replace(/[\u200E\u200F\u202A-\u202E\u2066-\u2069]/g, "");
  // zero-width
  s = s.replace(/[\u200B-\u200D\uFEFF]/g, "");
  s = s.replace(/\s+/g, " ").replace(/^ +| +$/g, "");
  var max = limit === undefined ? MAX_NAME_DISPLAY : limit;
  if (s.length > max) s = s.slice(0, Math.max(0, max - 1)) + "\u2026";
  return s;
}

// A name is *usable* (safe to send back to the CLI as part of a path) only if
// it cannot change the meaning of a path or an argv element. We reject rather
// than repair: acting on a path we had to rewrite is how you delete the wrong
// file.
//
// Note the deliberate narrowness. Because commands are executed as an argv
// ARRAY (never a shell string) and native verbs get `--`, the only characters
// that can actually change meaning are NUL (terminates a C string) and "/"
// (path separator). Tabs, newlines, escapes and leading dashes are legal on
// the server and DO occur in real drives — rejecting them would make those
// files invisible in the panel and impossible to delete, which is worse than
// displaying them. They are neutralised at render time by sanitizeText().
function isUsableName(name) {
  var s = String(name === undefined || name === null ? "" : name);
  if (s === "" || s === "." || s === "..") return false;
  if (s.length > 255) return false;
  if (s.indexOf("\u0000") !== -1) return false;        // NUL only
  if (s.indexOf("/") !== -1) return false;             // path separator
  return true;
}

// ---------------------------------------------------------------- paths

// Filen paths are POSIX-like and always absolute from the drive root.
// Built by joining validated segments — never by string-concatenating user
// input into a shell command (we never use a shell at all; see Service.qml).
function joinPath(base, name) {
  var b = normalizePath(base);
  if (!isUsableName(name)) return null;
  return b === "/" ? "/" + name : b + "/" + name;
}

function normalizePath(path) {
  var s = String(path === undefined || path === null ? "/" : path);
  if (s === "") return "/";
  var parts = s.split("/");
  var out = [];
  for (var i = 0; i < parts.length; i++) {
    var p = parts[i];
    if (p === "" || p === ".") continue;
    if (p === "..") { out.pop(); continue; }
    out.push(p);
    if (out.length > MAX_PATH_DEPTH) break;
  }
  return "/" + out.join("/");
}

function parentPath(path) {
  var n = normalizePath(path);
  if (n === "/") return "/";
  var idx = n.lastIndexOf("/");
  return idx <= 0 ? "/" : n.slice(0, idx);
}

function basename(path) {
  var n = normalizePath(path);
  if (n === "/") return "/";
  return n.slice(n.lastIndexOf("/") + 1);
}

// Breadcrumb segments for display: [{label, path}], root first.
function crumbs(path) {
  var n = normalizePath(path);
  var out = [{ label: "/", path: "/" }];
  if (n === "/") return out;
  var parts = n.split("/").slice(1);
  var acc = "";
  for (var i = 0; i < parts.length; i++) {
    acc += "/" + parts[i];
    out.push({ label: sanitizeText(parts[i], 40), path: acc });
  }
  return out;
}

// ---------------------------------------------------------------- JSON

// Bounded, total JSON parse. Returns null on anything unexpected rather than
// throwing into a QML signal handler (which would tear down the binding).
function parseJson(text) {
  var s = String(text === undefined || text === null ? "" : text);
  if (s.length === 0 || s.length > MAX_RESPONSE_BYTES) return null;
  try {
    return JSON.parse(s);
  } catch (e) {
    return null;
  }
}

// `filen --json ls <dir>` => {"directories": string[], "files": string[]}
// Names only — no sizes, no dates. Sizes require a per-entry `stat`, which the
// service does lazily for the focused row only.
function parseListing(text) {
  var data = parseJson(text);
  if (!data || typeof data !== "object") return null;
  var dirs = data.directories instanceof Array ? data.directories : [];
  var files = data.files instanceof Array ? data.files : [];
  var out = [];
  var i;
  for (i = 0; i < dirs.length && out.length < MAX_ENTRIES; i++) {
    var dn = dirs[i];
    if (typeof dn !== "string" || !isUsableName(dn)) continue;
    out.push({ name: dn, display: sanitizeText(dn), dir: true, kind: "directory" });
  }
  for (i = 0; i < files.length && out.length < MAX_ENTRIES; i++) {
    var fn = files[i];
    if (typeof fn !== "string" || !isUsableName(fn)) continue;
    out.push({ name: fn, display: sanitizeText(fn), dir: false, kind: kindOf(fn) });
  }
  return out;
}

// `filen --json stat <path>` for a file / dir / the drive root.
function parseStat(text) {
  var d = parseJson(text);
  if (!d || typeof d !== "object") return null;
  if (d.type === "drive") {
    var used = toNumber(d.usedStorage);
    var total = toNumber(d.totalStorage);
    if (used === null || total === null || total <= 0) return null;
    return { type: "drive", used: used, total: total };
  }
  if (d.type === "file") {
    return {
      type: "file",
      name: sanitizeText(d.name),
      size: toNumber(d.size),
      modified: toNumber(d.modified),
      created: toNumber(d.created),
      uuid: typeof d.uuid === "string" ? sanitizeText(d.uuid, 64) : ""
    };
  }
  if (d.type === "directory") {
    return {
      type: "directory",
      name: sanitizeText(d.name),
      created: toNumber(d.created),
      uuid: typeof d.uuid === "string" ? sanitizeText(d.uuid, 64) : ""
    };
  }
  return null;
}

function toNumber(v) {
  if (v === undefined || v === null || v === "") return null;
  var n = Number(v);
  return isFinite(n) ? n : null;
}

// `filen rclone lsjson filen:<path>` => array of
//   {Path, Name, Size, MimeType, ModTime, IsDir, ID}
// This is the preferred listing source: one call yields sizes and dates,
// where the native `ls --json` returns names only.
//
// ModTime is an RFC3339 string, NOT epoch ms — parsed here into ms so the
// rest of the plugin sees one time representation.
function parseLsJson(text) {
  var data = parseJson(text);
  if (!(data instanceof Array)) return null;
  var out = [];
  for (var i = 0; i < data.length && out.length < MAX_ENTRIES; i++) {
    var e = data[i];
    if (!e || typeof e !== "object") continue;
    var name = typeof e.Name === "string" ? e.Name : "";
    if (!isUsableName(name)) continue;      // drops "..", "a/b", control bytes
    var isDir = e.IsDir === true;
    var size = toNumber(e.Size);
    out.push({
      name: name,
      display: sanitizeText(name),
      dir: isDir,
      kind: isDir ? "directory" : kindOf(name),
      size: isDir || size === null || size < 0 ? null : size,
      modified: parseRfc3339(e.ModTime),
      mime: typeof e.MimeType === "string" ? sanitizeText(e.MimeType, 64) : ""
    });
  }
  return out;
}

// Bounded RFC3339 -> epoch ms. Returns null rather than NaN on anything odd.
function parseRfc3339(value) {
  var s = String(value || "");
  if (s === "" || s.length > 64) return null;
  var ms = Date.parse(s);
  return isFinite(ms) && ms > 0 ? ms : null;
}

// `filen rclone about filen: --json` => {total, used, free}
function parseAbout(text) {
  var d = parseJson(text);
  if (!d || typeof d !== "object") return null;
  var used = toNumber(d.used);
  var total = toNumber(d.total);
  if (used === null || total === null || total <= 0) return null;
  return { used: used, total: total, free: toNumber(d.free) };
}

// ---------------------------------------------------------------- progress

// rclone with `--use-json-log --stats 1s --stats-log-level NOTICE` writes one
// JSON object per line to stderr, each carrying a `stats` block:
//   {"level":"notice","msg":"...","stats":{"bytes":N,"totalBytes":N,
//    "speed":N,"eta":N|null,"transfers":N,"errors":N,...}}
// Lines are parsed individually so a partial trailing line (we read a live
// stream) can never break the parse. Returns the LAST usable stats block.
function parseRcloneProgress(chunk) {
  var text = String(chunk || "");
  if (text.length > MAX_RESPONSE_BYTES) text = text.slice(-MAX_RESPONSE_BYTES);
  var lines = text.split("\n");
  var latest = null;
  for (var i = lines.length - 1; i >= 0; i--) {
    var line = lines[i];
    if (line.length < 2 || line.charAt(0) !== "{") continue;
    var obj = parseJson(line);
    if (!obj || typeof obj !== "object" || !obj.stats) continue;
    var s = obj.stats;
    var bytes = toNumber(s.bytes);
    var total = toNumber(s.totalBytes);
    if (bytes === null) continue;
    latest = {
      bytes: bytes,
      totalBytes: total === null || total <= 0 ? null : total,
      speed: toNumber(s.speed),
      eta: toNumber(s.eta),
      errors: toNumber(s.errors) || 0,
      fraction: (total !== null && total > 0)
        ? Math.max(0, Math.min(1, bytes / total)) : null
    };
    break;
  }
  return latest;
}

function formatSpeed(bytesPerSec) {
  var n = Number(bytesPerSec);
  if (!isFinite(n) || n <= 0) return "";
  return formatSize(n) + "/s";
}

function formatEta(seconds) {
  var n = Number(seconds);
  if (!isFinite(n) || n <= 0) return "";
  if (n < 60) return Math.round(n) + "s left";
  if (n < 3600) return Math.round(n / 60) + "m left";
  return Math.round(n / 3600) + "h left";
}

// ---------------------------------------------------------------- file kinds

var IMAGE_EXT = ["png","jpg","jpeg","gif","webp","bmp","avif","jxl","tiff","tif","ico","svg"];
var VIDEO_EXT = ["mp4","mkv","webm","mov","avi","m4v","wmv","flv","mpg","mpeg"];
var AUDIO_EXT = ["mp3","flac","wav","ogg","opus","m4a","aac","wma"];
var DOC_EXT   = ["pdf","epub","djvu"];
var TEXT_EXT  = ["txt","md","markdown","json","yaml","yml","toml","ini","conf",
                 "log","csv","tsv","xml","html","css","js","ts","py","rs","go",
                 "sh","bash","c","h","cpp","hpp","java","rb","lua","sql"];
var ARCHIVE_EXT = ["zip","tar","gz","tgz","bz2","xz","zst","7z","rar"];

function extensionOf(name) {
  var s = String(name || "");
  var dot = s.lastIndexOf(".");
  if (dot <= 0 || dot === s.length - 1) return "";
  return s.slice(dot + 1).toLowerCase();
}

function kindOf(name) {
  var e = extensionOf(name);
  if (e === "") return "file";
  if (IMAGE_EXT.indexOf(e) !== -1) return "image";
  if (VIDEO_EXT.indexOf(e) !== -1) return "video";
  if (AUDIO_EXT.indexOf(e) !== -1) return "audio";
  if (DOC_EXT.indexOf(e) !== -1) return "document";
  if (TEXT_EXT.indexOf(e) !== -1) return "text";
  if (ARCHIVE_EXT.indexOf(e) !== -1) return "archive";
  return "file";
}

// Nerd Font glyphs, matching the vocabulary the first-party panels use.
function iconFor(entry) {
  if (!entry) return "󰈤";
  if (entry.dir) return "󰉋";
  switch (entry.kind) {
    case "image":    return "󰋩";
    case "video":    return "󰕧";
    case "audio":    return "󰎇";
    case "document": return "󰈦";
    case "text":     return "󰈙";
    case "archive":  return "󰗀";
    default:         return "󰈤";
  }
}

// Only these open in a viewer. Everything else must be downloaded first and
// handed to xdg-open explicitly by the user.
//
// Opening is gated on the extension because a drive can hold files someone
// else put there (shared folders, received links), and xdg-open hands the
// file to whatever handler its type maps to. A `.desktop` launcher, a shell
// script or an HTML page would be *executed* or rendered with scripts rather
// than viewed — so those are never auto-opened, only revealed in the folder.
var NEVER_OPEN_EXT = ["desktop", "sh", "bash", "zsh", "fish", "html", "htm",
                      "xhtml", "js", "mjs", "py", "rb", "pl", "lua", "jar",
                      "appimage", "run", "bin", "exe", "msi", "bat", "cmd",
                      "ps1", "vbs", "lnk", "svg"];

function isPreviewable(entry) {
  if (!entry || entry.dir) return false;
  if (NEVER_OPEN_EXT.indexOf(extensionOf(entry.name)) !== -1) return false;
  var k = entry.kind;
  return k === "image" || k === "video" || k === "audio" || k === "document" || k === "text";
}

// Same rule for a LOCAL path (a finished download), by its basename.
function isSafeToOpen(path) {
  var s = String(path || "");
  var name = s.slice(s.lastIndexOf("/") + 1);
  return isPreviewable({ name: name, dir: false, kind: kindOf(name) });
}

// ---------------------------------------------------------------- formatting

function formatSize(bytes) {
  var n = Number(bytes);
  if (!isFinite(n) || n < 0) return "";
  if (n < 1024) return n + " B";
  var units = ["KiB", "MiB", "GiB", "TiB", "PiB"];
  var v = n / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return (v >= 100 ? v.toFixed(0) : v >= 10 ? v.toFixed(1) : v.toFixed(2)) + " " + units[i];
}

function formatPercent(used, total) {
  var u = Number(used), t = Number(total);
  if (!isFinite(u) || !isFinite(t) || t <= 0) return 0;
  return Math.max(0, Math.min(1, u / t));
}

// The CLI emits epoch milliseconds for modified/created.
function formatDate(ms) {
  var n = Number(ms);
  if (!isFinite(n) || n <= 0) return "";
  var d = new Date(n);
  if (isNaN(d.getTime())) return "";
  var pad = function (x) { return x < 10 ? "0" + x : String(x); };
  return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
    + " " + pad(d.getHours()) + ":" + pad(d.getMinutes());
}

function relativeTime(ms, nowMs) {
  var n = Number(ms);
  var now = Number(nowMs) || Date.now();
  if (!isFinite(n) || n <= 0) return "";
  var diff = Math.floor((now - n) / 1000);
  if (diff < 0) return "just now";
  if (diff < 60) return diff + "s ago";
  if (diff < 3600) return Math.floor(diff / 60) + "m ago";
  if (diff < 86400) return Math.floor(diff / 3600) + "h ago";
  return Math.floor(diff / 86400) + "d ago";
}

// ---------------------------------------------------------------- errors

// Map a CLI failure to something a human can act on. `stderr` is CLI-controlled
// text, so it is sanitized and truncated before it ever reaches a Text element.
function errorMessage(exitCode, stderr) {
  if (isAuthError(stderr)) return "Not signed in to Filen";
  if (isNotFoundError(stderr)) return "That folder no longer exists";
  if (isConfigRaceError(stderr)) return "Filen CLI config was busy \u2014 try again";
  // rclone logs several timestamped lines; show only the most informative one
  // rather than dumping the whole stream into the panel.
  var text = sanitizeText(firstMeaningfulLine(stderr), 160);
  if (text === "") return "Filen CLI failed (exit " + exitCode + ")";
  return text;
}

// Pick the line most worth showing a human out of a multi-line CLI dump, and
// strip the leading "2026/08/27 23:39:50 ERROR : " decoration.
function firstMeaningfulLine(text) {
  var lines = String(text || "").split("\n");
  var best = "";
  for (var i = 0; i < lines.length; i++) {
    var l = lines[i].replace(/^\s+|\s+$/g, "");
    if (l === "" || l === "[" || l === "]") continue;
    // drop rclone's timestamp + level prefix
    l = l.replace(/^\d{4}\/\d{2}\/\d{2}\s+\d{2}:\d{2}:\d{2}\s+/, "");
    l = l.replace(/^(ERROR|NOTICE|CRITICAL|INFO|DEBUG)\s*:\s*/, "");
    l = l.replace(/^\s+|\s+$/g, "");
    if (l === "") continue;
    if (best === "") best = l;
    // an explicit "error:"/"failed" line beats a generic first line
    if (/error|failed|cannot|denied/i.test(l)) return l;
  }
  return best;
}

// The CLI has no `whoami`. When it needs credentials and has no TTY it fails
// with this specific message on stderr and a non-zero exit. That is our
// "signed out" signal — checked as a substring because the CLI decorates it
// with a ✘ and colour codes.
function isAuthError(stderr) {
  var s = String(stderr || "");
  return s.indexOf("Failed to read input from terminal") !== -1
      || s.indexOf("Invalid credentials") !== -1
      || s.indexOf("Please ensure that the terminal supports interactive input") !== -1;
}

// Network failure looks IDENTICAL to being signed out: with no connectivity
// the CLI cannot validate the stored session, falls back to prompting for
// credentials, finds no TTY, and prints the same "Failed to read input from
// terminal" message. Treating that as "signed out" would show a login button
// every time the Wi-Fi drops — and worse, imply the saved session was lost.
//
// So the caller must confirm connectivity before acting on an auth error.
// These markers identify the network case when the CLI is more forthcoming.
function isNetworkError(text) {
  var s = String(text || "");
  return s.indexOf("dial tcp") !== -1
      || s.indexOf("no such host") !== -1
      || s.indexOf("connection refused") !== -1
      || s.indexOf("network is unreachable") !== -1
      || s.indexOf("Temporary failure in name resolution") !== -1
      || s.indexOf("i/o timeout") !== -1
      || s.indexOf("TLS handshake timeout") !== -1
      || /error sending request|failed to lookup address/i.test(s);
}

function isNotFoundError(stderr) {
  var s = String(stderr || "");
  return s.indexOf("No such file or directory") !== -1
      || s.indexOf("Failed to find item") !== -1
      || s.indexOf("directory not found") !== -1
      || s.indexOf("object not found") !== -1;
}

// Every `filen rclone ...` invocation REWRITES ~/.config/filen-cli/rclone/
// rclone.conf as it starts. When two invocations overlap, one can read the
// file while the other is mid-write and fail with:
//   CRITICAL: Failed to create file system for "filen:/x":
//   didn't find section in config file ("filen")
// This is transient and entirely a local-file race — not an auth failure and
// not a missing path — so the caller should simply retry rather than show it.
function isConfigRaceError(text) {
  var s = String(text || "");
  return s.indexOf("didn't find section in config file") !== -1
      || s.indexOf("Failed to create file system") !== -1;
}

// Oversized/failed transfer detection, mirroring the passpage plugin: head
// closing the pipe makes the producer fail its write.
function oversized(exitCode, output) {
  return exitCode === 23 || exitCode === 141
    || String(output || "").length >= MAX_RESPONSE_BYTES;
}

// ---------------------------------------------------------------- listing ops

function sortEntries(entries) {
  var list = (entries || []).slice();
  list.sort(function (a, b) {
    if (a.dir !== b.dir) return a.dir ? -1 : 1;
    return a.display.localeCompare(b.display, undefined, { numeric: true, sensitivity: "base" });
  });
  return list;
}

// Cheap identity check so the Repeater is not rebuilt (and an open dialog
// destroyed) when a refresh returns the same rows.
function sameEntries(a, b) {
  var x = a || [], y = b || [];
  if (x.length !== y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (x[i].name !== y[i].name) return false;
    if (x[i].dir !== y[i].dir) return false;
    if (x[i].size !== y[i].size) return false;
  }
  return true;
}

function filterEntries(entries, query) {
  var q = String(query || "").toLowerCase().replace(/^\s+|\s+$/g, "");
  if (q === "") return entries || [];
  var out = [];
  var list = entries || [];
  for (var i = 0; i < list.length; i++) {
    if (list[i].display.toLowerCase().indexOf(q) !== -1) out.push(list[i]);
  }
  return out;
}

// ---------------------------------------------------------------- local paths

// Guard for the configured download directory. Must be an absolute path with
// no shell metacharacters and no traversal; anything else falls back to the
// default so a bad setting can never redirect writes somewhere surprising.
function validatedDownloadDir(value, home) {
  var s = String(value || "").replace(/^\s+|\s+$/g, "");
  var fallback = (home || "") + "/Downloads";
  if (s === "") return fallback;
  if (s.charAt(0) === "~") s = (home || "") + s.slice(1);
  if (s.charAt(0) !== "/") return fallback;
  if (s.indexOf("..") !== -1) return fallback;
  if (/[\u0000-\u001F]/.test(s)) return fallback;
  // No shell is ever used, but refuse obviously hostile values anyway.
  if (/[`$;|&<>\n\r]/.test(s)) return fallback;
  return s.replace(/\/+$/, "") || "/";
}

// Local filename for a downloaded remote entry. Rejects anything unusable so
// we never write outside the chosen directory.
function localTargetName(name) {
  return isUsableName(name) ? name : null;
}

// The filename we actually write to LOCAL disk.
//
// A remote name is attacker-controlled, and writing it verbatim would carry
// the attack onto the local filesystem: a bidi override (U+202E) makes
// "ev<RLO>gnp.exe" render as "evexe.gnp" in every file manager and terminal,
// hiding the real extension. Control characters similarly break shell output
// and confuse scripts that later touch the download directory.
//
// So the REMOTE path stays byte-exact (we must fetch the right object), while
// the LOCAL name is stripped of anything deceptive. The visible extension is
// preserved so the correct application still opens it.
function safeLocalName(name) {
  var s = String(name === undefined || name === null ? "" : name);
  // bidi controls: the extension-spoofing vector
  s = s.replace(/[\u200E\u200F\u202A-\u202E\u2066-\u2069]/g, "");
  // zero-width joiners/spaces
  s = s.replace(/[\u200B-\u200D\uFEFF]/g, "");
  // C0/C1 controls and DEL -> underscore, so words stay separated
  s = s.replace(/[\u0000-\u001F\u007F-\u009F]/g, "_");
  // rclone's "control picture" stand-ins (U+2400-U+2421: ␀..␟, ␠, ␡). rclone
  // lists a remote "a\nb" as "a␊b" and DECODES the symbol back to the real
  // control byte when writing locally — so these must go too, or a newline
  // lands in the filename on disk after all. Verified against rclone 1.74.
  s = s.replace(/[\u2400-\u2421]/g, "_");
  // path separators can never appear in a basename
  s = s.replace(/\//g, "_");
  // collapse the runs of underscores that substitution can create
  s = s.replace(/_{2,}/g, "_");
  // strip leading separators/dots/dashes: a leading dot would hide the file,
  // a leading dash trips CLI tools, and a leading underscore is just noise
  s = s.replace(/^[._\-]+/, "");
  s = s.replace(/^\s+|\s+$/g, "");
  if (s === "" || s === "." || s === "..") return null;
  if (s.length > 200) {
    var dot = s.lastIndexOf(".");
    var ext = dot > 0 && s.length - dot <= 12 ? s.slice(dot) : "";
    s = s.slice(0, 200 - ext.length) + ext;
  }
  return s;
}

// Split a (sanitized) local name into stem + extension so a collision can be
// resolved as "report (1).pdf" rather than "report.pdf (1)". Only a short,
// non-leading extension counts; directories pass isDir and keep no extension.
function splitExtension(name, isDir) {
  var s = String(name || "");
  if (isDir) return { stem: s, ext: "" };
  var dot = s.lastIndexOf(".");
  if (dot <= 0 || dot === s.length - 1 || s.length - dot > 12) return { stem: s, ext: "" };
  return { stem: s.slice(0, dot), ext: s.slice(dot) };
}

// Is the CLI's key file readable by anyone but its owner?
// `fileMode` is the octal string from `stat -c %a` for rclone.conf; `dirModes`
// are the modes of every directory on the way to it that we control
// (~/.config/filen-cli and its rclone/ subdirectory). A group/other read bit
// on the file only matters if that same class can also traverse (x) every
// directory above it — so `chmod 700` on the config dir is a complete fix
// even though the CLI recreates rclone.conf as 0644 on each sign-in.
function credentialExposed(fileMode, dirModes) {
  var f = parseInt(String(fileMode || ""), 8);
  if (!isFinite(f)) return false;
  var dirs = dirModes || [];
  function reachable(shift) {
    for (var i = 0; i < dirs.length; i++) {
      var d = parseInt(String(dirs[i] || ""), 8);
      if (!isFinite(d)) continue;
      if (((d >> shift) & 1) === 0) return false;   // no x for this class
    }
    return true;
  }
  var groupRead = ((f >> 5) & 1) === 1;   // 0040
  var otherRead = ((f >> 2) & 1) === 1;   // 0004
  return (groupRead && reachable(3)) || (otherRead && reachable(0));
}

// ---------------------------------------------------------------- transfers

function makeTransfer(id, kind, label, remotePath, localPath) {
  return {
    id: id,
    kind: kind,                       // "download" | "upload"
    label: sanitizeText(label, 60),
    remotePath: remotePath,
    localPath: localPath,
    state: "running",                 // running | done | failed | canceled
    error: "",
    startedMs: Date.now()
  };
}

function transferSummary(list) {
  var running = 0, failed = 0;
  var items = list || [];
  for (var i = 0; i < items.length; i++) {
    if (items[i].state === "running") running++;
    else if (items[i].state === "failed") failed++;
  }
  return { running: running, failed: failed, total: items.length };
}

// ---------------------------------------------------------------- exports

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    MAX_RESPONSE_BYTES: MAX_RESPONSE_BYTES,
    MAX_STDERR_BYTES: MAX_STDERR_BYTES,
    MAX_ENTRIES: MAX_ENTRIES,
    sanitizeText: sanitizeText,
    isUsableName: isUsableName,
    joinPath: joinPath,
    normalizePath: normalizePath,
    parentPath: parentPath,
    basename: basename,
    crumbs: crumbs,
    parseJson: parseJson,
    parseListing: parseListing,
    parseStat: parseStat,
    parseLsJson: parseLsJson,
    parseRfc3339: parseRfc3339,
    parseAbout: parseAbout,
    parseRcloneProgress: parseRcloneProgress,
    formatSpeed: formatSpeed,
    formatEta: formatEta,
    extensionOf: extensionOf,
    kindOf: kindOf,
    iconFor: iconFor,
    isPreviewable: isPreviewable,
    isSafeToOpen: isSafeToOpen,
    formatSize: formatSize,
    formatPercent: formatPercent,
    formatDate: formatDate,
    relativeTime: relativeTime,
    errorMessage: errorMessage,
    isAuthError: isAuthError,
    isNetworkError: isNetworkError,
    isNotFoundError: isNotFoundError,
    isConfigRaceError: isConfigRaceError,
    firstMeaningfulLine: firstMeaningfulLine,
    oversized: oversized,
    sortEntries: sortEntries,
    sameEntries: sameEntries,
    filterEntries: filterEntries,
    validatedDownloadDir: validatedDownloadDir,
    localTargetName: localTargetName,
    safeLocalName: safeLocalName,
    splitExtension: splitExtension,
    credentialExposed: credentialExposed,
    makeTransfer: makeTransfer,
    transferSummary: transferSummary
  };
}
