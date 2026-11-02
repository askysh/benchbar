"use strict";
const test = require("node:test");
const assert = require("node:assert");
const { JoinLimiter, ConnLimiter, RateBucket } = require("../../lib/frappe-local/share/ratelimit.js");

function clock(start = 1_000_000) {
    const c = { t: start, now: () => c.t };
    return c;
}
const S = 1000;

test("JoinLimiter: one in flight per IP and three in total", () => {
    const c = clock(); const l = new JoinLimiter({ now: c.now });
    assert.deepStrictEqual(l.admit("10.0.0.1", "a"), { ok: true });
    assert.deepStrictEqual(l.admit("10.0.0.1", "b"), { ok: false, reason: "ip_in_flight" });
    for (const [ip, id] of [["10.0.0.2", "c"], ["10.0.0.3", "d"]]) assert.strictEqual(l.admit(ip, id).ok, true);
    assert.deepStrictEqual(l.admit("10.0.0.4", "e"), { ok: false, reason: "total_in_flight" });
    l.release("c");
    assert.strictEqual(l.admit("10.0.0.4", "e").ok, true);
    assert.strictEqual(l.count(), 3);
});

test("JoinLimiter: a wrong code cools the IP down for 10 s", () => {
    const c = clock(); const l = new JoinLimiter({ now: c.now });
    l.admit("10.0.0.1", "a"); l.release("a"); l.cooldown("10.0.0.1");
    c.t += 9 * S;
    assert.deepStrictEqual(l.admit("10.0.0.1", "b"), { ok: false, reason: "cooldown" });
    assert.strictEqual(l.retryAfter("10.0.0.1"), 1);
    c.t += 2 * S;
    assert.strictEqual(l.admit("10.0.0.1", "b").ok, true);
});

test("JoinLimiter: a start expires at 30 s, is reported once, and the cooldown runs from the TTL", () => {
    const c = clock(); const l = new JoinLimiter({ now: c.now });
    l.admit("10.0.0.1", "a");
    c.t += 29 * S;
    assert.deepStrictEqual(l.expire(), []);
    assert.strictEqual(l.admit("10.0.0.1", "b").reason, "ip_in_flight");
    c.t += 1 * S;
    assert.deepStrictEqual(l.expire(), [{ id: "a", ip: "10.0.0.1" }]);
    assert.deepStrictEqual(l.expire(), []);
    c.t += 9 * S;
    assert.strictEqual(l.admit("10.0.0.1", "b").reason, "cooldown");
    c.t += 2 * S;
    assert.strictEqual(l.admit("10.0.0.1", "b").ok, true);
});

test("JoinLimiter: an expiry noticed late still counts the cooldown from the TTL, and frees the total slot", () => {
    const c = clock(); const l = new JoinLimiter({ now: c.now });
    for (const [ip, id] of [["10.0.0.1", "a"], ["10.0.0.2", "b"], ["10.0.0.3", "d"]]) l.admit(ip, id);
    c.t += 35 * S;
    l.expire();
    assert.strictEqual(l.admit("10.0.0.4", "e").ok, true);
    assert.strictEqual(l.admit("10.0.0.1", "f").reason, "cooldown");
    c.t += 6 * S;
    assert.strictEqual(l.admit("10.0.0.1", "f").ok, true);
});

test("JoinLimiter: retryAfter reports the cooldown left, the IP's own TTL left, or the soonest slot to free", () => {
    const c = clock(); const l = new JoinLimiter({ now: c.now });
    l.admit("10.0.0.1", "a");
    c.t += 10 * S;
    l.admit("10.0.0.2", "b"); l.admit("10.0.0.3", "d");
    assert.strictEqual(l.admit("10.0.0.1", "x").reason, "ip_in_flight");
    assert.strictEqual(l.retryAfter("10.0.0.1"), 20);
    assert.strictEqual(l.admit("10.0.0.4", "y").reason, "total_in_flight");
    assert.strictEqual(l.retryAfter("10.0.0.4"), 20);
    l.release("b"); l.cooldown("10.0.0.2");
    assert.strictEqual(l.retryAfter("10.0.0.2"), 10);
});

test("JoinLimiter: trouble is an expiry, or five 429s, within five minutes", () => {
    const c = clock(); const l = new JoinLimiter({ now: c.now });
    assert.strictEqual(l.trouble(), false);
    for (let i = 0; i < 4; i++) l.noteLimited();
    assert.strictEqual(l.trouble(), false);
    l.noteLimited();
    assert.strictEqual(l.trouble(), true);
    c.t += 301 * S;
    assert.strictEqual(l.trouble(), false);
    l.admit("10.0.0.1", "a");
    c.t += 31 * S;
    l.expire();
    assert.strictEqual(l.trouble(), true);
    c.t += 301 * S;
    assert.strictEqual(l.trouble(), false);
});

test("ConnLimiter: the 5th connection from one IP and the 17th unpaired are refused", () => {
    const l = new ConnLimiter();
    for (let i = 0; i < 4; i++) assert.strictEqual(l.acquire("10.0.0.1").ok, true);
    assert.deepStrictEqual(l.acquire("10.0.0.1"), { ok: false, reason: "ip_conns" });
    l.release("10.0.0.1");
    assert.strictEqual(l.acquire("10.0.0.1").ok, true);
    const l2 = new ConnLimiter();
    for (let i = 0; i < 16; i++) assert.strictEqual(l2.acquire(`10.0.${i >> 2}.${i}`).ok, true, String(i));
    assert.deepStrictEqual(l2.acquire("10.9.9.9"), { ok: false, reason: "total_conns" });
    l2.release("10.0.0.0");
    assert.strictEqual(l2.acquire("10.9.9.9").ok, true);
});

test("ConnLimiter: release never goes negative and forgets idle IPs", () => {
    const l = new ConnLimiter();
    l.release("10.0.0.1");
    assert.strictEqual(l.total(), 0);
    l.acquire("10.0.0.1"); l.release("10.0.0.1"); l.release("10.0.0.1");
    assert.strictEqual(l.total(), 0);
});

test("RateBucket: 6 per minute per key, a sliding window, keys independent", () => {
    const c = clock(); const b = new RateBucket({ now: c.now, limit: 6, windowMs: 60 * S });
    for (let i = 0; i < 6; i++) assert.strictEqual(b.take("dev1"), true, String(i));
    assert.strictEqual(b.take("dev1"), false);
    assert.strictEqual(b.take("dev2"), true);
    c.t += 59 * S;
    assert.strictEqual(b.take("dev1"), false);
    c.t += 2 * S;
    assert.strictEqual(b.take("dev1"), true);
});

test("RateBucket.retryAfter is the time until the oldest hit leaves the window", () => {
    const c = clock(); const b = new RateBucket({ now: c.now, limit: 2, windowMs: 60 * S });
    b.take("k"); c.t += 20 * S; b.take("k");
    assert.strictEqual(b.take("k"), false);
    assert.strictEqual(b.retryAfter("k"), 40);
    assert.strictEqual(b.retryAfter("other"), 1);
});
