"use strict";
const crypto = require("crypto");
const cpace = require("./cpace.js");
const { newId } = require("./devices.js");

const PROTOCOL = 3;
const FAILURE_BUDGET = 10;
const NAME_MAX = 40;
const MODEL_MAX = 32;
const SALT_BYTES = 16;
const NO_SID = Buffer.alloc(0);
const UNSAFE_CHARS = /[\u{0}-\u{1f}\u{7f}-\u{9f}\u{2028}\u{2029}\u{200b}-\u{200f}\u{202a}-\u{202e}\u{2060}-\u{2064}\u{2066}-\u{2069}\u{feff}]/gu;
const HEX64 = /^[0-9a-f]{64}$/;
const HEX128 = /^[0-9a-f]{128}$/;
const REQUEST_ID = /^j_[0-9a-f]{32}$/;

const hasExactKeys = (o, keys) => Object.keys(o).length === keys.length && keys.every((k) => Object.hasOwn(o, k));
const reply = (status, body) => ({ status, body });
const BAD = reply(400, { error: "bad_request" });
const WRONG_PROTOCOL = reply(426, { error: "protocol", need: PROTOCOL });
const LOCKED = reply(423, { status: "locked" });
const FULL = reply(409, { status: "full" });
const BLOCKED = reply(403, { status: "blocked" });
const WRONG_CODE = reply(403, { status: "wrong_code" });

const shown = (text) => text.replace(UNSAFE_CHARS, "").trim();
const fpRaw = (fp) => Buffer.from(fp.slice("sha256:".length), "hex");

// The room: one code, one salt, one generator, a failure budget, and the join requests
// between `start` and `finish`. Everything here is in memory except the people, who live
// in the device store. The code leaves this object only through code().
class Room {
    constructor({ store, limiter, hostFp, label, roomLabel, siteLabel, seats, now = Date.now }) {
        Object.assign(this, { store, limiter, label, roomLabel, siteLabel, seats, now });
        this.hostFpRaw = fpRaw(hostFp);
        this.requests = new Map();
        this.hostLocked = false;
        this.epoch = 0;
        this.#drawCode();
    }

    // The generator is computed once per code, so no attacker-chosen input reaches the map (R3-3).
    #drawCode() {
        this.epoch++;
        this.roomCode = String(crypto.randomInt(0, 1_000_000)).padStart(6, "0");
        this.salt = crypto.randomBytes(SALT_BYTES);
        this.generator = cpace.calculateGenerator(Buffer.from(this.roomCode, "ascii"), this.salt, NO_SID);
        this.failures = 0;
        this.budgetLocked = false;
        this.#dropAll();
    }

    #drop(entry) {
        this.requests.delete(entry.id);
        this.limiter.release(entry.id);
    }

    #dropAll() {
        for (const entry of [...this.requests.values()]) this.#drop(entry);
    }

    #charge() {
        this.failures++;
        if (this.failures >= FAILURE_BUDGET) {
            this.budgetLocked = true;
            this.#dropAll();
        }
    }

    // An unfinished start is a failed attempt (J6).
    sweep() {
        for (const { id } of this.limiter.expire()) {
            if (this.requests.delete(id)) this.#charge();
        }
    }

    #people() {
        return this.store.list().length;
    }

    #full() {
        return this.#people() >= this.seats.length;
    }

    #locked() {
        return this.hostLocked || this.budgetLocked;
    }

    budgetLeft() {
        return Math.max(0, FAILURE_BUDGET - this.failures);
    }

    code() {
        return { ok: true, code: this.roomCode };
    }

    hello() {
        this.sweep();
        return {
            v: PROTOCOL, room: this.roomLabel, host: this.label, site: this.siteLabel, salt: this.salt.toString("hex"),
            locked: this.#locked(), full: this.#full(), people: this.#people(), seats: this.seats.length
        };
    }

    status() {
        this.sweep();
        const full = this.#full();
        const reason = this.budgetLocked ? "budget" : this.hostLocked ? "host" : full ? "full" : null;
        return {
            locked: reason !== null, lock_reason: reason, budget_left: this.budgetLeft(), seats: this.seats.length, people: this.#people(),
            join_trouble: this.limiter.trouble()
        };
    }

    rotate() {
        this.#drawCode();
        return { ok: true, budget_left: this.budgetLeft() };
    }

    lock() {
        this.hostLocked = true;
        this.#dropAll();
        return { ok: true };
    }

    // Never resets the budget (J3): a budget lock stays until a new code.
    unlock() {
        this.hostLocked = false;
        return { ok: true, locked: this.budgetLocked, lock_reason: this.budgetLocked ? "budget" : null };
    }

    onRemove(fp) {
        this.store.block(fp);
        for (const entry of [...this.requests.values()]) if (entry.fp === fp) this.#drop(entry);
    }

    #validStart(body) {
        if (!hasExactKeys(body, ["v", "name", "model", "Ya"])) return null;
        const { name, model, Ya } = body;
        const text = (v, max) => typeof v === "string" && v.length > 0 && v.length <= max && v.isWellFormed();
        if (!text(name, NAME_MAX) || !text(model, MODEL_MAX) || typeof Ya !== "string" || !HEX64.test(Ya)) return null;
        const [displayName, displayModel] = [shown(name), shown(model)];
        return displayName && displayModel ? { name, model, displayName, displayModel, Ya: Buffer.from(Ya, "hex") } : null;
    }

    start(ip, fp, body) {
        this.sweep();
        if (Number.isInteger(body.v) && body.v !== PROTOCOL) return WRONG_PROTOCOL;
        const parsed = body.v === PROTOCOL ? this.#validStart(body) : null;
        if (!parsed) return BAD;
        if (this.store.isBlocked(fp)) return BLOCKED;
        if (this.store.findBySpki(fp)) return reply(409, { status: "already_joined" });
        if (this.#locked()) return LOCKED;
        if (this.#full()) return FULL;
        if (this.budgetLeft() - this.requests.size <= 0) return LOCKED;

        const id = "j_" + crypto.randomBytes(16).toString("hex");
        const slot = this.limiter.admit(ip, id);
        if (!slot.ok) {
            this.limiter.noteLimited();
            return reply(429, { status: "rate_limited", retry_after: this.limiter.retryAfter(ip) });
        }
        const yb = crypto.randomBytes(32);
        let Yb, K;
        try {
            Yb = cpace.scalarMult(yb, this.generator);
            K = cpace.scalarMult(yb, parsed.Ya);
        } catch {
            this.limiter.release(id);
            return BAD;
        }
        const ada = cpace.adGuest(parsed.name, parsed.model);
        const adb = cpace.adHost(this.roomLabel, id);
        const isk = cpace.isk(NO_SID, K, parsed.Ya, ada, Yb, adb);
        this.requests.set(id, {
            id, ip, fp, epoch: this.epoch, name: parsed.displayName, model: parsed.displayModel,
            Ya: parsed.Ya, Yb, ada, adb, macKey: cpace.macKey(NO_SID, isk)
        });
        return reply(200, { v: PROTOCOL, request_id: id, Yb: Yb.toString("hex") });
    }

    // `exporter` is the TLS exporter of the connection this request arrived on (J16).
    finish(ip, fp, exporter, body) {
        this.sweep();
        if (Number.isInteger(body.v) && body.v !== PROTOCOL) return WRONG_PROTOCOL;
        const id = body.request_id;
        if (!hasExactKeys(body, ["v", "request_id", "Ta"]) || body.v !== PROTOCOL || !REQUEST_ID.test(id) || typeof body.Ta !== "string" || !HEX128.test(body.Ta)) return BAD;
        const entry = this.requests.get(id);
        // J2: refusals that cost the guest nothing. The request is spent either way (J1).
        const refusal = this.store.isBlocked(fp) ? BLOCKED : this.#locked() ? LOCKED : this.#full() ? FULL : null;
        if (refusal) {
            if (entry) this.#drop(entry);
            return refusal;
        }
        if (!entry) return reply(404, { status: "unknown_request" });
        this.#drop(entry);
        if (entry.epoch !== this.epoch) return reply(410, { status: "expired" });

        if (entry.fp !== fp) return this.#wrongCode(ip);
        const guestFp = fpRaw(fp);
        const expected = cpace.tag(entry.macKey, "guest", entry.Ya, entry.ada, entry.Yb, entry.adb, this.hostFpRaw, guestFp, exporter);
        if (!cpace.verifyTag(expected, Buffer.from(body.Ta, "hex"))) return this.#wrongCode(ip);

        let device;
        try {
            device = this.store.add({ id: newId(), name: entry.name, model: entry.model, fp, user: null, seat_id: null, paired_ip: ip }, { cap: this.seats.length });
        } catch (e) {
            if (e.code === "full") return FULL;
            if (e.code === "blocked") return BLOCKED;
            if (e.code === "duplicate") return reply(409, { status: "already_joined" });
            throw e;
        }
        const Tb = cpace.tag(entry.macKey, "host", entry.Ya, entry.ada, entry.Yb, entry.adb, this.hostFpRaw, guestFp, exporter);
        return reply(200, { v: PROTOCOL, status: "joined", device_id: device.id, Tb: Tb.toString("hex") });
    }

    #wrongCode(ip) {
        this.#charge();
        this.limiter.cooldown(ip);
        return WRONG_CODE;
    }

    seatList() {
        const holders = new Map(this.store.list().filter((d) => d.seat_id).map((d) => [d.seat_id, d.name]));
        return this.seats.map((s) => ({ seat_id: s.seat_id, full_name: s.full_name, roles: s.roles, taken_by: holders.get(s.seat_id) ?? null }));
    }

    roster(me, deadlineEpoch, isOnline) {
        const seatName = new Map(this.seats.map((s) => [s.seat_id, s.full_name]));
        return {
            room: this.roomLabel, host: this.label, site: this.siteLabel, deadline_epoch: deadlineEpoch, you: me.id,
            people: this.store.list().map((d) => ({ name: d.name, model: d.model, seat: seatName.get(d.seat_id) ?? null, online: isOnline(d) }))
        };
    }

    // Used for a guest's own pick and for the host's assign. The old seat's sessions are
    // wiped first and a failed wipe stops the move: a stale session must never outlive its
    // seat. A concurrent grab loses at the atomic set and the device keeps its old seat.
    async moveToSeat(device, seatId, wipe) {
        const seat = this.seats.find((s) => s.seat_id === seatId);
        if (!seat) return { ok: false, status: 404, error: "no_such_seat" };
        const current = this.store.list().find((d) => d.id === device.id);
        if (!current) return { ok: false, status: 404, error: "not_found" };
        if (current.seat_id === seatId) return { ok: true, seat_id: seatId, full_name: seat.full_name };
        if (this.store.list().some((d) => d.seat_id === seatId)) return { ok: false, status: 409, error: "seat_taken" };
        if (current.user) {
            try {
                await wipe(current.user);
            } catch {
                return { ok: false, status: 503, error: "restarting" };
            }
        }
        try {
            this.store.takeSeat(device.id, seat);
        } catch (e) {
            if (e.code === "seat_taken") return { ok: false, status: 409, error: "seat_taken" };
            throw e;
        }
        return { ok: true, seat_id: seatId, full_name: seat.full_name };
    }
}

module.exports = { Room, PROTOCOL, FAILURE_BUDGET };
