"use strict";

const JOIN_TTL_MS = 30_000;
const JOIN_COOLDOWN_MS = 10_000;
const MAX_IN_FLIGHT_TOTAL = 3;   // and one per IP
const TROUBLE_WINDOW_MS = 300_000;
const LIMITED_TROUBLE_THRESHOLD = 5;

// Slots for join requests between `start` and `finish` (J6), keyed by request id so the
// room can charge each expiry to the failure budget. An expired slot's cooldown runs
// from the TTL moment, not from whenever it was noticed.
class JoinLimiter {
    constructor({ now = Date.now } = {}) {
        this.now = now;
        this.inFlight = new Map();      // request id -> {ip, expiresAt}, insertion order
        this.cooldownUntil = new Map(); // ip -> time
        this.expiries = [];             // times of unfinished starts
        this.limited = [];              // times of 429s answered to a start
    }

    #ipHolds(ip) {
        for (const slot of this.inFlight.values()) if (slot.ip === ip) return true;
        return false;
    }

    // Callers run expire() first, so a stale slot never blocks a fresh start.
    admit(ip, id) {
        const t = this.now();
        for (const [other, until] of this.cooldownUntil) if (until <= t) this.cooldownUntil.delete(other);
        if (this.cooldownUntil.has(ip)) return { ok: false, reason: "cooldown" };
        if (this.#ipHolds(ip)) return { ok: false, reason: "ip_in_flight" };
        if (this.inFlight.size >= MAX_IN_FLIGHT_TOTAL) return { ok: false, reason: "total_in_flight" };
        this.inFlight.set(id, { ip, expiresAt: t + JOIN_TTL_MS });
        return { ok: true };
    }

    release(id) {
        this.inFlight.delete(id);
    }

    // Requests whose TTL passed, removed here; each starts its IP's cooldown and counts as join trouble.
    expire() {
        const t = this.now();
        const gone = [];
        for (const [id, slot] of this.inFlight) {
            if (slot.expiresAt > t) continue;
            this.inFlight.delete(id);
            this.cooldownUntil.set(slot.ip, slot.expiresAt + JOIN_COOLDOWN_MS);
            this.expiries.push(slot.expiresAt);
            gone.push({ id, ip: slot.ip });
        }
        return gone;
    }

    cooldown(ip) {
        this.cooldownUntil.set(ip, this.now() + JOIN_COOLDOWN_MS);
    }

    count() {
        return this.inFlight.size;
    }

    // Seconds until `ip` may try again, after admit() refused it. At least 1.
    retryAfter(ip) {
        const t = this.now();
        let until = this.cooldownUntil.get(ip);
        if (until === undefined) {
            const own = [...this.inFlight.values()].filter((slot) => slot.ip === ip).map((slot) => slot.expiresAt);
            until = own.length ? Math.min(...own) : Math.min(...[...this.inFlight.values()].map((slot) => slot.expiresAt));
        }
        return Math.max(1, Math.ceil((until - t) / 1000));
    }

    noteLimited() {
        this.limited.push(this.now());
    }

    // An unfinished start, or sustained 429s, within the last five minutes.
    trouble() {
        const cutoff = this.now() - TROUBLE_WINDOW_MS;
        this.expiries = this.expiries.filter((at) => at > cutoff);
        this.limited = this.limited.filter((at) => at > cutoff);
        return this.expiries.length > 0 || this.limited.length >= LIMITED_TROUBLE_THRESHOLD;
    }
}

class ConnLimiter {
    constructor({ maxTotal = 16, maxPerIp = 4 } = {}) {
        this.maxTotal = maxTotal;
        this.maxPerIp = maxPerIp;
        this.perIp = new Map();
        this.count = 0;
    }

    acquire(ip) {
        const n = this.perIp.get(ip) || 0;
        if (n >= this.maxPerIp) return { ok: false, reason: "ip_conns" };
        if (this.count >= this.maxTotal) return { ok: false, reason: "total_conns" };
        this.perIp.set(ip, n + 1);
        this.count++;
        return { ok: true };
    }

    release(ip) {
        const n = this.perIp.get(ip) || 0;
        if (n === 0) return;
        if (n === 1) this.perIp.delete(ip);
        else this.perIp.set(ip, n - 1);
        this.count--;
    }

    total() {
        return this.count;
    }
}

class RateBucket {
    constructor({ now = Date.now, limit, windowMs = 60_000 }) {
        this.now = now;
        this.limit = limit;
        this.windowMs = windowMs;
        this.hits = new Map();
    }

    take(key) {
        const t = this.now();
        const recent = (this.hits.get(key) || []).filter((at) => t - at < this.windowMs);
        if (recent.length >= this.limit) {
            this.hits.set(key, recent);
            return false;
        }
        recent.push(t);
        this.hits.set(key, recent);
        return true;
    }

    forget(key) {
        this.hits.delete(key);
    }

    // Seconds until `key` has a free slot, after take() refused it. At least 1.
    retryAfter(key) {
        const recent = (this.hits.get(key) || []).filter((at) => this.now() - at < this.windowMs);
        return recent.length ? Math.max(1, Math.ceil((recent[0] + this.windowMs - this.now()) / 1000)) : 1;
    }
}

module.exports = { JoinLimiter, ConnLimiter, RateBucket, JOIN_TTL_MS, JOIN_COOLDOWN_MS };
