"use strict";
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const SCHEMA_V = 3;
const STATUSES = new Set(["active"]);
const SEATLESS_TTL_MS = 120_000;
const ID_RE = /^d_[0-9a-f]{8}$/;
const FP_RE = /^sha256:[0-9a-f]{64}$/;
const MAX_TEXT = 200;
const STALE_LOCK_MS = 10_000;
const LOCK_TIMEOUT_MS = 5_000;
const LOCK_RETRY_MS = 20;
const TOUCH_INTERVAL_MS = 60_000;
const DAY_MS = 86_400_000;

function fail(code, message) {
    const e = new Error(message);
    e.code = code;
    return e;
}

function sleepSync(ms) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function validateDevice(d) {
    const text = (v) => typeof v === "string" && v.length > 0 && v.length <= MAX_TEXT;
    const optionalText = (v) => v === undefined || v === null || (typeof v === "string" && v.length <= MAX_TEXT);
    if (!d || typeof d !== "object" || Array.isArray(d)) throw fail("schema", "device must be an object");
    if (typeof d.id !== "string" || !ID_RE.test(d.id)) throw fail("schema", "bad device id");
    if (!text(d.name)) throw fail("schema", "bad device name");
    if (!text(d.model)) throw fail("schema", "bad device model");
    if (typeof d.fp !== "string" || !FP_RE.test(d.fp)) throw fail("schema", "bad device fingerprint");
    if (!STATUSES.has(d.status)) throw fail("schema", "bad device status");
    if (!optionalText(d.user) || !optionalText(d.seat_id) || !optionalText(d.paired_ip) || !optionalText(d.added) || !optionalText(d.last_seen)) {
        throw fail("schema", "bad device field");
    }
}

function seatTaken(doc, seatId, except) {
    return doc.devices.some((d) => d !== except && d.seat_id === seatId);
}

function isSeatlessExpired(d, now) {
    return !d.seat_id && now - Date.parse(d.added) >= SEATLESS_TTL_MS;
}

function newId(random = crypto.randomBytes) {
    return "d_" + random(4).toString("hex");
}

// Mutations take an exclusive-create lock file (open with 'wx': atomic on
// every local filesystem, and the only primitive the bash side can share by
// calling this file's CLI). A lock older than STALE_LOCK_MS belongs to a dead
// process and is broken. The lock holds a unique token and is released only if
// it still holds ours, so a holder whose lock was broken as stale never deletes
// the next holder's lock.
class DeviceStore {
    constructor(file, { now = Date.now, lockTimeoutMs = LOCK_TIMEOUT_MS } = {}) {
        this.file = file;
        this.now = now;
        this.lockTimeoutMs = lockTimeoutMs;
        this.lockFile = path.join(path.dirname(file), path.basename(file, path.extname(file)) + ".lock");
        this.cache = null;
        this.token = null;
    }

    #read() {
        let stat;
        try {
            stat = fs.statSync(this.file);
        } catch (e) {
            if (e.code === "ENOENT") return { v: SCHEMA_V, devices: [], blocked: [] };
            throw e;
        }
        const stamp = `${stat.ino}:${stat.mtimeMs}:${stat.size}`;
        if (this.cache && this.cache.stamp === stamp) return this.cache.doc;
        let doc;
        try {
            doc = JSON.parse(fs.readFileSync(this.file, "utf8"));
        } catch {
            throw fail("schema", "devices file is not valid JSON");
        }
        if (!doc || typeof doc !== "object" || Array.isArray(doc)) throw fail("schema", "devices file must be an object");
        doc.blocked ??= [];
        // A future v is read as-is and written back with its own v and unknown fields intact.
        if (!Number.isInteger(doc.v) || doc.v < SCHEMA_V) throw fail("schema", "unsupported devices file version");
        if (!Array.isArray(doc.devices)) throw fail("schema", "devices must be an array");
        if (!Array.isArray(doc.blocked) || !doc.blocked.every((fp) => typeof fp === "string" && FP_RE.test(fp))) throw fail("schema", "bad blocked list");
        doc.devices.forEach(validateDevice);
        this.cache = { stamp, doc };
        return doc;
    }

    #write(doc) {
        const tmp = `${this.file}.tmp-${process.pid}-${crypto.randomBytes(4).toString("hex")}`;
        const fd = fs.openSync(tmp, "wx", 0o600);
        try {
            fs.writeSync(fd, JSON.stringify(doc, null, 2) + "\n");
            fs.fsyncSync(fd);
        } catch (e) {
            fs.closeSync(fd);
            fs.rmSync(tmp, { force: true });
            throw e;
        }
        fs.closeSync(fd);
        try {
            fs.renameSync(tmp, this.file);
        } catch (e) {
            fs.rmSync(tmp, { force: true });
            throw e;
        }
        this.cache = null;
    }

    #acquire() {
        fs.mkdirSync(path.dirname(this.file), { recursive: true, mode: 0o700 });
        const deadline = Date.now() + this.lockTimeoutMs;
        for (;;) {
            try {
                const fd = fs.openSync(this.lockFile, "wx", 0o600);
                this.token = `${process.pid}:${crypto.randomBytes(8).toString("hex")}`;
                fs.writeSync(fd, this.token);
                fs.closeSync(fd);
                return;
            } catch (e) {
                if (e.code !== "EEXIST") throw e;
            }
            try {
                if (Date.now() - fs.statSync(this.lockFile).mtimeMs > STALE_LOCK_MS) {
                    fs.rmSync(this.lockFile, { force: true });
                    continue;
                }
            } catch (e) {
                if (e.code === "ENOENT") continue;
                throw e;
            }
            if (Date.now() >= deadline) throw fail("lock", "devices lock is held");
            sleepSync(LOCK_RETRY_MS);
        }
    }

    #mutate(fn) {
        this.#acquire();
        try {
            const doc = JSON.parse(JSON.stringify(this.#read()));
            const result = fn(doc);
            if (result.changed) this.#write(doc);
            return result.value;
        } finally {
            this.#release();
        }
    }

    #release() {
        try {
            if (fs.readFileSync(this.lockFile, "utf8") === this.token) fs.rmSync(this.lockFile, { force: true });
        } catch (e) {
            if (e.code !== "ENOENT") throw e;
        }
    }

    #index(doc, id) {
        const i = doc.devices.findIndex((d) => d.id === id);
        if (i < 0) throw fail("not_found", `device ${id} not found`);
        return i;
    }

    list() {
        return JSON.parse(JSON.stringify(this.#read().devices));
    }

    findBySpki(fp) {
        const d = this.#read().devices.find((x) => x.fp === fp);
        return d ? JSON.parse(JSON.stringify(d)) : null;
    }

    // `cap` is the people limit (the seat count). It is checked inside the lock, so
    // concurrent finishes cannot exceed it (J5).
    add(dev, { cap } = {}) {
        const iso = new Date(this.now()).toISOString();
        const device = { status: "active", added: iso, last_seen: iso, ...dev };
        validateDevice(device);
        return this.#mutate((doc) => {
            if (doc.blocked.includes(device.fp)) throw fail("blocked", "this device was removed from the room");
            if (doc.devices.some((d) => d.id === device.id || d.fp === device.fp)) throw fail("duplicate", "duplicate device id or fingerprint");
            if (cap !== undefined && doc.devices.length >= cap) throw fail("full", "the room is full");
            if (typeof device.seat_id === "string" && seatTaken(doc, device.seat_id, null)) throw fail("seat_taken", "seat is already held");
            doc.devices.push(device);
            return { changed: true, value: device };
        });
    }

    remove(id) {
        return this.#mutate((doc) => {
            const i = doc.devices.findIndex((d) => d.id === id);
            if (i >= 0) doc.devices.splice(i, 1);
            return { changed: i >= 0, value: i >= 0 };
        });
    }

    // The check and the set are one step under the lock (J10). Returns the seat the device held before.
    takeSeat(id, seat) {
        return this.#mutate((doc) => {
            const target = doc.devices[this.#index(doc, id)];
            if (seatTaken(doc, seat.seat_id, target)) throw fail("seat_taken", "seat is already held");
            const before = target.seat_id ? { seat_id: target.seat_id, user: target.user } : null;
            const changed = target.seat_id !== seat.seat_id;
            target.seat_id = seat.seat_id;
            target.user = seat.user;
            return { changed, value: before };
        });
    }

    block(fp) {
        return this.#mutate((doc) => {
            const changed = !doc.blocked.includes(fp);
            if (changed) doc.blocked.push(fp);
            return { changed, value: undefined };
        });
    }

    isBlocked(fp) {
        return this.#read().blocked.includes(fp);
    }

    // A new code: a removal holds against the code the person knew, not for the whole room.
    clearBlocked() {
        return this.#mutate((doc) => {
            const changed = doc.blocked.length > 0;
            doc.blocked = [];
            return { changed, value: changed };
        });
    }

    // A device that joined and never picked a seat loses its place (J5).
    reapSeatless(now = this.now()) {
        return this.#mutate((doc) => {
            const gone = doc.devices.filter((d) => isSeatlessExpired(d, now));
            doc.devices = doc.devices.filter((d) => !gone.includes(d));
            return { changed: gone.length > 0, value: gone };
        });
    }

    // The room ended or a new one starts: nothing carries over, including the blocked list.
    // Written without reading, so an old or damaged file cannot stop it.
    emptyAll() {
        this.#acquire();
        try {
            this.#write({ v: SCHEMA_V, devices: [], blocked: [] });
        } finally {
            this.#release();
        }
    }

    // Throttled: the gateway calls it per request, and prune() needs last_seen.
    touch(id) {
        const t = this.now();
        // Checked against the cache before the lock so a throttled call does no file I/O.
        const cached = this.cache && this.cache.doc.devices.find((x) => x.id === id);
        if (cached && t - Date.parse(cached.last_seen) < TOUCH_INTERVAL_MS) return;
        return this.#mutate((doc) => {
            const d = doc.devices[this.#index(doc, id)];
            if (t - Date.parse(d.last_seen) < TOUCH_INTERVAL_MS) return { changed: false, value: undefined };
            d.last_seen = new Date(t).toISOString();
            return { changed: true, value: undefined };
        });
    }

    prune(now = this.now(), days = 30) {
        const cutoff = new Date(now).getTime() - days * DAY_MS;
        return this.#mutate((doc) => {
            const gone = doc.devices.filter((d) => Date.parse(d.last_seen || d.added) < cutoff).map((d) => d.id);
            doc.devices = doc.devices.filter((d) => !gone.includes(d.id));
            return { changed: gone.length > 0, value: gone };
        });
    }
}

function load(file, opts) {
    return new DeviceStore(file, opts);
}

// node devices.js remove ID: exit 0 removed, 2 unknown id, 1 anything else.
function cli(argv, env) {
    const [command, id] = argv;
    const file = env.FL_SHARE_DEVICES_FILE ||
        (env.FL_STATE_DIR ? path.join(env.FL_STATE_DIR, "share", "devices.json") : null);
    if (command !== "remove" || typeof id !== "string" || !ID_RE.test(id) || !file) {
        process.stderr.write("usage: devices.js remove ID  (FL_SHARE_DEVICES_FILE or FL_STATE_DIR set)\n");
        return 1;
    }
    try {
        return load(file).remove(id) ? 0 : 2;
    } catch (e) {
        process.stderr.write(`devices.js: ${e.message}\n`);
        return 1;
    }
}

if (require.main === module) process.exitCode = cli(process.argv.slice(2), process.env);

module.exports = { load, newId, isSeatlessExpired, DeviceStore, SEATLESS_TTL_MS };
