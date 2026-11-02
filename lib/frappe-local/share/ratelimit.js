"use strict";

const PAIR_TTL_MS = 300_000;
const PAIR_COOLDOWN_MS = 60_000;
const MAX_PENDING_TOTAL = 3;

class PairLimiter {
    constructor({ now = Date.now } = {}) {
        this.now = now;
        this.pending = new Map();   // ip -> expiresAt, insertion order is the FIFO queue
        this.cooldownUntil = new Map();
    }

    // A request that outlived its TTL is dropped here, and its cooldown runs
    // from the TTL moment, not from whenever we noticed.
    #sweep() {
        const expired = [];
        const t = this.now();
        for (const [ip, expiresAt] of this.pending) {
            if (expiresAt <= t) {
                this.pending.delete(ip);
                this.cooldownUntil.set(ip, expiresAt + PAIR_COOLDOWN_MS);
                expired.push(ip);
            }
        }
        for (const [ip, until] of this.cooldownUntil) if (until <= t) this.cooldownUntil.delete(ip);
        return expired;
    }

    admit(ip) {
        this.#sweep();
        if (this.cooldownUntil.has(ip)) return { ok: false, reason: "cooldown" };
        if (this.pending.has(ip)) return { ok: false, reason: "ip_pending" };
        if (this.pending.size >= MAX_PENDING_TOTAL) return { ok: false, reason: "total_pending" };
        this.pending.set(ip, this.now() + PAIR_TTL_MS);
        return { ok: true };
    }

    onDeny(ip) {
        this.pending.delete(ip);
        this.cooldownUntil.set(ip, this.now() + PAIR_COOLDOWN_MS);
    }

    onExpire(ip) {
        this.onDeny(ip);
    }

    onDone(ip) {
        this.pending.delete(ip);
    }

    // IPs whose request just timed out, so the caller can tell the guest.
    expired() {
        return this.#sweep();
    }

    // Seconds until `ip` may try again, after admit() refused it: the cooldown left, else that
    // IP's own request TTL, else (queue full) the soonest slot to free. At least 1.
    retryAfter(ip) {
        this.#sweep();
        const t = this.now();
        const until = this.cooldownUntil.get(ip) ?? this.pending.get(ip) ?? Math.min(...this.pending.values());
        return Math.max(1, Math.ceil((until - t) / 1000));
    }

    head() {
        this.#sweep();
        for (const ip of this.pending.keys()) return ip;
        return null;
    }

    isHead(ip) {
        return this.head() === ip;
    }

    size() {
        this.#sweep();
        return this.pending.size;
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
}

module.exports = { PairLimiter, ConnLimiter, RateBucket, PAIR_TTL_MS, PAIR_COOLDOWN_MS };
