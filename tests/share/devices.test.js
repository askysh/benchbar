"use strict";
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");
const devices = require("../../lib/frappe-local/share/devices.js");

const DEVICES_JS = path.join(__dirname, "../../lib/frappe-local/share/devices.js");
const fp = (n) => "sha256:" + String(n).padStart(64, "0");
const id = (n) => "d_" + String(n).padStart(8, "0");
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), "bb-dev-"));
const T0 = Date.parse("2026-11-02T10:00:00Z");
const DAY = 86400000;

function store(dir, now = () => T0) {
    return devices.load(path.join(dir, "devices.json"), { now });
}
const dev = (n, extra = {}) => ({ id: id(n), name: `Mac ${n}`, model: "MacBookPro18,1", fp: fp(n), paired_ip: "192.168.1.23", ...extra });

test("a missing file loads empty; add writes 0600 atomically and leaves no temp or lock file", () => {
    const dir = tmp();
    const s = store(dir);
    assert.deepStrictEqual(s.list(), []);
    s.add(dev(1));
    const file = path.join(dir, "devices.json");
    assert.strictEqual(fs.statSync(file).mode & 0o777, 0o600);
    assert.deepStrictEqual(fs.readdirSync(dir), ["devices.json"]);
    const j = JSON.parse(fs.readFileSync(file, "utf8"));
    assert.strictEqual(j.v, 2);
    assert.strictEqual(j.devices[0].status, "pending_confirm");
    assert.strictEqual(j.devices[0].added, "2026-11-02T10:00:00.000Z");
    assert.strictEqual(j.devices[0].last_seen, "2026-11-02T10:00:00.000Z");
});

test("a write that fails mid-way leaves the previous file intact and no temp file", () => {
    const dir = tmp();
    const s = store(dir);
    s.add(dev(1));
    const file = path.join(dir, "devices.json");
    const before = fs.readFileSync(file, "utf8");
    const real = fs.renameSync;
    fs.renameSync = () => { throw new Error("boom"); };
    try {
        assert.throws(() => s.add(dev(2)), /boom/);
    } finally {
        fs.renameSync = real;
    }
    assert.strictEqual(fs.readFileSync(file, "utf8"), before);
    assert.deepStrictEqual(fs.readdirSync(dir), ["devices.json"]);
});

test("unknown fields and an unknown future v survive a round trip", () => {
    const dir = tmp();
    const file = path.join(dir, "devices.json");
    fs.writeFileSync(file, JSON.stringify({
        v: 7, future_top: { a: 1 },
        devices: [{ id: id(1), name: "A", model: "M", fp: fp(1), status: "active", added: "2026-10-01T00:00:00.000Z",
            last_seen: "2026-11-01T00:00:00.000Z", paired_ip: "10.0.0.1", future_field: [1, 2] }]
    }), { mode: 0o600 });
    const s = devices.load(file, { now: () => T0 });
    s.add(dev(2));
    const j = JSON.parse(fs.readFileSync(file, "utf8"));
    assert.strictEqual(j.v, 7);
    assert.deepStrictEqual(j.future_top, { a: 1 });
    assert.deepStrictEqual(j.devices[0].future_field, [1, 2]);
    assert.strictEqual(j.devices.length, 2);
});

test("strict schema: a corrupt or malformed file is refused, never silently reset", () => {
    const dir = tmp();
    const file = path.join(dir, "devices.json");
    const bad = [
        "not json", "[]", JSON.stringify({ v: 1, devices: [] }), JSON.stringify({ devices: [] }), JSON.stringify({ v: 2 }),
        JSON.stringify({ v: 2, devices: [{ id: "x", name: "A", model: "M", fp: fp(1), status: "active" }] }),
        JSON.stringify({ v: 2, devices: [{ id: id(1), name: "A", model: "M", fp: "sha256:short", status: "active" }] }),
        JSON.stringify({ v: 2, devices: [{ id: id(1), name: "A", model: "M", fp: fp(1), status: "weird" }] }),
        JSON.stringify({ v: 2, devices: [{ id: id(1), name: 5, model: "M", fp: fp(1), status: "active" }] })
    ];
    for (const b of bad) {
        fs.writeFileSync(file, b);
        assert.throws(() => devices.load(file, { now: () => T0 }).list(), undefined, b);
    }
});

test("add refuses an invalid device and a duplicate id or fingerprint", () => {
    const s = store(tmp());
    assert.throws(() => s.add({ ...dev(1), fp: "sha256:abc" }));
    assert.throws(() => s.add({ ...dev(1), id: "nope" }));
    assert.throws(() => s.add({ ...dev(1), status: "root" }));
    assert.throws(() => s.add({ ...dev(1), name: "x".repeat(500) }));
    s.add(dev(1));
    assert.throws(() => s.add({ ...dev(2), id: id(1) }), /duplicate/);
    assert.throws(() => s.add({ ...dev(2), fp: fp(1) }), /duplicate/);
});

test("confirm moves pending_confirm to active; findBySpki returns a copy", () => {
    const s = store(tmp());
    s.add(dev(1));
    assert.strictEqual(s.findBySpki(fp(1)).status, "pending_confirm");
    s.confirm(id(1));
    const d = s.findBySpki(fp(1));
    assert.strictEqual(d.status, "active");
    d.status = "hacked";
    assert.strictEqual(s.findBySpki(fp(1)).status, "active");
    assert.strictEqual(s.findBySpki(fp(9)), null);
    assert.throws(() => s.confirm(id(9)), /not found/);
});

test("remove deletes and reports whether it did", () => {
    const s = store(tmp());
    s.add(dev(1));
    assert.strictEqual(s.remove(id(1)), true);
    assert.strictEqual(s.remove(id(1)), false);
    assert.deepStrictEqual(s.list(), []);
});

test("a user cannot be mapped to two devices; the same device may be reassigned", () => {
    const s = store(tmp());
    s.add(dev(1)); s.add(dev(2));
    s.assign(id(1), "priya.test@example.com");
    assert.throws(() => s.assign(id(2), "Priya.Test@example.com"), (e) => e.code === "user_taken");
    s.assign(id(1), "priya.test@example.com");
    s.assign(id(2), "other@example.com");
    assert.strictEqual(s.findBySpki(fp(2)).user, "other@example.com");
    assert.throws(() => s.assign(id(9), "z@example.com"), /not found/);
});

test("prune removes a device unseen for 30 days and keeps a recent one", () => {
    let t = T0;
    const s = store(tmp(), () => t);
    s.add(dev(1)); s.add(dev(2));
    t = T0 + 29 * DAY;
    s.touch(id(2));
    t = T0 + 31 * DAY;
    assert.deepStrictEqual(s.prune(t), [id(1)]);
    assert.deepStrictEqual(s.list().map((d) => d.id), [id(2)]);
    assert.deepStrictEqual(s.prune(t), []);
});

test("touch writes at most once a minute", () => {
    let t = T0;
    const dir = tmp();
    const s = store(dir, () => t);
    s.add(dev(1));
    const file = path.join(dir, "devices.json");
    t = T0 + 10_000; s.touch(id(1));
    assert.strictEqual(JSON.parse(fs.readFileSync(file, "utf8")).devices[0].last_seen, "2026-11-02T10:00:00.000Z");
    t = T0 + 61_000; s.touch(id(1));
    assert.strictEqual(JSON.parse(fs.readFileSync(file, "utf8")).devices[0].last_seen, "2026-11-02T10:01:01.000Z");
});

test("two concurrent writer processes serialise through the lock (no lost update)", async () => {
    const dir = tmp();
    const file = path.join(dir, "devices.json");
    const code = `
        const d = require(${JSON.stringify(DEVICES_JS)});
        const [file, tag] = process.argv.slice(1);
        const s = d.load(file, {});
        for (let i = 0; i < 25; i++) {
            const n = tag + String(i).padStart(2, "0");
            s.add({ id: "d_" + n.padStart(8, "0"), name: "m" + n, model: "M", fp: "sha256:" + n.padStart(64, "0") });
        }`;
    const run = (tag) => new Promise((resolve) => {
        const c = spawn(process.execPath, ["-e", code, file, tag], { stdio: ["ignore", "ignore", "pipe"] });
        let err = ""; c.stderr.on("data", (b) => { err += b; });
        c.on("exit", (status) => resolve({ status, err }));
    });
    const [a, b] = await Promise.all([run("a"), run("b")]);
    assert.strictEqual(a.status, 0, a.err);
    assert.strictEqual(b.status, 0, b.err);
    const j = JSON.parse(fs.readFileSync(file, "utf8"));
    assert.strictEqual(j.devices.length, 50);
    assert.strictEqual(new Set(j.devices.map((d) => d.id)).size, 50);
    assert.deepStrictEqual(fs.readdirSync(dir), ["devices.json"]);
});

test("a stale lock (older than 10 s) is broken; a fresh one makes the writer wait then fail", () => {
    const dir = tmp();
    const lock = path.join(dir, "devices.lock");
    fs.writeFileSync(lock, "999999", { mode: 0o600 });
    const old = new Date(Date.now() - 60_000);
    fs.utimesSync(lock, old, old);
    const s = devices.load(path.join(dir, "devices.json"), { now: () => T0 });
    s.add(dev(1));
    assert.strictEqual(s.list().length, 1);

    fs.writeFileSync(lock, "999999", { mode: 0o600 });
    const s2 = devices.load(path.join(dir, "devices.json"), { now: () => T0, lockTimeoutMs: 150 });
    assert.throws(() => s2.add(dev(2)), /lock/);
    assert.ok(fs.existsSync(lock), "a lock we did not take is left alone");
});

test("CLI: remove ID takes the same lock and file; unknown id exits 2; bad usage exits 1", () => {
    const dir = tmp();
    const file = path.join(dir, "devices.json");
    const s = devices.load(file, { now: () => T0 });
    s.add(dev(1)); s.add(dev(2));
    const run = (...args) => spawnSync(process.execPath, [DEVICES_JS, ...args], { encoding: "utf8", env: { PATH: process.env.PATH, FL_SHARE_DEVICES_FILE: file } });
    let r = run("remove", id(1));
    assert.strictEqual(r.status, 0, r.stderr);
    assert.deepStrictEqual(devices.load(file, {}).list().map((d) => d.id), [id(2)]);
    assert.strictEqual(run("remove", id(1)).status, 2);
    assert.strictEqual(run("remove", "not-an-id").status, 1);
    assert.strictEqual(run("frobnicate", id(2)).status, 1);
    assert.strictEqual(run("remove").status, 1);
});
