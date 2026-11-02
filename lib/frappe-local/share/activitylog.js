"use strict";
const fs = require("fs");
const path = require("path");

const MAX_PATH_CHARS = 200;
const DAY_MS = 86_400_000;
const FILE_RE = /^activity-(\d{4}-\d{2}-\d{2})\.log$/;
const CONTROL = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g;

const clean = (value) => String(value ?? "").replace(CONTROL, "");

// Two path segments, no query: the log must never carry a document name (A16).
function loggedPath(rawPath) {
    const segments = clean(rawPath).split(/[?#]/, 1)[0].split("/").filter(Boolean).slice(0, 2);
    return ("/" + segments.join("/")).slice(0, MAX_PATH_CHARS);
}

class ActivityLog {
    constructor(dir, { now = Date.now, retentionDays = 14 } = {}) {
        this.dir = dir;
        this.now = now;
        this.retentionDays = retentionDays;
    }

    #dayOf(ms) {
        return new Date(ms).toISOString().slice(0, 10);
    }

    // Destructures the five logged fields: a Cookie or Authorization value
    // handed in alongside has nowhere to go.
    record({ device, user, method, path: requestPath, status }) {
        const ms = this.now();
        const line = JSON.stringify({
            ts: new Date(ms).toISOString(),
            device: clean(device).slice(0, MAX_PATH_CHARS),
            user: clean(user).slice(0, MAX_PATH_CHARS),
            method: clean(method).slice(0, 16),
            path: loggedPath(requestPath),
            status: Number.isInteger(status) ? status : 0
        });
        fs.mkdirSync(this.dir, { recursive: true, mode: 0o700 });
        fs.appendFileSync(path.join(this.dir, `activity-${this.#dayOf(ms)}.log`), line + "\n", { mode: 0o600 });
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
