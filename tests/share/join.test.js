"use strict";
const test = require("node:test");
const assert = require("node:assert");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const cpace = require("../../lib/frappe-local/share/cpace.js");
const devices = require("../../lib/frappe-local/share/devices.js");
const { JoinLimiter } = require("../../lib/frappe-local/share/ratelimit.js");
const { Room } = require("../../lib/frappe-local/share/join.js");

const S = 1000;
const HOST_FP = "sha256:" + "ab".repeat(32);
const randomFp = () => "sha256:" + crypto.randomBytes(32).toString("hex");
const SEATS = ["a", "b", "c", "d"].map((n) => ({ seat_id: `seat_${n}`, user: `${n}@example.com`, full_name: `Seat ${n.toUpperCase()}`, roles: ["Sales User"] }));
const EXPORTER = crypto.randomBytes(32);

function makeRoom({ seats = SEATS.length } = {}) {
    const clock = { t: 1_000_000, now: () => clock.t };
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "bj-"));
    const store = devices.load(path.join(dir, "devices.json"), { now: clock.now });
    const limiter = new JoinLimiter({ now: clock.now });
    const room = new Room({
        store, limiter, hostFp: HOST_FP, label: "Host Mac", roomLabel: "Standup", siteLabel: "macdev", seats: SEATS.slice(0, seats), now: clock.now
    });
    return { room, store, limiter, clock };
}

// The guest side of the protocol, in process (the TLS-level version is in gateway.test.js).
class Guest {
    constructor(room, { fp = randomFp(), ip = `10.0.0.${Math.floor(Math.random() * 200) + 1}`, name = "Priya's Mac", model = "Mac14,2" } = {}) {
        Object.assign(this, { room, fp, ip, name, model });
    }

    start({ code, hostFp = HOST_FP, Ya } = {}) {
        const hello = this.room.hello();
        const g = cpace.calculateGenerator(Buffer.from(code ?? this.room.roomCode, "ascii"), Buffer.from(hello.salt, "hex"), Buffer.alloc(0));
        this.ya = crypto.randomBytes(32);
        this.Ya = Ya ?? cpace.scalarMult(this.ya, g);
        this.hostFpRaw = Buffer.from(hostFp.slice(7), "hex");
        this.res = this.room.start(this.ip, this.fp, { v: 3, name: this.name, model: this.model, Ya: this.Ya.toString("hex") });
        if (this.res.status === 200) {
            this.Yb = Buffer.from(this.res.body.Yb, "hex");
            this.id = this.res.body.request_id;
            this.ada = cpace.adGuest(this.name, this.model);
            this.adb = cpace.adHost(hello.room, this.id);
            const isk = cpace.isk(Buffer.alloc(0), cpace.scalarMult(this.ya, this.Yb), this.Ya, this.ada, this.Yb, this.adb);
            this.mac = cpace.macKey(Buffer.alloc(0), isk);
        }
        return this.res;
    }

    ta({ exporter = EXPORTER, fp = this.fp } = {}) {
        return cpace.tag(this.mac, "guest", this.Ya, this.ada, this.Yb, this.adb, this.hostFpRaw, Buffer.from(fp.slice(7), "hex"), exporter);
    }

    finish({ exporter = EXPORTER, ta, fp = this.fp, id = this.id, body } = {}) {
        this.fin = this.room.finish(this.ip, fp, exporter, body ?? { v: 3, request_id: id, Ta: (ta ?? this.ta({ exporter, fp })).toString("hex") });
        return this.fin;
    }

    tbValid(exporter = EXPORTER) {
        const expected = cpace.tag(this.mac, "host", this.Ya, this.ada, this.Yb, this.adb, this.hostFpRaw, Buffer.from(this.fp.slice(7), "hex"), exporter);
        return cpace.verifyTag(expected, Buffer.from(this.fin.body.Tb, "hex"));
    }
}

const joined = (room, opts) => {
    const g = new Guest(room, opts);
    assert.strictEqual(g.start().status, 200);
    assert.strictEqual(g.finish().status, 200);
    return g;
};
const wrong = (room, opts = {}) => {
    const g = new Guest(room, opts);
    g.start({ code: room.roomCode === "000000" ? "111111" : "000000" });
    return g.finish();
};

test("hello carries the documented fields and no secret; a new code changes the salt", () => {
    const { room } = makeRoom();
    const h = room.hello();
    assert.deepStrictEqual(Object.keys(h), ["v", "room", "host", "site", "salt", "locked", "full", "people", "seats"]);
    assert.deepStrictEqual([h.v, h.room, h.host, h.site, h.locked, h.full, h.people, h.seats], [3, "Standup", "Host Mac", "macdev", false, false, 0, 4]);
    assert.match(h.salt, /^[0-9a-f]{32}$/);
    assert.ok(!JSON.stringify(h).includes(room.roomCode) || room.roomCode.length < 6);
    room.rotate();
    assert.notStrictEqual(room.hello().salt, h.salt);
});

test("the code is six zero-padded digits, served only by code(), and absent from status and hello", () => {
    const { room } = makeRoom();
    const seen = new Set();
    for (let i = 0; i < 30; i++) { room.rotate(); seen.add(room.code().code); }
    for (const c of seen) assert.match(c, /^[0-9]{6}$/);
    assert.ok(seen.size > 20);
    const wire = JSON.stringify([room.status(), room.hello(), room.rotate(), room.lock(), room.unlock()]);
    assert.ok(!wire.includes(room.code().code));
});

test("happy path: Tb verifies on the guest, the device is stored active and seatless", () => {
    const { room, store } = makeRoom();
    const g = new Guest(room);
    assert.strictEqual(g.start().status, 200);
    assert.match(g.res.body.request_id, /^j_[0-9a-f]{32}$/);
    assert.match(g.res.body.Yb, /^[0-9a-f]{64}$/);
    assert.strictEqual(g.res.body.v, 3);
    assert.strictEqual(g.finish().status, 200);
    assert.deepStrictEqual([g.fin.body.v, g.fin.body.status], [3, "joined"]);
    assert.match(g.fin.body.device_id, /^d_[0-9a-f]{8}$/);
    assert.strictEqual(g.tbValid(), true);
    const [row] = store.list();
    assert.deepStrictEqual([row.status, row.user, row.seat_id, row.fp, row.name, row.model], ["active", null, null, g.fp, "Priya's Mac", "Mac14,2"]);
    assert.strictEqual(room.status().budget_left, 10);
});

test("wrong code: 403 wrong_code, charged, and that IP cools down for 10 s", () => {
    const { room, clock } = makeRoom();
    const res = wrong(room, { ip: "10.1.1.1" });
    assert.deepStrictEqual([res.status, res.body], [403, { status: "wrong_code" }]);
    assert.strictEqual(room.status().budget_left, 9);
    const again = new Guest(room, { ip: "10.1.1.1" }).start();
    assert.strictEqual(again.status, 429);
    assert.ok(again.body.retry_after >= 1 && again.body.retry_after <= 10);
    clock.t += 11 * S;
    assert.strictEqual(new Guest(room, { ip: "10.1.1.1" }).start().status, 200);
    assert.strictEqual(room.store.list().length, 0);
});

test("ten wrong codes lock the room; unlock never resets the budget; a new code does", () => {
    const { room } = makeRoom();
    for (let i = 0; i < 10; i++) {
        assert.strictEqual(wrong(room, { ip: `10.2.0.${i}` }).status, 403, `attempt ${i + 1}`);
    }
    let s = room.status();
    assert.deepStrictEqual([s.locked, s.lock_reason, s.budget_left], [true, "budget", 0]);
    assert.strictEqual(new Guest(room).start().status, 423);
    assert.deepStrictEqual(room.unlock(), { ok: true, locked: true, lock_reason: "budget" });
    s = room.status();
    assert.deepStrictEqual([s.locked, s.budget_left], [true, 0]);
    assert.strictEqual(new Guest(room).start().status, 423);
    room.rotate();
    s = room.status();
    assert.deepStrictEqual([s.locked, s.lock_reason, s.budget_left], [false, null, 10]);
    joined(room);
});

test("host lock and unlock: start is 423, hello says locked, unlock restores the same budget", () => {
    const { room } = makeRoom();
    wrong(room, { ip: "10.3.0.1" });
    room.lock();
    assert.strictEqual(room.hello().locked, true);
    assert.strictEqual(room.status().lock_reason, "host");
    assert.deepStrictEqual(new Guest(room).start(), { status: 423, body: { status: "locked" } });
    room.unlock();
    assert.strictEqual(room.status().budget_left, 9);
    joined(room);
});

test("J1: a request id is single-use whatever the outcome", () => {
    const { room } = makeRoom();
    const ok = new Guest(room);
    ok.start(); ok.finish();
    assert.deepStrictEqual(ok.finish({ id: ok.id }), { status: 404, body: { status: "unknown_request" } });
    const bad = new Guest(room, { ip: "10.4.0.2" });
    bad.start({ code: room.roomCode === "000000" ? "111111" : "000000" });
    assert.strictEqual(bad.finish().status, 403);
    assert.strictEqual(bad.finish().status, 404, "the failed request is gone too");
    assert.strictEqual(room.status().budget_left, 9, "only the first failure was charged");
});

test("J1/J2: finish after rotate, lock or remove is refused and costs nothing", () => {
    const { room, store } = makeRoom();
    const before = room.status().budget_left;

    const a = new Guest(room, { ip: "10.5.0.1" }); a.start();
    room.rotate();
    assert.strictEqual(a.finish().status, 404);

    const b = new Guest(room, { ip: "10.5.0.2" }); b.start();
    room.lock();
    assert.strictEqual(b.finish().status, 423);
    room.unlock();
    assert.strictEqual(b.finish().status, 404, "unlock does not bring the request back");

    const c = new Guest(room, { ip: "10.5.0.3" }); c.start();
    room.onRemove(c.fp);
    assert.strictEqual(c.finish().status, 403);
    assert.strictEqual(c.fin.body.status, "blocked");
    assert.strictEqual(room.status().budget_left, before);
    assert.strictEqual(store.list().length, 0);
});

test("J2: a room that filled up while a request was in flight refuses the finish, uncharged", () => {
    const { room, store } = makeRoom({ seats: 1 });
    const late = new Guest(room, { ip: "10.6.0.2" }); late.start();
    joined(room, { ip: "10.6.0.1" });
    assert.deepStrictEqual(late.finish(), { status: 409, body: { status: "full" } });
    assert.strictEqual(store.list().length, 1);
    assert.strictEqual(room.status().budget_left, 10);
    assert.strictEqual(room.status().lock_reason, "full");
    assert.strictEqual(room.hello().full, true);
    assert.deepStrictEqual(new Guest(room).start(), { status: 409, body: { status: "full" } });
});

test("relay: a finish on a connection with another client SPKI is 403 wrong_code, charged", () => {
    const { room, store } = makeRoom();
    const g = new Guest(room);
    g.start();
    const res = g.finish({ fp: randomFp() });
    assert.deepStrictEqual([res.status, res.body], [403, { status: "wrong_code" }]);
    assert.strictEqual(room.status().budget_left, 9);
    assert.strictEqual(store.list().length, 0);
});

test("channel binding: a Ta over another exporter, or over another host certificate, fails and is charged", () => {
    const { room } = makeRoom();
    const a = new Guest(room, { ip: "10.7.0.1" }); a.start();
    assert.strictEqual(a.finish({ ta: a.ta({ exporter: crypto.randomBytes(32) }) }).status, 403);
    const b = new Guest(room, { ip: "10.7.0.2" });
    b.start({ hostFp: randomFp() });
    assert.strictEqual(b.finish().status, 403);
    assert.strictEqual(room.status().budget_left, 8);
    assert.strictEqual(room.store.list().length, 0);
});

test("J4: starts near exhaustion cannot add up to more failures than the budget", () => {
    const { room } = makeRoom();
    for (let i = 0; i < 8; i++) wrong(room, { ip: `10.8.0.${i}` });
    const guests = ["10.8.1.1", "10.8.1.2", "10.8.1.3"].map((ip) => new Guest(room, { ip }));
    const codes = guests.map((g) => g.start({ code: room.roomCode === "000000" ? "111111" : "000000" }).status);
    assert.deepStrictEqual(codes, [200, 200, 423]);
    for (const g of guests.slice(0, 2)) g.finish();
    const s = room.status();
    assert.deepStrictEqual([s.budget_left, s.lock_reason], [0, "budget"]);
});

test("J5: three concurrent finishes with two seats store exactly two people", () => {
    const { room, store } = makeRoom({ seats: 2 });
    const gs = ["10.9.0.1", "10.9.0.2", "10.9.0.3"].map((ip) => new Guest(room, { ip }));
    for (const g of gs) assert.strictEqual(g.start().status, 200);
    assert.deepStrictEqual(gs.map((g) => g.finish().status), [200, 200, 409]);
    assert.strictEqual(store.list().length, 2);
});

test("the store itself refuses a person over the cap and a blocked fingerprint", () => {
    const { store } = makeRoom();
    const row = (n) => ({ id: `d_0000000${n}`, name: "n", model: "m", fp: randomFp(), user: null, seat_id: null });
    store.add(row(1), { cap: 1 });
    assert.throws(() => store.add(row(2), { cap: 1 }), (e) => e.code === "full");
    const blocked = row(3);
    store.block(blocked.fp);
    assert.throws(() => store.add(blocked), (e) => e.code === "blocked");
});

test("a blocked SPKI is refused at start, uncharged, and the block outlives the in-flight request", () => {
    const { room, store } = makeRoom();
    const g = joined(room);
    const id = store.list()[0].id;
    store.remove(id);
    room.onRemove(g.fp);
    const again = new Guest(room, { fp: g.fp, ip: "10.10.0.9" });
    assert.deepStrictEqual(again.start(), { status: 403, body: { status: "blocked" } });
    assert.strictEqual(room.status().budget_left, 10);
    room.rotate();
    assert.strictEqual(new Guest(room, { fp: g.fp, ip: "10.10.0.9" }).start().status, 403, "a new code does not lift the block");
});

test("a person already in the room cannot start another join", () => {
    const { room } = makeRoom();
    const g = joined(room);
    assert.deepStrictEqual(new Guest(room, { fp: g.fp, ip: "10.10.1.1" }).start(), { status: 409, body: { status: "already_joined" } });
});

test("a low-order Ya at start is 400, uncharged, identical for any code, and frees the slot", () => {
    const { room } = makeRoom();
    const lowOrder = [Buffer.alloc(32), Buffer.from("01" + "00".repeat(31), "hex"), Buffer.from("ecff" + "ff".repeat(29) + "7f", "hex")];
    const bodies = [];
    for (const Ya of lowOrder) {
        const g = new Guest(room, { ip: "10.11.0.1" });
        const res = g.start({ Ya });
        assert.strictEqual(res.status, 400);
        bodies.push(JSON.stringify(res));
        room.rotate();
    }
    assert.strictEqual(new Set(bodies).size, 1, "the answer does not depend on the code");
    assert.strictEqual(room.status().budget_left, 10);
    assert.strictEqual(room.limiter.count(), 0);
    assert.strictEqual(new Guest(room, { ip: "10.11.0.1" }).start().status, 200);
});

test("J6: an unfinished start is charged on expiry and raises join_trouble", () => {
    const { room, clock } = makeRoom();
    const g = new Guest(room, { ip: "10.12.0.1" }); g.start();
    assert.strictEqual(room.status().join_trouble, false);
    clock.t += 29 * S;
    assert.strictEqual(room.status().budget_left, 10);
    clock.t += 2 * S;
    const s = room.status();
    assert.deepStrictEqual([s.budget_left, s.join_trouble], [9, true]);
    assert.strictEqual(room.status().budget_left, 9, "charged once");
    assert.strictEqual(g.finish().status, 404);
    assert.strictEqual(room.status().budget_left, 9);
    clock.t += 301 * S;
    assert.strictEqual(room.status().join_trouble, false, "the signal fades");
});

test("start limits: one in flight per IP, three in total, a retry_after that is real", () => {
    const { room, clock } = makeRoom();
    assert.strictEqual(new Guest(room, { ip: "10.13.0.1" }).start().status, 200);
    clock.t += 10 * S;
    const second = new Guest(room, { ip: "10.13.0.1" }).start();
    assert.strictEqual(second.status, 429);
    assert.strictEqual(second.body.status, "rate_limited");
    assert.ok(second.body.retry_after >= 19 && second.body.retry_after <= 21, String(second.body.retry_after));
    assert.strictEqual(new Guest(room, { ip: "10.13.0.2" }).start().status, 200);
    assert.strictEqual(new Guest(room, { ip: "10.13.0.3" }).start().status, 200);
    assert.strictEqual(new Guest(room, { ip: "10.13.0.4" }).start().status, 429);
});

test("sustained 429s raise join_trouble", () => {
    const { room } = makeRoom();
    new Guest(room, { ip: "10.14.0.1" }).start();
    for (let i = 0; i < 4; i++) new Guest(room, { ip: "10.14.0.1" }).start();
    assert.strictEqual(room.status().join_trouble, false);
    new Guest(room, { ip: "10.14.0.1" }).start();
    assert.strictEqual(room.status().join_trouble, true);
});

test("start schema: strict keys, v:3 only, hex shares, bounded printable text", () => {
    const { room } = makeRoom();
    const Ya = "00".repeat(31) + "09";
    const ok = { v: 3, name: "n", model: "m", Ya };
    const refused = [
        [{ ...ok, extra: 1 }, 400], [{ ...ok, v: 2 }, 426], [{ ...ok, v: 4 }, 426], [{ name: "n", model: "m", Ya }, 400], [{ ...ok, name: "" }, 400],
        [{ ...ok, name: "a".repeat(41) }, 400], [{ ...ok, model: "m".repeat(33) }, 400], [{ ...ok, Ya: Ya.slice(2) }, 400], [{ ...ok, Ya: Ya.toUpperCase().replace("00", "AA") }, 400],
        [{ ...ok, name: "​‮" }, 400], [{ ...ok, name: "bad\ud800" }, 400], [{ ...ok, name: 5 }, 400], [{ ...ok, v: "3" }, 400]
    ];
    for (const [body, status] of refused) assert.strictEqual(room.start("10.15.0.1", randomFp(), body).status, status, JSON.stringify(body));
    assert.strictEqual(room.limiter.count(), 0);
});

test("J18/J11: the roster shows the name without control, bidi or zero-width characters, while ADa binds the exact bytes", () => {
    const { room, store } = makeRoom();
    const g = new Guest(room, { name: "Pri‮ya​\u0007" });
    assert.strictEqual(g.start().status, 200);
    assert.strictEqual(g.finish().status, 200);
    assert.strictEqual(g.tbValid(), true, "the tags were computed over the raw name");
    assert.strictEqual(store.list()[0].name, "Priya");
});

test("seats: take, switch (wipe the old user), a taken seat is 409, an unknown id is 404, a failed wipe moves nothing", async () => {
    const { room, store } = makeRoom();
    const g1 = joined(room, { ip: "10.16.0.1" }), g2 = joined(room, { ip: "10.16.0.2" });
    const [d1, d2] = store.list();
    const wiped = [];
    const wipe = async (user) => { wiped.push(user); };
    assert.deepStrictEqual(await room.moveToSeat(d1, "seat_a", wipe), { ok: true, seat_id: "seat_a", full_name: "Seat A" });
    assert.deepStrictEqual(wiped, [], "nothing to wipe on a first seat");
    assert.deepStrictEqual((await room.moveToSeat(d2, "seat_a", wipe)).error, "seat_taken");
    assert.deepStrictEqual((await room.moveToSeat(d2, "seat_zzz", wipe)).error, "no_such_seat");
    assert.deepStrictEqual((await room.moveToSeat(d2, "SEAT_B", wipe)).error, "no_such_seat", "ids match exactly");
    assert.strictEqual((await room.moveToSeat(d1, "seat_b", wipe)).ok, true);
    assert.deepStrictEqual(wiped, ["a@example.com"]);
    assert.strictEqual((await room.moveToSeat(d2, "seat_a", wipe)).ok, true, "the freed seat is takeable");
    assert.deepStrictEqual(wiped, ["a@example.com"]);

    const failing = async () => { throw new Error("boom"); };
    const before = store.list().find((d) => d.id === d1.id);
    const out = await room.moveToSeat(before, "seat_c", failing);
    assert.deepStrictEqual([out.ok, out.status], [false, 503]);
    assert.strictEqual(store.list().find((d) => d.id === d1.id).seat_id, "seat_b");
    assert.ok(g1 && g2);
});

test("J17: the seat list carries ids, names, roles and who holds a seat, never an email", async () => {
    const { room, store } = makeRoom();
    joined(room);
    await room.moveToSeat(store.list()[0], "seat_b", async () => {});
    const list = room.seatList();
    assert.strictEqual(list.length, 4);
    assert.deepStrictEqual(list[1], { seat_id: "seat_b", full_name: "Seat B", roles: ["Sales User"], taken_by: "Priya's Mac" });
    assert.strictEqual(list[0].taken_by, null);
    assert.ok(!JSON.stringify(list).includes("@"));
    assert.ok(!JSON.stringify(room.roster(store.list()[0], 123, () => true)).includes("@"));
});

test("the roster lists people with name, model, seat and online, and who you are", async () => {
    const { room, store } = makeRoom();
    joined(room, { ip: "10.17.0.1", name: "Asha" }); joined(room, { ip: "10.17.0.2", name: "Ben" });
    const [a, b] = store.list();
    await room.moveToSeat(a, "seat_c", async () => {});
    const r = room.roster(b, 999, (d) => d.id === a.id);
    assert.deepStrictEqual(r, {
        room: "Standup", host: "Host Mac", site: "macdev", deadline_epoch: 999, you: b.id,
        people: [{ name: "Asha", model: "Mac14,2", seat: "Seat C", online: true }, { name: "Ben", model: "Mac14,2", seat: null, online: false }]
    });
});

test("seatless devices expire after 120 s; seated ones do not", async () => {
    const { room, store, clock } = makeRoom();
    joined(room, { ip: "10.18.0.1" }); joined(room, { ip: "10.18.0.2" });
    await room.moveToSeat(store.list()[0], "seat_a", async () => {});
    clock.t += 119 * S;
    assert.strictEqual(store.reapSeatless().length, 0);
    clock.t += 2 * S;
    const gone = store.reapSeatless();
    assert.strictEqual(gone.length, 1);
    assert.strictEqual(store.list().length, 1);
    assert.strictEqual(store.list()[0].seat_id, "seat_a");
});

test("J5: the cap is re-checked inside the store lock, even when the pre-check saw room", () => {
    const { room, store } = makeRoom({ seats: 1 });
    const late = new Guest(room, { ip: "10.19.0.2" }); late.start();
    joined(room, { ip: "10.19.0.1" });
    const realList = store.list.bind(store);
    store.list = () => realList().slice(1);
    let res;
    try {
        res = late.finish();
    } finally {
        store.list = realList;
    }
    assert.deepStrictEqual(res, { status: 409, body: { status: "full" } });
    assert.strictEqual(store.list().length, 1);
    assert.strictEqual(room.status().budget_left, 10, "not charged");
});
