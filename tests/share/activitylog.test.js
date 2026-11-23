"use strict";
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { ActivityLog } = require("../../lib/frappe-local/share/activitylog.js");

const T0 = Date.parse("2026-11-02T10:00:00Z");
const DAY = 86400000;
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), "bb-act-"));
const lines = (dir) => fs.readFileSync(path.join(dir, "activity-2026-11-02.log"), "utf8").trim().split("\n").map((l) => JSON.parse(l));

test("a record is one JSON line in a daily 0600 file with exactly the documented fields", () => {
    const dir = tmp();
    const log = new ActivityLog(dir, { now: () => T0 });
    log.record({ device: "d_00000001", seat: "s_0a1b2c3d", method: "GET", path: "/app/sales-order", status: 200 });
    const [r] = lines(dir);
    assert.deepStrictEqual(r, { ts: "2026-11-02T10:00:00.000Z", device: "d_00000001", seat: "s_0a1b2c3d", method: "GET", path: "/app/sales-order", status: 200 });
    assert.deepStrictEqual(Object.keys(r), ["ts", "device", "seat", "method", "path", "status"]);
    assert.strictEqual(fs.statSync(path.join(dir, "activity-2026-11-02.log")).mode & 0o777, 0o600);
});

test("the query is dropped and the path is redacted to two segments", () => {
    const dir = tmp();
    const log = new ActivityLog(dir, { now: () => T0 });
    log.record({ device: "d", user: "u", method: "GET", path: "/app/sales-order/SO-0042?customer=Acme%20Ltd#x", status: 200 });
    log.record({ device: "d", user: "u", method: "POST", path: "/api/method/frappe.client.get?name=Secret", status: 200 });
    const r = lines(dir);
    assert.strictEqual(r[0].path, "/app/sales-order");
    assert.strictEqual(r[1].path, "/api/method");
    assert.ok(!JSON.stringify(r).includes("SO-0042") && !JSON.stringify(r).includes("Acme") && !JSON.stringify(r).includes("Secret"));
});

test("file names are never logged", () => {
    const dir = tmp();
    const log = new ActivityLog(dir, { now: () => T0 });
    log.record({ device: "d", user: "u", method: "GET", path: "/files/Secret.pdf", status: 200 });
    log.record({ device: "d", user: "u", method: "GET", path: "/private/files/Payroll.xlsx?x=1", status: 200 });
    const r = lines(dir);
    assert.deepStrictEqual(r.map((x) => x.path), ["/files", "/private/files"]);
});

test("a newline or other control character cannot forge a line", () => {
    const dir = tmp();
    const log = new ActivityLog(dir, { now: () => T0 });
    log.record({ device: "d\n{\"x\":1}", user: "u\r\nfake", method: "GET", path: "/app/a\n{\"ts\":\"forged\"}/b\u0000c\u2028d", status: 200 });
    const raw = fs.readFileSync(path.join(dir, "activity-2026-11-02.log"), "utf8");
    assert.strictEqual(raw.split("\n").length, 2, "exactly one line plus the trailing newline");
    const r = JSON.parse(raw);
    assert.ok(!/[\u0000-\u001f\u007f\u2028\u2029]/.test(r.path + r.device + r.user));
});

test("a path longer than 200 characters is capped", () => {
    const dir = tmp();
    const log = new ActivityLog(dir, { now: () => T0 });
    log.record({ device: "d", user: "u", method: "GET", path: "/app/" + "a".repeat(500), status: 200 });
    assert.strictEqual(lines(dir)[0].path.length, 200);
});

test("Cookie, Authorization and any other field cannot reach a record", () => {
    const dir = tmp();
    const log = new ActivityLog(dir, { now: () => T0 });
    log.record({ device: "d", user: "u", method: "GET", path: "/app", status: 200, cookie: "sid=SECRETSID", authorization: "token K:S", headers: { cookie: "sid=SECRETSID" } });
    const raw = fs.readFileSync(path.join(dir, "activity-2026-11-02.log"), "utf8");
    assert.ok(!raw.includes("SECRETSID") && !raw.includes("token K:S"));
    assert.deepStrictEqual(Object.keys(lines(dir)[0]), ["ts", "device", "seat", "method", "path", "status"]);
});

// ---- #159 SHARE-10: the seat's id, not its e-mail address; a day's file has a size limit
test("a line names the seat by its id, and no e-mail address reaches the file", () => {
    const dir = tmp();
    const log = new ActivityLog(dir, { now: () => T0 });
    log.record({ device: "d_00000001", seat: "s_0a1b2c3d", user: "priya.test@example.com", method: "GET", path: "/app/sales-order", status: 200 });
    log.record({ device: "d_00000002", seat: null, method: "GET", path: "/_benchbar/hello", status: 200 });
    const text = fs.readFileSync(path.join(dir, "activity-2026-11-02.log"), "utf8");
    const lines = text.trim().split("\n").map((l) => JSON.parse(l));
    assert.deepStrictEqual(lines[0], { ts: "2026-11-02T10:00:00.000Z", device: "d_00000001", seat: "s_0a1b2c3d", method: "GET", path: "/app/sales-order", status: 200 });
    assert.strictEqual(lines[1].seat, "");
    assert.ok(!text.includes("@") && !text.includes("priya"), text);
});

test("a day's file stops at its size limit with one closing line, and the next day records again", () => {
    const dir = tmp();
    let t = T0;
    const log = new ActivityLog(dir, { now: () => t, maxDayBytes: 600 });
    for (let i = 0; i < 50; i++) log.record({ device: "d_00000001", seat: "s_0a1b2c3d", method: "GET", path: "/app/sales-order", status: 200 });
    const file = path.join(dir, "activity-2026-11-02.log");
    const lines = fs.readFileSync(file, "utf8").trim().split("\n").map((l) => JSON.parse(l));
    assert.ok(fs.statSync(file).size <= 600, `the file is ${fs.statSync(file).size} bytes`);
    assert.ok(lines.length < 50 && lines.length > 2, `${lines.length} lines`);
    assert.strictEqual(lines.at(-1).path, "/_benchbar/log-full");
    assert.strictEqual(lines.filter((l) => l.path === "/_benchbar/log-full").length, 1);
    // a gateway that starts again on the same day finds the file full and adds nothing
    const again = new ActivityLog(dir, { now: () => t, maxDayBytes: 600 });
    const before = fs.statSync(file).size;
    again.record({ device: "d", seat: "s", method: "GET", path: "/app", status: 200 });
    assert.strictEqual(fs.statSync(file).size, before);
    t = T0 + DAY;
    log.record({ device: "d", seat: "s", method: "GET", path: "/app", status: 200 });
    assert.strictEqual(fs.readFileSync(path.join(dir, "activity-2026-11-03.log"), "utf8").trim().split("\n").length, 1);
});

test("a new day starts a new file", () => {
    const dir = tmp();
    let t = T0;
    const log = new ActivityLog(dir, { now: () => t });
    log.record({ device: "d", user: "u", method: "GET", path: "/app", status: 200 });
    t = T0 + DAY;
    log.record({ device: "d", user: "u", method: "GET", path: "/app", status: 200 });
    assert.deepStrictEqual(fs.readdirSync(dir).sort(), ["activity-2026-11-02.log", "activity-2026-11-03.log"]);
});

test("prune removes activity files older than 14 days and nothing else", () => {
    const dir = tmp();
    const names = ["activity-2026-10-17.log", "activity-2026-10-18.log", "activity-2026-10-19.log", "activity-2026-11-02.log", "devices.json", "activity-notes.txt"];
    for (const n of names) fs.writeFileSync(path.join(dir, n), "x");
    const log = new ActivityLog(dir, { now: () => T0 });
    const removed = log.prune();
    assert.deepStrictEqual(removed.sort(), ["activity-2026-10-17.log", "activity-2026-10-18.log"]);
    assert.deepStrictEqual(fs.readdirSync(dir).sort(), names.filter((n) => !removed.includes(n)).sort());
    assert.ok(fs.existsSync(path.join(dir, "activity-2026-10-19.log")), "exactly 14 days old is kept");
});

test("retentionDays is honoured", () => {
    const dir = tmp();
    for (const n of ["activity-2026-10-31.log", "activity-2026-11-01.log"]) fs.writeFileSync(path.join(dir, n), "x");
    new ActivityLog(dir, { now: () => T0, retentionDays: 1 }).prune();
    assert.deepStrictEqual(fs.readdirSync(dir), ["activity-2026-11-01.log"]);
});

test("the directory is created when missing", () => {
    const dir = path.join(tmp(), "nested", "share");
    new ActivityLog(dir, { now: () => T0 }).record({ device: "d", user: "u", method: "GET", path: "/app", status: 200 });
    assert.ok(fs.existsSync(path.join(dir, "activity-2026-11-02.log")));
});

test("prune on a directory that does not exist yet is a no-op", () => {
    assert.deepStrictEqual(new ActivityLog(path.join(tmp(), "none"), { now: () => T0 }).prune(), []);
});
