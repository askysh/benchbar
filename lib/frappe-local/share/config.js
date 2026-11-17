"use strict";
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const EX_CONFIG = 78;
const MAX_TOTAL_S_CEILING = 43200;

const KEYS = ["v", "protocol", "listen", "tls", "share_site", "web_port", "deadline_epoch", "started_epoch", "max_total_s", "state_dir",
    "devices", "control_sock", "log_dir", "python", "signin_helper", "max_conns", "max_body_mb", "label", "room_label", "site_label", "copy_made", "seats"];
// Written only by a CLI that knows them; a config from an older CLI simply lacks them.
const OPTIONAL_KEYS = ["app_routes"];
const SEAT_KEYS = ["seat_id", "user", "full_name", "roles"];
const SEAT_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;
const MAX_SEATS = 50;
const SHARE_SITE_RE = /^[a-z0-9][a-z0-9-]{0,60}\.localhost$/;

function invalid(reason) {
    const e = new Error(`invalid gateway config: ${reason}`);
    e.exitCode = EX_CONFIG;
    return e;
}

const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

function integer(cfg, key, min, max) {
    const v = cfg[key];
    if (!Number.isInteger(v) || v < min || v > max) throw invalid(`${key} must be an integer from ${min} to ${max}`);
    return v;
}

function text(v, key, { absolute = false, max = 1024 } = {}) {
    if (typeof v !== "string" || v.length === 0 || v.length > max) throw invalid(`${key} must be a non-empty string`);
    if (absolute && !path.isAbsolute(v)) throw invalid(`${key} must be an absolute path`);
    return v;
}

// Written by the host's share setup from share.json: the allowed users, each behind an opaque id (J10).
function checkSeats(seats) {
    if (!Array.isArray(seats) || seats.length < 1 || seats.length > MAX_SEATS) throw invalid(`seats must hold 1 to ${MAX_SEATS} entries`);
    const ids = new Set();
    const users = new Set();
    for (const seat of seats) {
        if (!isObject(seat) || Object.keys(seat).length !== SEAT_KEYS.length || !SEAT_KEYS.every((k) => k in seat)) throw invalid("a seat has the wrong keys");
        if (typeof seat.seat_id !== "string" || !SEAT_ID_RE.test(seat.seat_id) || ids.has(seat.seat_id)) throw invalid("seat_id must be unique and plain");
        text(seat.user, "seat user", { max: 200 });
        text(seat.full_name, "seat full_name", { max: 200 });
        if (!Array.isArray(seat.roles) || seat.roles.length > 30 || !seat.roles.every((r) => typeof r === "string" && r.length > 0 && r.length <= 100)) {
            throw invalid("seat roles must be a list of names");
        }
        // Two seats on one user would let releasing one wipe the session of the other.
        if (users.has(seat.user.toLowerCase())) throw invalid("two seats map to one user");
        ids.add(seat.seat_id);
        users.add(seat.user.toLowerCase());
    }
}

function checkShape(cfg) {
    if (!isObject(cfg)) throw invalid("not an object");
    for (const key of Object.keys(cfg)) if (!KEYS.includes(key) && !OPTIONAL_KEYS.includes(key)) throw invalid(`unknown key ${key}`);
    for (const key of KEYS) if (!(key in cfg)) throw invalid(`missing ${key}`);
    if (cfg.v !== 3 || cfg.protocol !== 3) throw invalid("v and protocol must be 3");
    if (!isObject(cfg.listen)) throw invalid("listen must be an object");
    text(cfg.listen.host, "listen.host", { max: 255 });
    integer(cfg.listen, "port", 0, 65535);
    if (!isObject(cfg.tls)) throw invalid("tls must be an object");
    text(cfg.tls.key, "tls.key", { absolute: true });
    text(cfg.tls.cert, "tls.cert", { absolute: true });
    if (typeof cfg.share_site !== "string" || !SHARE_SITE_RE.test(cfg.share_site)) throw invalid("share_site is not a *.localhost name");
    integer(cfg, "web_port", 1, 65535);
    integer(cfg, "started_epoch", 1, Number.MAX_SAFE_INTEGER);
    integer(cfg, "max_total_s", 1, MAX_TOTAL_S_CEILING);
    for (const key of ["state_dir", "devices", "control_sock", "log_dir", "python", "signin_helper"]) text(cfg[key], key, { absolute: true });
    if (!isObject(cfg.max_conns)) throw invalid("max_conns must be an object");
    for (const key of ["per_device", "total", "unpaired_total", "unpaired_per_ip"]) integer(cfg.max_conns, key, 1, 100000);
    integer(cfg, "max_body_mb", 1, 1024);
    text(cfg.label, "label", { max: 200 });
    text(cfg.room_label, "room_label", { max: 200 });
    text(cfg.site_label, "site_label", { max: 200 });
    checkSeats(cfg.seats);
    if (typeof cfg.copy_made !== "string" || Number.isNaN(Date.parse(cfg.copy_made))) throw invalid("copy_made must be an ISO date");
    if ("app_routes" in cfg && (!Array.isArray(cfg.app_routes) || cfg.app_routes.length > 32
        || !cfg.app_routes.every((r) => typeof r === "string" && r.length > 0 && r.length <= 64))) {
        throw invalid("app_routes must be a list of at most 32 routes");
    }
}

// The deadline is checked here and nowhere else at startup: missing, past, or
// beyond the cap means the job never listens.
function checkDeadline(cfg, nowMs) {
    const d = cfg.deadline_epoch;
    if (!Number.isInteger(d)) throw invalid("deadline_epoch is missing or not an integer");
    if (d * 1000 <= nowMs) throw invalid("deadline_epoch is in the past");
    if (d > cfg.started_epoch + cfg.max_total_s) throw invalid("deadline_epoch is beyond started_epoch + max_total_s");
}

function load(file, nowMs) {
    let cfg;
    try {
        cfg = JSON.parse(fs.readFileSync(file, "utf8"));
    } catch (e) {
        throw invalid(e.code === "ENOENT" ? "file not found" : "unreadable or not JSON");
    }
    checkShape(cfg);
    checkDeadline(cfg, nowMs);
    return cfg;
}

// Written the way devices.json is: a temp file in the same directory, fsynced,
// renamed over the target, so a reader sees the old or the new file, never a
// partial one.
function writeDeadline(file, deadlineEpoch) {
    const cfg = JSON.parse(fs.readFileSync(file, "utf8"));
    cfg.deadline_epoch = deadlineEpoch;
    const tmp = `${file}.tmp-${process.pid}-${crypto.randomBytes(4).toString("hex")}`;
    const fd = fs.openSync(tmp, "wx", 0o600);
    try {
        fs.writeSync(fd, JSON.stringify(cfg) + "\n");
        fs.fsyncSync(fd);
    } catch (e) {
        fs.closeSync(fd);
        fs.rmSync(tmp, { force: true });
        throw e;
    }
    fs.closeSync(fd);
    try {
        fs.renameSync(tmp, file);
    } catch (e) {
        fs.rmSync(tmp, { force: true });
        throw e;
    }
}

module.exports = { EX_CONFIG, load, writeDeadline };
