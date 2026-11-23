"use strict";
const fs = require("fs");
const path = require("path");
const { redactPath } = require("./policy.js");

const MAX_PATH_CHARS = 200;
const DAY_MS = 86_400_000;
// One line per proxied request: a busy day writes tens of MB. A day's file stops here, with one closing
// line, so that a long share cannot fill the disk; the next day starts a new file.
const MAX_DAY_BYTES = 16 * 1024 * 1024;
const FULL_PATH = "/_benchbar/log-full";
const FILE_RE = /^activity-(\d{4}-\d{2}-\d{2})\.log$/;
const CONTROL = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g;

const clean = (value) => String(value ?? "").replace(CONTROL, "");

// redactPath: no query, no document or file name (A16).
function loggedPath(rawPath) {
    return redactPath(clean(rawPath)).slice(0, MAX_PATH_CHARS);
}

class ActivityLog {
    constructor(dir, { now = Date.now, retentionDays = 14, maxDayBytes = MAX_DAY_BYTES } = {}) {
        this.dir = dir;
        this.now = now;
        this.retentionDays = retentionDays;
        this.maxDayBytes = maxDayBytes;
        this.day = null;        // the day of the file below
        this.dayBytes = 0;      // its size, counted here after one stat
        this.dayFull = false;
    }

    #dayOf(ms) {
        return new Date(ms).toISOString().slice(0, 10);
    }

    #line(ms, { device, seat, method, path: requestPath, status }) {
        return JSON.stringify({
            ts: new Date(ms).toISOString(),
            device: clean(device).slice(0, MAX_PATH_CHARS),
            seat: clean(seat).slice(0, MAX_PATH_CHARS),
            method: clean(method).slice(0, 16),
            path: loggedPath(requestPath),
            status: Number.isInteger(status) ? status : 0
        }) + "\n";
    }

    // Destructures the five logged fields: a Cookie or Authorization value
    // handed in alongside has nowhere to go. `seat` is the seat's opaque id:
    // the user behind it (an e-mail address) is not written (share log shows
    // the seat's name from share.json).
    record({ device, seat, method, path: requestPath, status }) {
        const ms = this.now();
        const day = this.#dayOf(ms);
        const file = path.join(this.dir, `activity-${day}.log`);
        fs.mkdirSync(this.dir, { recursive: true, mode: 0o700 });
        if (day !== this.day) {
            this.day = day;
            // a file that a gateway before this one closed stays closed: its last line says so
            let tail = "";
            try {
                this.dayBytes = fs.statSync(file).size;
                const fd = fs.openSync(file, "r");
                try {
                    const buf = Buffer.alloc(Math.min(this.dayBytes, 1024));
                    fs.readSync(fd, buf, 0, buf.length, this.dayBytes - buf.length);
                    tail = buf.toString("utf8");
                } finally {
                    fs.closeSync(fd);
                }
            } catch {
                this.dayBytes = 0;
            }
            this.dayFull = this.dayBytes >= this.maxDayBytes || tail.trimEnd().split("\n").at(-1).includes(`"path":"${FULL_PATH}"`);
        }
        if (this.dayFull) return;
        let line = this.#line(ms, { device, seat, method, path: requestPath, status });
        // room is kept for the closing line, so the file never passes its limit
        const closing = this.#line(ms, { device: "", seat: "", method: "", path: FULL_PATH, status: 0 });
        if (this.dayBytes + Buffer.byteLength(line) + Buffer.byteLength(closing) > this.maxDayBytes) {
            this.dayFull = true;
            line = closing;
        }
        fs.appendFileSync(file, line, { mode: 0o600 });
        this.dayBytes += Buffer.byteLength(line);
    }

    prune() {
        const oldestKept = this.#dayOf(this.now() - this.retentionDays * DAY_MS);
        const removed = [];
        let names;
        try {
            names = fs.readdirSync(this.dir);
        } catch (e) {
            if (e.code === "ENOENT") return removed;
            throw e;
        }
        for (const name of names) {
            const m = FILE_RE.exec(name);
            if (m && m[1] < oldestKept) {
                fs.unlinkSync(path.join(this.dir, name));
                removed.push(name);
            }
        }
        return removed;
    }
}

module.exports = { ActivityLog };
