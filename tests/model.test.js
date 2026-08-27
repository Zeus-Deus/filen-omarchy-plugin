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

test("isUsableName rejects control characters and NUL", () => {
  assert.strictEqual(M.isUsableName("a\u0000b"), false);
  assert.strictEqual(M.isUsableName("a\nb"), false);
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
