"use strict";
const test = require("node:test");
const assert = require("node:assert");
const { PairLimiter, ConnLimiter, RateBucket } = require("../../lib/frappe-local/share/ratelimit.js");

function clock(start = 1_000_000) {
    const c = { t: start, now: () => c.t };
    return c;
}
const S = 1000;

test("a second pending request from one IP is refused", () => {
    const c = clock(); const l = new PairLimiter({ now: c.now });
    assert.deepStrictEqual(l.admit("10.0.0.1"), { ok: true });
    assert.deepStrictEqual(l.admit("10.0.0.1"), { ok: false, reason: "ip_pending" });
});

test("the fourth pending request in total is refused", () => {
    const c = clock(); const l = new PairLimiter({ now: c.now });
    for (const ip of ["10.0.0.1", "10.0.0.2", "10.0.0.3"]) assert.strictEqual(l.admit(ip).ok, true);
    assert.deepStrictEqual(l.admit("10.0.0.4"), { ok: false, reason: "total_pending" });
    l.onDone("10.0.0.2");
    assert.strictEqual(l.admit("10.0.0.4").ok, true);
});

test("cooldown after a deny holds for 59 s and clears at 61 s", () => {
    const c = clock(); const l = new PairLimiter({ now: c.now });
    l.admit("10.0.0.1"); l.onDeny("10.0.0.1");
    c.t += 59 * S;
    assert.deepStrictEqual(l.admit("10.0.0.1"), { ok: false, reason: "cooldown" });
    c.t += 2 * S;
    assert.strictEqual(l.admit("10.0.0.1").ok, true);
});

test("cooldown after an explicit expiry holds for 59 s and clears at 61 s", () => {
    const c = clock(); const l = new PairLimiter({ now: c.now });
    l.admit("10.0.0.1"); l.onExpire("10.0.0.1");
    c.t += 59 * S;
    assert.strictEqual(l.admit("10.0.0.1").reason, "cooldown");
    c.t += 2 * S;
    assert.strictEqual(l.admit("10.0.0.1").ok, true);
});

test("the TTL is 300 s and an expiry starts the cooldown from the moment of expiry", () => {
    const c = clock(); const l = new PairLimiter({ now: c.now });
    l.admit("10.0.0.1");
    c.t += 299 * S;
    assert.strictEqual(l.admit("10.0.0.1").reason, "ip_pending");
    c.t += 1 * S;
    assert.deepStrictEqual(l.expired(), ["10.0.0.1"]);
    c.t += 59 * S;
    assert.strictEqual(l.admit("10.0.0.1").reason, "cooldown");
    c.t += 2 * S;
    assert.strictEqual(l.admit("10.0.0.1").ok, true);
});

test("an expiry noticed late still counts the cooldown from the TTL, not from the notice", () => {
    const c = clock(); const l = new PairLimiter({ now: c.now });
    l.admit("10.0.0.1");
    c.t += 330 * S;
    assert.strictEqual(l.admit("10.0.0.1").reason, "cooldown");
    c.t += 31 * S;
    assert.strictEqual(l.admit("10.0.0.1").ok, true);
});

test("an expired request frees its slot in the total", () => {
    const c = clock(); const l = new PairLimiter({ now: c.now });
    for (const ip of ["10.0.0.1", "10.0.0.2", "10.0.0.3"]) l.admit(ip);
    c.t += 300 * S;
    assert.strictEqual(l.admit("10.0.0.4").ok, true);
    assert.strictEqual(l.size(), 1);
});

test("only the head of the FIFO queue is shown to the host", () => {
    const c = clock(); const l = new PairLimiter({ now: c.now });
    l.admit("10.0.0.1"); c.t += S; l.admit("10.0.0.2"); c.t += S; l.admit("10.0.0.3");
    assert.strictEqual(l.head(), "10.0.0.1");
    assert.strictEqual(l.isHead("10.0.0.2"), false);
    l.onDeny("10.0.0.1");
    assert.strictEqual(l.head(), "10.0.0.2");
    l.onDone("10.0.0.2");
    assert.strictEqual(l.head(), "10.0.0.3");
    l.onDone("10.0.0.3");
    assert.strictEqual(l.head(), null);
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
