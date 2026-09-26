const { test } = require("node:test");
const assert = require("node:assert");
const M = require("../Model.js");

// ─────────────────────────────────────────────── text safety

test("sanitizeText neutralises control characters as separators", () => {
  // Control bytes become spaces so they can never silently join two words.
  assert.strictEqual(M.sanitizeText("a\u0000b\u001Fc"), "a b c");
  assert.strictEqual(M.sanitizeText("line\nbreak"), "line break");
  assert.strictEqual(M.sanitizeText("tab\there"), "tab here");
  // and none of the raw bytes survive
  assert.strictEqual(M.sanitizeText("a\u0000b").indexOf("\u0000"), -1);
});

test("sanitizeText neutralises ANSI escape bytes", () => {
  // ESC is \u001B — a raw escape in a filename could repaint the panel/log.
  // It becomes a space (not deleted), so the payload can't re-form as a word.
  const out = M.sanitizeText("\u001B[31mred\u001B[0m");
  assert.strictEqual(out.indexOf("\u001B"), -1);
  assert.strictEqual(out, "[31mred [0m");
});

test("sanitizeText strips bidi override (RTL filename spoofing)", () => {
  // classic "exe spoofed as txt" trick
  const evil = "invoice\u202Egnp.exe";
  assert.strictEqual(M.sanitizeText(evil).indexOf("\u202E"), -1);
});

test("sanitizeText strips zero-width characters", () => {
  assert.strictEqual(M.sanitizeText("in\u200Bvoice"), "invoice");
});

test("sanitizeText truncates with ellipsis", () => {
  const long = "x".repeat(400);
  const out = M.sanitizeText(long);
  assert.ok(out.length <= 120);
  assert.ok(out.endsWith("\u2026"));
});

test("sanitizeText handles null/undefined", () => {
  assert.strictEqual(M.sanitizeText(null), "");
  assert.strictEqual(M.sanitizeText(undefined), "");
});

// ─────────────────────────────────────────────── name validation

test("isUsableName rejects traversal and separators", () => {
  assert.strictEqual(M.isUsableName(".."), false);
  assert.strictEqual(M.isUsableName("."), false);
  assert.strictEqual(M.isUsableName("a/b"), false);
  assert.strictEqual(M.isUsableName("../../etc/passwd"), false);
  assert.strictEqual(M.isUsableName(""), false);
});

test("isUsableName rejects only what can change path meaning", () => {
  // NUL and "/" are the only genuinely dangerous characters, because commands
  // are argv arrays and never shell strings.
  assert.strictEqual(M.isUsableName("a\u0000b"), false);
  assert.strictEqual(M.isUsableName("a/b"), false);
  // Legal-but-ugly names must stay usable, or the file becomes invisible and
  // undeletable in the panel. These exist in the live test account.
  assert.strictEqual(M.isUsableName("weird\ttab.png"), true);
  assert.strictEqual(M.isUsableName("ev\u202Egnp.exe"), true);
  assert.strictEqual(M.isUsableName("-leading-dash.png"), true);
  assert.strictEqual(M.isUsableName("line\nbreak.txt"), true);
});

test("isUsableName rejects over-long names", () => {
  assert.strictEqual(M.isUsableName("x".repeat(256)), false);
  assert.strictEqual(M.isUsableName("x".repeat(255)), true);
});

test("isUsableName accepts normal and unicode names", () => {
  assert.strictEqual(M.isUsableName("invoice-01.pdf"), true);
  assert.strictEqual(M.isUsableName("Ünïcode ファイル.txt"), true);
  assert.strictEqual(M.isUsableName("-leading-dash.txt"), true); // safe: never argv-leading
});

// ─────────────────────────────────────────────── paths

test("normalizePath collapses traversal", () => {
  assert.strictEqual(M.normalizePath("/a/b/../c"), "/a/c");
  assert.strictEqual(M.normalizePath("/a/./b"), "/a/b");
  assert.strictEqual(M.normalizePath("/a//b"), "/a/b");
  assert.strictEqual(M.normalizePath("/.."), "/");
  assert.strictEqual(M.normalizePath("/../../.."), "/");
  assert.strictEqual(M.normalizePath(""), "/");
  assert.strictEqual(M.normalizePath(null), "/");
});

test("joinPath refuses unusable names", () => {
  assert.strictEqual(M.joinPath("/docs", ".."), null);
  assert.strictEqual(M.joinPath("/docs", "a/b"), null);
  assert.strictEqual(M.joinPath("/docs", ""), null);
});

test("joinPath builds correct paths", () => {
  assert.strictEqual(M.joinPath("/", "docs"), "/docs");
  assert.strictEqual(M.joinPath("/docs", "a.txt"), "/docs/a.txt");
  assert.strictEqual(M.joinPath("/docs/", "a.txt"), "/docs/a.txt");
});

test("parentPath walks up and stops at root", () => {
  assert.strictEqual(M.parentPath("/a/b/c"), "/a/b");
  assert.strictEqual(M.parentPath("/a"), "/");
  assert.strictEqual(M.parentPath("/"), "/");
});

test("basename", () => {
  assert.strictEqual(M.basename("/a/b/c.txt"), "c.txt");
  assert.strictEqual(M.basename("/"), "/");
});

test("crumbs produce root-first breadcrumb", () => {
  const c = M.crumbs("/Documents/Invoices");
  assert.strictEqual(c.length, 3);
  assert.strictEqual(c[0].path, "/");
  assert.strictEqual(c[1].path, "/Documents");
  assert.strictEqual(c[2].path, "/Documents/Invoices");
  assert.strictEqual(c[2].label, "Invoices");
});

test("crumbs sanitize hostile segment names", () => {
  const c = M.crumbs("/ev\u202Eil");
  assert.strictEqual(c[1].label.indexOf("\u202E"), -1);
});

// ─────────────────────────────────────────────── JSON parsing

test("parseJson is total — never throws", () => {
  assert.strictEqual(M.parseJson("not json"), null);
  assert.strictEqual(M.parseJson(""), null);
  assert.strictEqual(M.parseJson(null), null);
  assert.strictEqual(M.parseJson("{unclosed"), null);
});

test("parseJson refuses oversized payloads", () => {
  const huge = "\"" + "x".repeat(M.MAX_RESPONSE_BYTES + 10) + "\"";
  assert.strictEqual(M.parseJson(huge), null);
});

test("parseListing reads the real CLI ls shape", () => {
  const out = M.parseListing(JSON.stringify({
    directories: ["Invoices", "Photos"],
    files: ["a.txt", "b.png"]
  }));
  assert.strictEqual(out.length, 4);
  assert.strictEqual(out[0].dir, true);
  assert.strictEqual(out[0].name, "Invoices");
  assert.strictEqual(out[2].dir, false);
  assert.strictEqual(out[3].kind, "image");
});

test("parseListing drops entries with unusable names", () => {
  const out = M.parseListing(JSON.stringify({
    directories: ["ok", "../escape", "has/slash"],
    files: ["good.txt", "bad\u0000.txt", ""]
  }));
  const names = out.map(e => e.name);
  assert.deepStrictEqual(names, ["ok", "good.txt"]);
});

test("parseListing tolerates missing/garbage fields", () => {
  assert.deepStrictEqual(M.parseListing("{}"), []);
  assert.deepStrictEqual(M.parseListing(JSON.stringify({ directories: "nope", files: 5 })), []);
  assert.strictEqual(M.parseListing("garbage"), null);
});

test("parseListing caps entry count", () => {
  const many = Array.from({ length: M.MAX_ENTRIES + 500 }, (_, i) => "f" + i + ".txt");
  const out = M.parseListing(JSON.stringify({ directories: [], files: many }));
  assert.strictEqual(out.length, M.MAX_ENTRIES);
});

test("parseStat reads drive quota", () => {
  const s = M.parseStat(JSON.stringify({ type: "drive", usedStorage: 443, totalStorage: 1000 }));
  assert.strictEqual(s.type, "drive");
  assert.strictEqual(s.used, 443);
  assert.strictEqual(s.total, 1000);
});

test("parseStat rejects a zero-total drive (divide-by-zero guard)", () => {
  assert.strictEqual(M.parseStat(JSON.stringify({ type: "drive", usedStorage: 1, totalStorage: 0 })), null);
});

test("parseStat reads file and directory", () => {
  const f = M.parseStat(JSON.stringify({
    type: "file", name: "a.txt", size: 1234, modified: 1700000000000,
    created: 1690000000000, uuid: "abc"
  }));
  assert.strictEqual(f.type, "file");
  assert.strictEqual(f.size, 1234);

  const d = M.parseStat(JSON.stringify({ type: "directory", name: "docs", created: 1, uuid: "x" }));
  assert.strictEqual(d.type, "directory");
});

test("parseStat rejects unknown types", () => {
  assert.strictEqual(M.parseStat(JSON.stringify({ type: "wormhole" })), null);
  assert.strictEqual(M.parseStat("null"), null);
});

// ─────────────────────────────────────────────── file kinds

test("kindOf classifies by extension", () => {
  assert.strictEqual(M.kindOf("a.PNG"), "image");
  assert.strictEqual(M.kindOf("a.mkv"), "video");
  assert.strictEqual(M.kindOf("a.flac"), "audio");
  assert.strictEqual(M.kindOf("a.pdf"), "document");
  assert.strictEqual(M.kindOf("a.rs"), "text");
  assert.strictEqual(M.kindOf("a.tar.gz"), "archive");
  assert.strictEqual(M.kindOf("noext"), "file");
  assert.strictEqual(M.kindOf(".bashrc"), "file"); // leading dot is not an ext
});

test("isPreviewable gates viewer launch", () => {
  assert.strictEqual(M.isPreviewable({ dir: false, kind: "image" }), true);
  assert.strictEqual(M.isPreviewable({ dir: false, kind: "video" }), true);
  assert.strictEqual(M.isPreviewable({ dir: false, kind: "archive" }), false);
  assert.strictEqual(M.isPreviewable({ dir: true, kind: "directory" }), false);
  assert.strictEqual(M.isPreviewable(null), false);
});

// ─────────────────────────────────────────────── formatting

test("formatSize", () => {
  assert.strictEqual(M.formatSize(0), "0 B");
  assert.strictEqual(M.formatSize(512), "512 B");
  assert.strictEqual(M.formatSize(1024), "1.00 KiB");
  assert.strictEqual(M.formatSize(1536), "1.50 KiB");
  assert.strictEqual(M.formatSize(1024 * 1024 * 1024), "1.00 GiB");
  assert.strictEqual(M.formatSize(-5), "");
  assert.strictEqual(M.formatSize("nope"), "");
});

test("formatPercent clamps", () => {
  assert.strictEqual(M.formatPercent(50, 100), 0.5);
  assert.strictEqual(M.formatPercent(200, 100), 1);
  assert.strictEqual(M.formatPercent(5, 0), 0);
  assert.strictEqual(M.formatPercent(-5, 100), 0);
});

test("formatDate handles epoch ms and junk", () => {
  assert.match(M.formatDate(1700000000000), /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/);
  assert.strictEqual(M.formatDate(0), "");
  assert.strictEqual(M.formatDate("nope"), "");
});

test("relativeTime", () => {
  const now = 1_700_000_000_000;
  assert.strictEqual(M.relativeTime(now - 30_000, now), "30s ago");
  assert.strictEqual(M.relativeTime(now - 120_000, now), "2m ago");
  assert.strictEqual(M.relativeTime(now - 7_200_000, now), "2h ago");
  assert.strictEqual(M.relativeTime(now + 5000, now), "just now");
});

// ─────────────────────────────────────────────── errors

test("isAuthError detects the no-TTY credential prompt", () => {
  // this is the literal stderr v0.2.7 emits when signed out
  assert.strictEqual(
    M.isAuthError("✘ Failed to read input from terminal. Please ensure that the terminal supports interactive input."),
    true);
  assert.strictEqual(M.isAuthError("some other failure"), false);
});

test("errorMessage prefers the auth message and sanitizes stderr", () => {
  assert.strictEqual(M.errorMessage(1, "Failed to read input from terminal"), "Not signed in to Filen");
  const msg = M.errorMessage(1, "boom\u001B[31m\nsecond line");
  assert.strictEqual(msg.indexOf("\u001B"), -1);
  assert.strictEqual(msg.indexOf("\n"), -1);
});

test("errorMessage falls back to exit code", () => {
  assert.strictEqual(M.errorMessage(7, ""), "Filen CLI failed (exit 7)");
});

test("oversized detects truncated pipelines", () => {
  assert.strictEqual(M.oversized(23, ""), true);
  assert.strictEqual(M.oversized(141, ""), true);
  assert.strictEqual(M.oversized(0, "x".repeat(M.MAX_RESPONSE_BYTES)), true);
  assert.strictEqual(M.oversized(0, "small"), false);
});

// ─────────────────────────────────────────────── listing ops

test("sortEntries puts directories first then natural order", () => {
  const list = M.sortEntries([
    { name: "b.txt", display: "b.txt", dir: false },
    { name: "file10", display: "file10", dir: false },
    { name: "file2", display: "file2", dir: false },
    { name: "zdir", display: "zdir", dir: true },
    { name: "adir", display: "adir", dir: true }
  ]);
  assert.deepStrictEqual(list.map(e => e.display),
    ["adir", "zdir", "b.txt", "file2", "file10"]);
});

test("sameEntries detects membership change", () => {
  const a = [{ name: "x", dir: false, size: 1 }];
  assert.strictEqual(M.sameEntries(a, [{ name: "x", dir: false, size: 1 }]), true);
  assert.strictEqual(M.sameEntries(a, [{ name: "y", dir: false, size: 1 }]), false);
  assert.strictEqual(M.sameEntries(a, [{ name: "x", dir: false, size: 2 }]), false);
  assert.strictEqual(M.sameEntries(a, []), false);
});

test("filterEntries is case-insensitive substring", () => {
  const list = [
    { display: "Invoice.pdf" }, { display: "photo.png" }, { display: "invoices" }
  ];
  assert.strictEqual(M.filterEntries(list, "invo").length, 2);
  assert.strictEqual(M.filterEntries(list, "").length, 3);
  assert.strictEqual(M.filterEntries(list, "zzz").length, 0);
});

// ─────────────────────────────────────────────── local paths

test("validatedDownloadDir falls back for hostile values", () => {
  const home = "/home/u";
  assert.strictEqual(M.validatedDownloadDir("", home), "/home/u/Downloads");
  assert.strictEqual(M.validatedDownloadDir("relative/path", home), "/home/u/Downloads");
  assert.strictEqual(M.validatedDownloadDir("/a/../../etc", home), "/home/u/Downloads");
  assert.strictEqual(M.validatedDownloadDir("/tmp; rm -rf /", home), "/home/u/Downloads");
  assert.strictEqual(M.validatedDownloadDir("/tmp/$(whoami)", home), "/home/u/Downloads");
  assert.strictEqual(M.validatedDownloadDir("/tmp/`id`", home), "/home/u/Downloads");
  assert.strictEqual(M.validatedDownloadDir("/tmp/a\nb", home), "/home/u/Downloads");
});

test("validatedDownloadDir accepts good values and expands ~", () => {
  const home = "/home/u";
  assert.strictEqual(M.validatedDownloadDir("/data/dl", home), "/data/dl");
  assert.strictEqual(M.validatedDownloadDir("/data/dl/", home), "/data/dl");
  assert.strictEqual(M.validatedDownloadDir("~/Cloud", home), "/home/u/Cloud");
});

test("localTargetName rejects unusable names", () => {
  assert.strictEqual(M.localTargetName("ok.txt"), "ok.txt");
  assert.strictEqual(M.localTargetName("../evil"), null);
  assert.strictEqual(M.localTargetName("a/b"), null);
});

// ─────────────────────────────────────────────── transfers

test("transferSummary counts by state", () => {
  const s = M.transferSummary([
    { state: "running" }, { state: "running" }, { state: "done" }, { state: "failed" }
  ]);
  assert.strictEqual(s.running, 2);
  assert.strictEqual(s.failed, 1);
  assert.strictEqual(s.total, 4);
});

test("makeTransfer sanitizes its label", () => {
  const t = M.makeTransfer("1", "download", "ev\u202Eil\u0000", "/a", "/b");
  assert.strictEqual(t.label.indexOf("\u202E"), -1);
  assert.strictEqual(t.label.indexOf("\u0000"), -1);
  assert.strictEqual(t.state, "running");
});

// ─────────────────────────────────────────────── rclone lsjson (real shapes)
// The JSON below is verbatim output captured from `filen rclone lsjson`
// against a live account on 2026-08-27 with CLI v0.2.7.

const REAL_LSJSON = `[
{"Path":"Documents","Name":"Documents","Size":-1,"MimeType":"inode/directory","ModTime":"2026-08-27T23:04:54.548+02:00","IsDir":true,"ID":"2214b8ed-3e29-4786-b089-44be46179b2a"},
{"Path":"Pictures","Name":"Pictures","Size":-1,"MimeType":"inode/directory","ModTime":"2026-08-27T23:04:55.061+02:00","IsDir":true,"ID":"7579b738-20c1-403d-8701-0a086b0c54bc"},
{"Path":"README.txt","Name":"README.txt","Size":40,"MimeType":"text/plain","ModTime":"2026-08-27T23:04:48.186+02:00","IsDir":false,"ID":"5001256a-1933-4f75-b50b-7fd2da6be00d"}
]`;

test("parseLsJson reads the real rclone listing", () => {
  const out = M.parseLsJson(REAL_LSJSON);
  assert.strictEqual(out.length, 3);
  assert.strictEqual(out[0].dir, true);
  assert.strictEqual(out[0].size, null);            // -1 for dirs -> null
  assert.strictEqual(out[2].name, "README.txt");
  assert.strictEqual(out[2].size, 40);
  assert.strictEqual(out[2].kind, "text");
  assert.ok(out[2].modified > 1_700_000_000_000);   // RFC3339 -> epoch ms
});

test("parseLsJson drops entries whose names are unusable", () => {
  const hostile = JSON.stringify([
    { Name: "ok.txt", Size: 1, IsDir: false, ModTime: "2026-01-01T00:00:00Z" },
    { Name: "..", Size: 1, IsDir: true },
    { Name: "a/b", Size: 1, IsDir: false },
    { Name: "nul\u0000byte", Size: 1, IsDir: false },
    { Name: "", Size: 1, IsDir: false }
  ]);
  const out = M.parseLsJson(hostile);
  assert.deepStrictEqual(out.map(e => e.name), ["ok.txt"]);
});

test("parseLsJson keeps hostile-but-legal names and sanitizes the display", () => {
  // These two exist in the live test account.
  const out = M.parseLsJson(JSON.stringify([
    { Name: "ev\u202Egnp.exe", Size: 18, IsDir: false },
    { Name: "weird\ttab.png", Size: 17, IsDir: false },
    { Name: "-leading-dash.png", Size: 179, IsDir: false }
  ]));
  assert.strictEqual(out.length, 3);
  // raw name preserved for the CLI call...
  assert.strictEqual(out[0].name, "ev\u202Egnp.exe");
  // ...but the rendered form has no bidi override
  assert.strictEqual(out[0].display.indexOf("\u202E"), -1);
  // tab collapsed to a space in display, raw kept
  assert.strictEqual(out[1].display, "weird tab.png");
  assert.strictEqual(out[1].name, "weird\ttab.png");
  // leading dash is legal; it is never argv-leading because we pass `--`
  assert.strictEqual(out[2].name, "-leading-dash.png");
});

test("parseLsJson rejects non-arrays and garbage", () => {
  assert.strictEqual(M.parseLsJson("{}"), null);
  assert.strictEqual(M.parseLsJson("not json"), null);
  assert.strictEqual(M.parseLsJson(""), null);
  assert.deepStrictEqual(M.parseLsJson("[]"), []);
});

test("parseLsJson tolerates missing fields", () => {
  const out = M.parseLsJson(JSON.stringify([{ Name: "x.txt" }]));
  assert.strictEqual(out.length, 1);
  assert.strictEqual(out[0].size, null);
  assert.strictEqual(out[0].modified, null);
  assert.strictEqual(out[0].dir, false);
});

test("parseRfc3339 handles real timestamps and junk", () => {
  assert.ok(M.parseRfc3339("2026-08-27T23:04:48.186+02:00") > 0);
  assert.ok(M.parseRfc3339("2026-01-01T00:00:00Z") > 0);
  assert.strictEqual(M.parseRfc3339("nonsense"), null);
  assert.strictEqual(M.parseRfc3339(""), null);
  assert.strictEqual(M.parseRfc3339("x".repeat(200)), null);
});

test("parseAbout reads the real quota shape", () => {
  // verbatim from `filen rclone about filen: --json`
  const s = M.parseAbout('{\n\t"total": 42949672960,\n\t"used": 96,\n\t"free": 42949672864\n}');
  assert.strictEqual(s.total, 42949672960);
  assert.strictEqual(s.used, 96);
  assert.strictEqual(s.free, 42949672864);
});

test("parseAbout fails closed on a zero total", () => {
  assert.strictEqual(M.parseAbout('{"total":0,"used":5}'), null);
  assert.strictEqual(M.parseAbout("garbage"), null);
});

test("sortEntries orders the real listing correctly", () => {
  const out = M.sortEntries(M.parseLsJson(REAL_LSJSON));
  assert.deepStrictEqual(out.map(e => e.name), ["Documents", "Pictures", "README.txt"]);
});

// ─────────────────────────────────────────────── local write safety
// Regression tests for a real vulnerability found during live testing: the
// plugin downloaded "ev<U+202E>gnp.exe" from the drive and wrote that exact
// name to ~/Downloads, where a file manager renders it as "evexe.gnp" —
// hiding the true .exe extension. Remote paths stay exact; local names don't.

test("safeLocalName strips the bidi extension-spoofing attack", () => {
  const evil = "ev\u202Egnp.exe";           // exists in the live test account
  const safe = M.safeLocalName(evil);
  assert.strictEqual(safe.indexOf("\u202E"), -1);
  assert.strictEqual(safe, "evgnp.exe");
  // the true extension survives, so the right app still opens it
  assert.ok(safe.endsWith(".exe"));
});

test("safeLocalName strips every bidi and zero-width control", () => {
  for (const cp of ["\u200E","\u200F","\u202A","\u202B","\u202C","\u202D","\u202E",
                    "\u2066","\u2067","\u2068","\u2069","\u200B","\u200C","\u200D","\uFEFF"]) {
    const out = M.safeLocalName("a" + cp + "b.txt");
    assert.strictEqual(out.indexOf(cp), -1, `leaked ${escape(cp)}`);
  }
});

test("safeLocalName replaces control characters with underscores", () => {
  assert.strictEqual(M.safeLocalName("weird\ttab.png"), "weird_tab.png");
  assert.strictEqual(M.safeLocalName("line\nbreak.txt"), "line_break.txt");
  assert.strictEqual(M.safeLocalName("nul\u0000byte.bin"), "nul_byte.bin");
});

test("safeLocalName neutralises leading dot and dash", () => {
  // a leading dot hides the file; a leading dash is read as a flag by tools
  assert.strictEqual(M.safeLocalName("-leading-dash.png"), "leading-dash.png");
  assert.strictEqual(M.safeLocalName(".hidden.txt"), "hidden.txt");
  assert.strictEqual(M.safeLocalName("...."), null);
});

test("safeLocalName can never escape the download directory", () => {
  assert.strictEqual(M.safeLocalName("../../etc/passwd"), "etc_passwd");
  assert.strictEqual(M.safeLocalName("/abs/path"), "abs_path");
  assert.strictEqual(M.safeLocalName(".."), null);
  assert.strictEqual(M.safeLocalName(""), null);
});

test("safeLocalName truncates long names but keeps the extension", () => {
  const long = "x".repeat(400) + ".png";
  const out = M.safeLocalName(long);
  assert.ok(out.length <= 200);
  assert.ok(out.endsWith(".png"));
});

test("safeLocalName leaves ordinary names untouched", () => {
  assert.strictEqual(M.safeLocalName("invoice-0184.pdf"), "invoice-0184.pdf");
  assert.strictEqual(M.safeLocalName("Ünïcode ファイル.txt"), "Ünïcode ファイル.txt");
  assert.strictEqual(M.safeLocalName("sunset.png"), "sunset.png");
});

// ─────────────────────────────────────────────── rclone progress
// Verbatim line from `rclone copyto --use-json-log --stats 1s`.

const REAL_STATS_LINE = '{"time":"2026-08-27T23:18:41.259913352+02:00","level":"notice","msg":"Transferred","stats":{"bytes":200000,"checks":0,"elapsedTime":0.14,"errors":0,"eta":8,"fatalError":false,"speed":1048576,"totalBytes":400000,"totalTransfers":1,"transfers":0}}';

test("parseRcloneProgress reads a real stats line", () => {
  const p = M.parseRcloneProgress(REAL_STATS_LINE);
  assert.strictEqual(p.bytes, 200000);
  assert.strictEqual(p.totalBytes, 400000);
  assert.strictEqual(p.fraction, 0.5);
  assert.strictEqual(p.speed, 1048576);
  assert.strictEqual(p.eta, 8);
});

test("parseRcloneProgress takes the LAST stats line in a chunk", () => {
  const chunk = [
    REAL_STATS_LINE,
    REAL_STATS_LINE.replace('"bytes":200000', '"bytes":400000')
  ].join("\n");
  assert.strictEqual(M.parseRcloneProgress(chunk).bytes, 400000);
});

test("parseRcloneProgress survives partial/garbage lines", () => {
  assert.strictEqual(M.parseRcloneProgress('{"incomplete'), null);
  assert.strictEqual(M.parseRcloneProgress("plain text"), null);
  assert.strictEqual(M.parseRcloneProgress(""), null);
  assert.strictEqual(M.parseRcloneProgress('{"level":"info","msg":"no stats"}'), null);
  // a good line followed by a truncated one still yields the good one
  assert.strictEqual(M.parseRcloneProgress(REAL_STATS_LINE + '\n{"trunc').bytes, 200000);
});

test("parseRcloneProgress leaves fraction null without a total", () => {
  const p = M.parseRcloneProgress('{"stats":{"bytes":50,"totalBytes":0}}');
  assert.strictEqual(p.fraction, null);
  assert.strictEqual(p.totalBytes, null);
});

test("parseRcloneProgress clamps a fraction above 1", () => {
  const p = M.parseRcloneProgress('{"stats":{"bytes":500,"totalBytes":100}}');
  assert.strictEqual(p.fraction, 1);
});

test("formatSpeed and formatEta", () => {
  assert.strictEqual(M.formatSpeed(1048576), "1.00 MiB/s");
  assert.strictEqual(M.formatSpeed(0), "");
  assert.strictEqual(M.formatSpeed(null), "");
  assert.strictEqual(M.formatEta(30), "30s left");
  assert.strictEqual(M.formatEta(120), "2m left");
  assert.strictEqual(M.formatEta(7200), "2h left");
  assert.strictEqual(M.formatEta(null), "");
});

// ─────────────────────────────────────────────── rclone.conf race
// Every `filen rclone ...` run rewrites rclone.conf as it starts. Two
// overlapping runs (the plugin used to fire quota + listing together) can
// catch it mid-write. Verbatim message observed on this machine:

const RACE_MSG = '2026/08/27 23:31:37 CRITICAL: Failed to create file system for "filen:/Pictures": didn\'t find section in config file ("filen")';

test("isConfigRaceError recognises the real message", () => {
  assert.strictEqual(M.isConfigRaceError(RACE_MSG), true);
});

test("isConfigRaceError does not swallow real failures", () => {
  assert.strictEqual(M.isConfigRaceError("No such file or directory"), false);
  assert.strictEqual(M.isConfigRaceError("Failed to read input from terminal"), false);
  assert.strictEqual(M.isConfigRaceError(""), false);
  assert.strictEqual(M.isConfigRaceError(null), false);
});

test("the race message is not mistaken for an auth failure", () => {
  // critical: if this classified as auth, the panel would falsely sign you out
  assert.strictEqual(M.isAuthError(RACE_MSG), false);
});

// ─────────────────────────────────────────────── error message quality
// rclone dumps multi-line, timestamped logs. The panel must show one useful
// sentence, never the raw stream. Verbatim capture from a bad path:

const REAL_NOTFOUND = `[
2026/08/27 23:39:50 ERROR : error listing: directory not found
2026/08/27 23:39:50 NOTICE: Failed to lsjson with 2 errors: last error was: directory not found
]`;

test("errorMessage turns a not-found dump into one sentence", () => {
  const msg = M.errorMessage(1, REAL_NOTFOUND);
  assert.strictEqual(msg, "That folder no longer exists");
  assert.strictEqual(msg.indexOf("2026/"), -1);   // no timestamps
  assert.strictEqual(msg.indexOf("\n"), -1);      // single line
});

test("isNotFoundError recognises rclone's phrasing", () => {
  assert.strictEqual(M.isNotFoundError(REAL_NOTFOUND), true);
  assert.strictEqual(M.isNotFoundError("object not found"), true);
  assert.strictEqual(M.isNotFoundError("something else"), false);
});

test("errorMessage strips rclone log decoration from unknown errors", () => {
  const msg = M.errorMessage(1, "2026/08/27 23:39:50 ERROR : quota exceeded on server");
  assert.strictEqual(msg, "quota exceeded on server");
});

test("errorMessage prefers the informative line over a generic first line", () => {
  const dump = "[\nstarting transfer\n2026/01/01 00:00:00 ERROR : permission denied\n]";
  assert.strictEqual(M.errorMessage(1, dump), "permission denied");
});

test("errorMessage still classifies auth and race before anything else", () => {
  assert.strictEqual(M.errorMessage(1, "Failed to read input from terminal"),
                     "Not signed in to Filen");
  assert.strictEqual(M.errorMessage(1, 'didn\'t find section in config file ("filen")'),
                     "Filen CLI config was busy \u2014 try again");
});

test("errorMessage falls back to the exit code when there is nothing to show", () => {
  assert.strictEqual(M.errorMessage(7, ""), "Filen CLI failed (exit 7)");
  assert.strictEqual(M.errorMessage(7, "[\n]"), "Filen CLI failed (exit 7)");
});

// ─────────────────────────────────────────────── offline vs signed out
// With no network the CLI cannot validate the stored session, falls back to
// prompting, finds no TTY, and prints the SAME message as being signed out.
// Confusing the two would show a login button (implying the session was lost)
// every time Wi-Fi drops. Captured from `unshare -n`:

const OFFLINE_OUTPUT = "✘ Failed to read input from terminal. Please ensure that the terminal supports interactive input.";

test("the offline message is textually identical to signed-out", () => {
  // documents WHY a connectivity probe is required — text alone cannot decide
  assert.strictEqual(M.isAuthError(OFFLINE_OUTPUT), true);
  assert.strictEqual(M.isNetworkError(OFFLINE_OUTPUT), false);
});

test("isNetworkError recognises explicit transport failures", () => {
  for (const s of ["dial tcp 1.2.3.4:443: connect: connection refused",
                   "lookup gateway.filen.io: no such host",
                   "network is unreachable",
                   "Temporary failure in name resolution",
                   "net/http: TLS handshake timeout",
                   "i/o timeout",
                   "error sending request for url"]) {
    assert.strictEqual(M.isNetworkError(s), true, `missed: ${s}`);
  }
});

test("isNetworkError does not fire on ordinary failures", () => {
  assert.strictEqual(M.isNetworkError("directory not found"), false);
  assert.strictEqual(M.isNetworkError("Failed to read input from terminal"), false);
  assert.strictEqual(M.isNetworkError(""), false);
});

// ─────────────────────────────────────────────── opening downloaded files

test("isPreviewable never auto-opens launchers, scripts or HTML", () => {
  // xdg-open would launch a .desktop file and run/render the others.
  for (const n of ["Invoice.desktop", "setup.sh", "page.html", "x.htm", "tool.py",
                   "a.js", "App.AppImage", "run.bin", "diagram.svg"]) {
    assert.strictEqual(M.isPreviewable({ name: n, dir: false, kind: M.kindOf(n) }), false, n);
  }
});

test("isPreviewable still opens ordinary media and documents", () => {
  for (const n of ["photo.png", "clip.mp4", "song.flac", "report.pdf", "notes.md", "data.csv"]) {
    assert.strictEqual(M.isPreviewable({ name: n, dir: false, kind: M.kindOf(n) }), true, n);
  }
  assert.strictEqual(M.isPreviewable({ name: "Pictures", dir: true, kind: "directory" }), false);
});

test("isSafeToOpen judges a local download path by its basename", () => {
  assert.strictEqual(M.isSafeToOpen("/home/u/Downloads/photo (1).png"), true);
  assert.strictEqual(M.isSafeToOpen("/home/u/Downloads/Invoice.desktop"), false);
  assert.strictEqual(M.isSafeToOpen("/home/u/Downloads/archive.tar.gz"), false);
  assert.strictEqual(M.isSafeToOpen(""), false);
});

// ─────────────────────────────────────────────── download collisions

test("splitExtension keeps the extension for collision suffixes", () => {
  assert.deepStrictEqual(M.splitExtension("report.pdf", false), { stem: "report", ext: ".pdf" });
  assert.deepStrictEqual(M.splitExtension("archive.tar.gz", false), { stem: "archive.tar", ext: ".gz" });
  assert.deepStrictEqual(M.splitExtension("README", false), { stem: "README", ext: "" });
  assert.deepStrictEqual(M.splitExtension("v1.2 photos", true), { stem: "v1.2 photos", ext: "" });
  assert.deepStrictEqual(M.splitExtension("x.averyveryverylongext", false),
                         { stem: "x.averyveryverylongext", ext: "" });
});

// ─────────────────────────────────────────────── credential file exposure

test("credentialExposed: 0644 key file behind a 0700 home is not exposed", () => {
  // Omarchy's default: HOME_MODE 0700, so the CLI's 0644 file is unreachable.
  assert.strictEqual(M.credentialExposed("644", ["700", "755", "755", "755"]), false);
});

test("credentialExposed: 0644 key file with every directory traversable is exposed", () => {
  assert.strictEqual(M.credentialExposed("644", ["755", "755", "755", "755"]), true);
  assert.strictEqual(M.credentialExposed("640", ["750", "750", "750", "750"]), true);
});

test("credentialExposed: the plugin's fix (config dir 0700) closes it", () => {
  assert.strictEqual(M.credentialExposed("644", ["755", "755", "700", "755"]), false);
  assert.strictEqual(M.credentialExposed("600", ["755", "755", "755", "755"]), false);
});

test("credentialExposed tolerates garbage", () => {
  assert.strictEqual(M.credentialExposed("", []), false);
  assert.strictEqual(M.credentialExposed("zz", ["755"]), false);
  assert.strictEqual(M.credentialExposed("644", ["zz"]), true);
});

test("safeLocalName strips rclone control-picture stand-ins", () => {
  // rclone lists "line\nbreak.txt" as "line\u240Abreak.txt" and decodes the
  // symbol back into a real newline when it writes the local file.
  assert.strictEqual(M.safeLocalName("line\u240Abreak.txt"), "line_break.txt");
  assert.strictEqual(M.safeLocalName("a\u2400b\u241Bc\u2421.txt"), "a_b_c_.txt");
  assert.strictEqual(M.safeLocalName("\u2420lead.txt"), "lead.txt");
});

// ─────────────────────────────────────────────── bounded CLI output
// StdioCollector buffers a child's whole stream until it exits, so the size
// ceiling has to be enforced while the child is writing. These run the real
// wrapper script under bash against producers that never stop.

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

function runBounded(argv, outCap, errCap) {
  const full = M.boundedArgv(argv, outCap, errCap);
  const r = spawnSync(full[0], full.slice(1), { timeout: 20000, maxBuffer: 64 * 1024 * 1024 });
  return { code: r.status, out: r.stdout, err: r.stderr, signal: r.signal };
}

test("bounded: small output passes through with the command's exit status", () => {
  const r = runBounded(["bash", "-c", "printf hello; printf oops >&2; exit 3"], 100, 100);
  assert.strictEqual(r.code, 3);
  assert.strictEqual(r.out.toString(), "hello");
  assert.strictEqual(r.err.toString(), "oops");
});

test("bounded: output exactly at the ceiling is not a cut-off", () => {
  const r = runBounded(["printf", "hello"], 5, 100);
  assert.strictEqual(r.code, 0);
  assert.strictEqual(r.out.toString(), "hello");
});

test("bounded: one byte over the ceiling is reported, not silently truncated", () => {
  const r = runBounded(["printf", "hello!"], 5, 100);
  assert.strictEqual(r.code, M.OUTPUT_LIMIT_EXIT);
  assert.strictEqual(r.out.length, 5);
  assert.strictEqual(M.outputLimitHit(r.code), true);
});

test("bounded: an endless listing is cut at MAX_RESPONSE_BYTES and the producer stops", () => {
  const t0 = Date.now();
  const r = runBounded(["yes", '{"Name":"x","IsDir":false},'], M.MAX_RESPONSE_BYTES, M.MAX_STDERR_BYTES);
  assert.strictEqual(r.signal, null, "wrapper must exit on its own, not hit the test timeout");
  assert.strictEqual(r.code, M.OUTPUT_LIMIT_EXIT);
  assert.strictEqual(r.out.length, M.MAX_RESPONSE_BYTES);
  assert.ok(Date.now() - t0 < 10000);
  // What the collector ends up holding is never handed to the parser as a listing.
  assert.strictEqual(M.parseLsJson("[" + r.out.toString()), null);
});

test("bounded: endless stderr is capped but drained, so the command still completes", () => {
  const r = runBounded(["bash", "-c", "head -c 5000000 /dev/zero | tr '\\0' e >&2; printf done"], 100, 64);
  assert.strictEqual(r.code, 0);
  assert.strictEqual(r.out.toString(), "done");
  assert.strictEqual(r.err.length, 64);
});

test("bounded: errCap 0 leaves stderr untouched for the streaming progress reader", () => {
  const r = runBounded(["bash", "-c", "printf 0123456789 >&2"], 10, 0);
  assert.strictEqual(r.code, 0);
  assert.strictEqual(r.err.toString(), "0123456789");
});

test("bounded: a missing binary still reads as a start failure (127)", () => {
  const r = runBounded(["/nonexistent/filen-xyz"], 100, 100);
  assert.strictEqual(r.code, 127);
});

test("bounded: hostile arguments are passed as data, never parsed as script", () => {
  const dir = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "filen-bounded-"));
  const marker = path.join(dir, "pwned");
  const evil = "filen:/a; touch " + marker + " $(touch " + marker + ") `touch " + marker + "`";
  const r = runBounded(["printf", "%s", evil], 4096, 100);
  assert.strictEqual(r.code, 0);
  assert.strictEqual(r.out.toString(), evil);
  assert.strictEqual(fs.existsSync(marker), false);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("bounded: argv shape keeps the script a fixed literal", () => {
  const a = M.boundedArgv(["filen", "--skip-update", "rclone", "lsjson", "filen:/x"], 10, 20);
  assert.deepStrictEqual(a.slice(0, 6), ["bash", "-c", M.BOUNDED_SCRIPT, "filen-bounded", "10", "20"]);
  assert.deepStrictEqual(a.slice(6), ["filen", "--skip-update", "rclone", "lsjson", "filen:/x"]);
});

test("errorMessage explains an output cut-off", () => {
  assert.strictEqual(M.errorMessage(M.OUTPUT_LIMIT_EXIT, ""), "Filen CLI output was too large to read");
});

test("Service: every CLI/child whose output is collected goes through the bounded wrapper", () => {
  const src = fs.readFileSync(path.join(__dirname, "..", "Service.qml"), "utf8");
  // Fixed local scripts with a few bytes of output are the only exceptions.
  const exempt = /whichProcess|permProcess|permFixProcess|reachProcess/;
  const assigns = src.split("\n").filter(l => /^\s*\w+Process\.command\s*=/.test(l));
  assert.ok(assigns.length >= 8, "found " + assigns.length + " command assignments");
  for (const line of assigns) {
    if (exempt.test(line)) continue;
    assert.match(line, /=\s*(root\.)?bounded\(/, "unbounded command: " + line.trim());
  }
  assert.match(src, /\["setsid"\]\.concat\(Model\.boundedArgv\(/, "transfers must be bounded too");
});

// ─────────────────────────────────────────────── download name claims
// Downloads never overwrite. The free name is CLAIMED on disk with an
// exclusive create, so two downloads resolving at the same moment (or any
// other writer in the folder) can never be handed the same path.

function qmlStringProperty(name) {
  const src = fs.readFileSync(path.join(__dirname, "..", "Service.qml"), "utf8");
  const m = src.match(new RegExp("readonly property string " + name + ":\\s*\\n((?:\\s*\".*\"\\s*\\+?\\s*\\n)+)"));
  assert.ok(m, name + " not found in Service.qml");
  // The property is a concatenation of plain JS string literals.
  return require("node:vm").runInNewContext(m[1]);
}

function claim(dir, stem, ext, kind) {
  const r = spawnSync("bash", ["-c", qmlStringProperty("freeNameScript"), "filen-free-name", dir, stem, ext, kind]);
  return { code: r.status, path: r.stdout.toString() };
}

test("freeNameScript claims the name on disk and skips taken ones", () => {
  const dir = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "filen-claim-"));
  fs.writeFileSync(path.join(dir, "report.pdf"), "keep me");
  fs.symlinkSync("/nonexistent", path.join(dir, "report (1).pdf"));   // dangling
  const a = claim(dir, "report", ".pdf", "file");
  assert.strictEqual(a.code, 0);
  assert.strictEqual(a.path, path.join(dir, "report (2).pdf"));
  assert.strictEqual(fs.statSync(a.path).size, 0, "placeholder is created empty");
  assert.strictEqual(fs.readFileSync(path.join(dir, "report.pdf"), "utf8"), "keep me");
  // The claim itself makes the next caller move on, no shared state needed.
  assert.strictEqual(claim(dir, "report", ".pdf", "file").path, path.join(dir, "report (3).pdf"));
  const d = claim(dir, "Trip", "", "dir");
  assert.ok(fs.statSync(d.path).isDirectory());
  assert.strictEqual(claim(dir, "Trip", "", "dir").path, path.join(dir, "Trip (1)"));
  fs.rmSync(dir, { recursive: true, force: true });
});

test("freeNameScript: simultaneous claims of one name never share a path", async () => {
  const { spawn } = require("node:child_process");
  const script = qmlStringProperty("freeNameScript");
  for (const kind of ["file", "dir"]) {
    const dir = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "filen-race-"));
    const runs = Array.from({ length: 24 }, () => new Promise((resolve) => {
      const p = spawn("bash", ["-c", script, "filen-free-name", dir, "same", kind === "dir" ? "" : ".jpg", kind]);
      let out = "";
      p.stdout.on("data", (b) => { out += b; });
      p.on("close", (code) => resolve({ code, out }));
    }));
    const results = await Promise.all(runs);
    const paths = results.map((r) => { assert.strictEqual(r.code, 0); return r.out; });
    assert.strictEqual(new Set(paths).size, paths.length, kind + ": duplicate claim " + paths.join(" | "));
    assert.strictEqual(fs.readdirSync(dir).length, paths.length);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("freeNameScript never opens a FIFO or writes through a symlink", () => {
  const dir = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "filen-claim-"));
  spawnSync("mkfifo", [path.join(dir, "x.txt")]);
  const outside = path.join(dir, "outside");
  fs.symlinkSync(outside, path.join(dir, "x (1).txt"));
  const r = spawnSync("bash", ["-c", qmlStringProperty("freeNameScript"), "filen-free-name", dir, "x", ".txt", "file"],
                      { timeout: 5000 });
  assert.strictEqual(r.signal, null, "must not block on the FIFO");
  assert.strictEqual(r.stdout.toString(), path.join(dir, "x (2).txt"));
  assert.strictEqual(fs.existsSync(outside), false);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("freeNameScript: hostile names are data, never script", () => {
  const dir = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "filen-claim-"));
  // Local names never contain "/", so the payload uses a relative marker
  // and runs with the temp dir as cwd.
  const stem = "$(touch pwned) `touch pwned`; touch pwned";
  const r = spawnSync("bash", ["-c", qmlStringProperty("freeNameScript"), "filen-free-name", dir, stem, ".txt", "file"],
                      { cwd: dir });
  assert.strictEqual(r.status, 0);
  assert.strictEqual(r.stdout.toString(), path.join(dir, stem + ".txt"));
  assert.strictEqual(fs.existsSync(path.join(dir, "pwned")), false);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("discardPlaceholderScript removes only an empty claim, never data or links", () => {
  const dir = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "filen-discard-"));
  const script = qmlStringProperty("discardPlaceholderScript");
  const run = (p) => spawnSync("bash", ["-c", script, "filen-discard", p]).status;
  const j = (n) => path.join(dir, n);
  fs.writeFileSync(j("empty.pdf"), "");
  fs.writeFileSync(j("full.pdf"), "data");
  fs.mkdirSync(j("emptydir"));
  fs.mkdirSync(j("partdir")); fs.writeFileSync(j("partdir/a"), "x");
  fs.writeFileSync(j("target"), "");
  fs.symlinkSync(j("target"), j("link.pdf"));
  for (const n of ["empty.pdf", "full.pdf", "emptydir", "partdir", "link.pdf", "missing"]) assert.strictEqual(run(j(n)), 0);
  assert.strictEqual(fs.existsSync(j("empty.pdf")), false);
  assert.strictEqual(fs.existsSync(j("emptydir")), false);
  assert.strictEqual(fs.readFileSync(j("full.pdf"), "utf8"), "data");
  assert.ok(fs.existsSync(j("partdir/a")));
  assert.ok(fs.lstatSync(j("link.pdf")).isSymbolicLink());
  assert.ok(fs.existsSync(j("target")));
  fs.rmSync(dir, { recursive: true, force: true });
});

test("Service: download names are claimed on disk, not reserved in memory", () => {
  const src = fs.readFileSync(path.join(__dirname, "..", "Service.qml"), "utf8");
  assert.doesNotMatch(src, /pendingLocalPaths/, "an in-memory reservation list races across async resolvers");
  assert.match(src, /freeNameScript, "filen-free-name",\s*\n\s*downloadDir, parts\.stem, parts\.ext, t\.isDir \? "dir" : "file"\]/);
});
