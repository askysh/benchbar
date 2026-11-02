"use strict";
const crypto = require("crypto");
const { checkCommit, sas } = require("./sas.js");
const { newId } = require("./devices.js");
const { PAIR_TTL_MS } = require("./ratelimit.js");

const PROTOCOL = 2;
const MAX_CODE_TRIES = 3;
const UNCONFIRMED_TTL_MS = 120_000;
const NAME_MAX = 40;
const MODEL_MAX = 32;
const NO_CONTROL_OR_BIDI = /^[^\u{0}-\u{1f}\u{7f}-\u{9f}\u{2028}\u{2029}\u{200e}\u{200f}\u{202a}-\u{202e}\u{2066}-\u{2069}]+$/u;

const hasExactKeys = (o, keys) => Object.keys(o).length === keys.length && keys.every((k) => Object.hasOwn(o, k));
const printable = (v, max) => typeof v === "string" && v.length <= max && NO_CONTROL_OR_BIDI.test(v);
const reply = (status, body) => ({ status, body });
const BAD = reply(400, { error: "bad_request" });
const WRONG_PROTOCOL = reply(426, { error: "protocol", need: PROTOCOL });

// The commit-reveal pairing queue (A10). A request holds its limiter slot from
// `start`, but only appears in the host's queue after a `reveal` whose Ng
// matches the commit, so a man in the middle cannot pick a certificate after
// seeing the nonces. The SAS is derived here from (Fh, Fg, Ng, Nh) and is never
// sent anywhere; the host types it and `approve` compares.
class Pairing {
    constructor({ store, limiter, hostFp, now }) {
        this.store = store;
        this.limiter = limiter;
        this.hostFp = hostFp;
        this.now = now;
        this.requests = new Map();  // request_id -> entry, from start until it ends
        this.queue = [];            // revealed entries in reveal order; only the head is shown
    }

    #end(entry) {
        this.requests.delete(entry.id);
        const i = this.queue.indexOf(entry);
        if (i >= 0) this.queue.splice(i, 1);
    }

    #finish(entry, status, body) {
        this.#end(entry);
        if (entry.respond) entry.respond(status, body);
    }

    // Always called before any other limiter call: the limiter drops expired
    // slots silently inside admit(), and a held guest has to hear about it.
    sweep() {
        const at = this.now();
        for (const ip of this.limiter.expired()) {
            const entry = [...this.requests.values()].find((e) => e.ip === ip);
            if (entry) this.#finish(entry, 408, { status: "expired" });
        }
        for (const entry of [...this.requests.values()]) {
            if (entry.expiresAt <= at) {
                this.limiter.onExpire(entry.ip);
                this.#finish(entry, 408, { status: "expired" });
            }
        }
    }

    start(ip, fg, msg) {
        this.sweep();
        if (msg.v !== PROTOCOL) return WRONG_PROTOCOL;
        if (!hasExactKeys(msg, ["v", "name", "model", "commit"]) || !printable(msg.name, NAME_MAX) || !printable(msg.model, MODEL_MAX) ||
            typeof msg.commit !== "string" || !/^[0-9a-f]{64}$/.test(msg.commit)) return BAD;
        const admitted = this.limiter.admit(ip);
        if (!admitted.ok) return reply(429, { status: "rate_limited", retry_after: this.limiter.retryAfter(ip) });
        const entry = {
            id: "r_" + crypto.randomBytes(8).toString("hex"), ip, fg, name: msg.name, model: msg.model, commit: msg.commit,
            nh: crypto.randomBytes(16).toString("hex"), ng: null, attempts: 0, respond: null, replaces: null,
            requestedAt: this.now(), expiresAt: this.now() + PAIR_TTL_MS
        };
        this.requests.set(entry.id, entry);
        return reply(200, { v: PROTOCOL, request_id: entry.id, nh: entry.nh });
    }

    // Returns {status, body}, or {held: id}: the response is then delivered later through `respond`.
    reveal(ip, fg, msg, respond) {
        this.sweep();
        if (msg.v !== PROTOCOL) return WRONG_PROTOCOL;
        if (!hasExactKeys(msg, ["v", "request_id", "ng"]) || typeof msg.request_id !== "string" || typeof msg.ng !== "string" ||
            !/^[0-9a-f]{32}$/.test(msg.ng)) return BAD;
        const entry = this.requests.get(msg.request_id);
        if (!entry || entry.fg !== fg || entry.ip !== ip) return reply(404, { error: "unknown_request" });
        if (entry.ng !== null) return reply(409, { error: "already_revealed" });
        if (!checkCommit(entry.commit, fg, msg.ng)) {
            this.#end(entry);
            this.limiter.onDeny(ip);
            return reply(400, { error: "commit_mismatch" });
        }
        entry.ng = msg.ng;
        entry.respond = respond;
        const known = this.store.findBySpki(fg);
        if (known) entry.replaces = { name: known.name, last_seen: known.last_seen };
        this.queue.push(entry);
        return { held: entry.id };
    }

    cancel(fg, msg) {
        this.sweep();
        if (!Object.keys(msg).every((k) => k === "v" || k === "request_id") || typeof msg.request_id !== "string") return BAD;
        const entry = this.requests.get(msg.request_id);
        if (entry && entry.fg === fg) {
            this.limiter.onDone(entry.ip);
            this.#finish(entry, 410, { status: "cancelled" });
        }
        return reply(200, { ok: true });
    }

    // The held connection went away: nothing to answer.
    drop(id) {
        const entry = this.requests.get(id);
        if (!entry) return;
        entry.respond = null;
        this.limiter.onDone(entry.ip);
        this.#end(entry);
    }

    queueLength() {
        this.sweep();
        return this.queue.length;
    }

    pending() {
        this.sweep();
        const head = this.queue[0];
        if (!head) return [];
        return [{
            id: head.id, name: head.name, model: head.model, ip: head.ip, requested_at: new Date(head.requestedAt).toISOString(),
            expires_epoch: Math.floor(head.expiresAt / 1000), replaces: head.replaces
        }];
    }

    #head(id) {
        this.sweep();
        return this.queue[0] && this.queue[0].id === id ? this.queue[0] : null;
    }

    deny(id) {
        const entry = this.#head(id);
        if (!entry) return { ok: false, error: "not_found" };
        this.limiter.onDeny(entry.ip);
        this.#finish(entry, 403, { status: "denied" });
        return { ok: true };
    }

    approve({ id, code, user }) {
        const entry = this.#head(id);
        if (!entry) return { ok: false, error: "not_found" };
        if (!/^[0-9]{6}$/.test(code) || typeof user !== "string" || user.length === 0 || user.length > 200) return { ok: false, error: "bad_request" };

        const expected = sas(this.hostFp, entry.fg, entry.ng, entry.nh);
        if (!crypto.timingSafeEqual(Buffer.from(code), Buffer.from(expected))) {
            entry.attempts++;
            const left = MAX_CODE_TRIES - entry.attempts;
            if (left > 0) return { ok: false, error: "code_mismatch", tries_left: left };
            this.limiter.onDeny(entry.ip);
            this.#finish(entry, 403, { status: "denied" });
            return { ok: false, error: "denied", tries_left: 0 };
        }

        const previous = this.store.findBySpki(entry.fg);
        const wanted = user.toLowerCase();
        if (this.store.list().some((d) => d.id !== (previous && previous.id) && typeof d.user === "string" && d.user.toLowerCase() === wanted)) {
            return { ok: false, error: "user_taken" };
        }
        const device = { id: newId(), name: entry.name, model: entry.model, fp: entry.fg, user, paired_ip: entry.ip, status: "pending_confirm" };
        if (previous) this.store.remove(previous.id);
        try {
            this.store.add(device);
        } catch (e) {
            if (previous) this.store.add(previous);
            throw e;
        }
        this.limiter.onDone(entry.ip);
        this.#finish(entry, 200, { v: PROTOCOL, status: "approved", device_id: device.id, user_label: user });
        return { ok: true, device: device.id, name: device.name, replaced: previous ? previous.id : null };
    }

    // Devices that were approved but never confirmed by the guest within 120 s; returns the removed rows.
    reapUnconfirmed() {
        const at = this.now();
        const stale = this.store.list().filter((d) => d.status === "pending_confirm" && at - Date.parse(d.added) >= UNCONFIRMED_TTL_MS);
        for (const d of stale) this.store.remove(d.id);
        return stale;
    }

    isUnconfirmedExpired(device) {
        return device.status === "pending_confirm" && this.now() - Date.parse(device.added) >= UNCONFIRMED_TTL_MS;
    }
}

module.exports = { Pairing };
