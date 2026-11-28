"use strict";
// What `benchbar share join|joined|leave|forget` runs: one operation for each run.
//
//   node guest-cli.js look|join|open|wait|seats|seat|joined|close|leave|forget   <request on stdin, one JSON object>
//
// The request comes on stdin, never as an argument: it carries the room code or the invite link. The
// answer is KEY=VALUE lines of cleaned fields, `row=` lines for a list, and `doc=`, the members of a JSON
// object for --json. No line ever holds the code, a key or anything derived from them. A refusal is
// `error=WORD` and exit 1; the shell has the sentence for each word.
const path = require("path");
const fs = require("fs");
const { spawn } = require("child_process");
const guest = require("./guest.js");
const forward = require("./guest-forward.js");

const { Refusal } = guest;
const FORWARD_JS = path.join(__dirname, "guest-forward.js");
const SEAT_ID = /^[A-Za-z0-9_-]{1,64}$/;
const ROOM_ID = /^[0-9a-f]{16}$/;
const START_WAIT_MS = 8_000;
const WAIT_STEP_MS = 3_000;
const SEP = "\x1f";

const fpOf = (pin) => `sha256:${pin.toString("hex")}`;
const pinOf = (room) => Buffer.from(room.host_fp.slice(7), "hex");

function context(req) {
    if (typeof req.dir !== "string" || !path.isAbsolute(req.dir)) throw new Refusal("failed");
    const kind = req.keystore === "keychain" ? "keychain" : "file";
    const security = typeof req.security === "string" ? req.security : "/usr/bin/security";
    return {
        dir: req.dir, kind, security, hideUrl: req.hide_url === true,
        rooms: guest.roomsStore(req.dir), keys: guest.keyStore({ kind, dir: req.dir, security })
    };
}

// The room an operation is for: its id (the 16 digits of the host's key), or the one room there is.
function savedRoom(ctx, id) {
    const rooms = ctx.rooms.load();
    if (id === undefined || id === "") {
        if (rooms.length === 1) return rooms[0];
        throw new Refusal(rooms.length ? "which_room" : "no_rooms");
    }
    const room = ROOM_ID.test(String(id)) ? rooms.find((r) => r.id === id) : null;
    if (!room) throw new Refusal("no_such_room");
    return room;
}

// A pinned connection that presents this computer's key for the room's host.
async function connect(ctx, room) {
    const key = ctx.keys.load(room.host_fp.slice(7));
    if (!key) throw new Refusal("key_store");
    return guest.dial({ host: room.address, port: room.port, pin: pinOf(room), identity: guest.identityOf(key) });
}

async function withRoom(ctx, room, fn) {
    const socket = await connect(ctx, room);
    try {
        return await fn(socket);
    } finally {
        socket.destroy();
    }
}

// An address a person typed or an invite carries is dialled only when it is one of a local network
// (the tests' gateway listens on loopback and says so).
function usable(req, address) {
    return guest.isLocalNetwork(address.host) || (req.allow_loopback === true && address.host.startsWith("127."));
}

// True when no forwarder runs any more. "Runs" is a control socket that takes a connection
// (forward.alive): one that is slow to answer is not gone, and saying so would report an address closed
// that is open. One that ignores "stop" is ended by its pid. The pid is the one it names in an answer asked
// for just before the end: a pid from an answer that is seconds old can belong to another process by then.
// When it cannot be ended the caller is told.
async function stopForwarder(ctx, id, { stopMs = 3_000, tries = 30, statusMs = 2_000 } = {}) {
    if (!(await forward.alive(ctx.dir, id, 1_000))) return true;
    await forward.ask(ctx.dir, id, "stop", stopMs);
    const gone = async () => {
        for (let i = 0; i < tries; i++) {
            if (!(await forward.alive(ctx.dir, id, 500))) return true;
            await guest.sleep(100);
        }
        return false;
    };
    if (await gone()) return true;
    const now = await forward.ask(ctx.dir, id, "status", statusMs);
    if (!now || !Number.isInteger(now.pid) || now.pid <= 1) return false;
    let sent = true;
    try {
        process.kill(now.pid, "SIGKILL");
    } catch { sent = false; /* it ended by itself just now, or the pid is not ours to end */ }
    if (sent ? !(await gone()) : await forward.alive(ctx.dir, id, 500)) return false;
    fs.rmSync(path.join(ctx.dir, `${id}.sock`), { force: true });
    return true;
}

// The room's forwarder, started detached when none runs. Its arguments name the folder and the room; the
// key it reads from the key store itself. Asking and starting happen under a lock of the room, so two
// commands at once start one forwarder, on one port. One that runs and does not answer yet (its port is
// not bound) is waited for: a second one beside it would only say already_running and end.
async function forwarderOf(ctx, room) {
    let status = await guest.locked(path.join(ctx.dir, `${room.id}.start`), async () => {
        let up = await forward.ask(ctx.dir, room.id, "status", 2_000);
        if (up) return up;
        if (await forward.alive(ctx.dir, room.id)) {
            up = await forward.ask(ctx.dir, room.id, "status", START_WAIT_MS);
        } else {
            spawn(process.execPath, [FORWARD_JS, ctx.dir, ctx.kind, ctx.security, room.id], { detached: true, stdio: "ignore", cwd: ctx.dir }).unref();
            for (let waited = 0; !up && waited < START_WAIT_MS; waited += 100) {
                await guest.sleep(100);
                up = await forward.ask(ctx.dir, room.id, "status", 500);
            }
        }
        if (!up) throw new Refusal("forwarder");
        return up;
    });
    status = (await forward.ask(ctx.dir, room.id, "ping")) || status;
    if (room.local_port !== status.port) ctx.rooms.save({ ...room, local_port: status.port });
    return status;
}

const live = (room, status, hideUrl = false) => ({
    id: room.id, room: room.room, host: room.host, site: (status && status.site) || room.site, address: room.address, port: room.port,
    host_key: room.host_fp.slice(7, 23), joined_at: room.joined_at, forwarding: Boolean(status), state: status ? status.state : "closed",
    seat: status ? status.seat : null, url: status && !hideUrl ? status.url : null, local_port: status ? status.port : null,
    deadline_epoch: status ? status.deadline_epoch : null
});

const ops = {
    // The first look at a room: its key, its words and its state, read on a connection that shows no
    // certificate. Nothing derived from the code is sent, so the host's wrong code budget is untouched.
    async look(req, ctx) {
        const invite = req.invite !== undefined ? guest.parseInvite(req.invite) : null;
        const address = invite ? invite.address : guest.parseAddress(`${req.address}:${req.port}`);
        if (!address) throw new Refusal(invite ? "invite_no_address" : "bad_address");
        if (!usable(req, address)) throw new Refusal(invite ? "invite_no_address" : "not_local");
        // the key the person confirmed in an earlier run (--host-key): a host that shows another key is
        // refused in the handshake, before any request, and so is an invite for another key
        if (req.expect_pin !== undefined && !/^[0-9a-f]{64}$/.test(String(req.expect_pin))) throw new Refusal("failed");
        const expected = req.expect_pin === undefined ? null : Buffer.from(req.expect_pin, "hex");
        if (invite && expected && !invite.hostPin.equals(expected)) throw new Refusal("host_key_mismatch");
        const rooms = ctx.rooms.load();
        let socket;
        try {
            socket = await guest.dial({ ...address, pin: invite ? invite.hostPin : expected });
        } catch (e) {
            if (invite && e.code === "identity_changed") throw new Refusal("not_the_invited_room");
            if (expected && e.code === "identity_changed") throw new Refusal("host_key_mismatch");
            // `x` is advisory (the host may have extended): it only explains a room that is gone
            if (invite && invite.expires * 1000 <= Date.now()) throw new Refusal("invite_expired");
            throw e;
        }
        let hello;
        const pin = socket.bbSpki;
        try {
            // a host this computer joined at this address must show the key it showed then: never trusted anew
            const earlier = invite ? null : rooms.find((r) => r.address === address.host && r.port === address.port);
            if (earlier && earlier.host_fp !== fpOf(pin)) throw new Refusal("identity_changed", { room: earlier.id });
            hello = await guest.roomHello(socket);
        } finally {
            socket.destroy();
        }
        if (hello.v !== guest.PROTOCOL) throw new Refusal("needs_update");
        if (invite && hello.salt.toLowerCase() !== invite.salt) throw new Refusal("invite_out_of_date");
        const saved = rooms.find((r) => r.host_fp === fpOf(pin));
        let paired = false;
        if (saved) {
            paired = await withRoom(ctx, { ...saved, address: address.host, port: address.port }, (s) => guest.call(s, "GET", "/_benchbar/hello")).then(() => true, () => false);
            if (paired && (saved.address !== address.host || saved.port !== address.port)) ctx.rooms.save({ ...saved, address: address.host, port: address.port });
        }
        return {
            id: guest.roomId(pin), host_pin: pin.toString("hex"), host_key: guest.roomId(pin), address: address.host, port: address.port,
            room: guest.clean(hello.room), host: guest.clean(hello.host), locked: hello.locked, full: hello.full, people: hello.people, seats: hello.seats,
            known: Boolean(saved), paired, from_invite: Boolean(invite)
        };
    },

    // The join with the code, pinned to the key `look` read. This computer's key for that host is made
    // here when there is none, and goes again when the join does not end in a saved room. From the key to
    // the saved room, one join for a host runs at a time: a second one that found the first one's key would
    // lose it when the first fails.
    async join(req, ctx) {
        const invite = req.invite !== undefined ? guest.parseInvite(req.invite) : null;
        const address = guest.parseAddress(`${req.address}:${req.port}`);
        if (!address || !usable(req, address) || !/^[0-9a-f]{64}$/.test(String(req.host_pin))) throw new Refusal("failed");
        const pin = Buffer.from(req.host_pin, "hex");
        if (invite && !invite.hostPin.equals(pin)) throw new Refusal("not_the_invited_room");
        const code = invite ? invite.code : req.code;
        if (!guest.normalizeCode(code)) throw new Refusal("invalid_code");
        const host = pin.toString("hex");
        const room = await guest.locked(path.join(ctx.dir, `${guest.roomId(pin)}.join`), async () => {
            const earlier = ctx.rooms.load().find((r) => r.host_fp === fpOf(pin));
            const { key, fresh } = ctx.keys.obtain(host);
            const identity = guest.identityOf(key);
            let joined;
            try {
                const socket = await guest.dial({ ...address, pin, identity });
                try {
                    joined = await guest.join(socket, { code, name: guest.clean(req.name) || "BenchBar guest", model: guest.clean(req.model) || "computer", fg: identity.fg, invite });
                } finally {
                    socket.destroy();
                }
            } catch (e) {
                if (fresh && !earlier) ctx.keys.remove(host);
                throw e;
            }
            const saved = {
                id: guest.roomId(pin), host_fp: fpOf(pin), device_id: joined.deviceId, room: guest.clean(joined.hello.room), host: guest.clean(joined.hello.host),
                site: "", address: address.host, port: address.port, local_port: earlier ? earlier.local_port : null, joined_at: new Date().toISOString(), salt: joined.hello.salt
            };
            ctx.rooms.save(saved);
            return saved;
        });
        // A forwarder of the room this host had before would show the pages of that room. The join is made
        // and saved by now: when that forwarder cannot be stopped, the person is told what is left to do.
        if (!(await stopForwarder(ctx, room.id))) throw new Refusal("forwarder_stuck");
        return live(room, await forwarderOf(ctx, room));
    },

    // Starts the forwarder of a room this computer is in, and says how the room is.
    async open(req, ctx) {
        const room = savedRoom(ctx, req.id);
        return live(room, await forwarderOf(ctx, room));
    },

    // Waits until the host gave this computer a seat, the room said no, or `timeout_s` passed.
    async wait(req, ctx) {
        const room = savedRoom(ctx, req.id);
        const until = Date.now() + Math.min(Math.max(Number(req.timeout_s) || 0, 0), 3600) * 1000;
        for (;;) {
            const status = await forward.ask(ctx.dir, room.id, "ping");
            if (!status) throw new Refusal("forwarder");
            if (!["waiting", "offline", "unknown"].includes(status.state) || Date.now() >= until) return live(room, status);
            await guest.sleep(Math.min(WAIT_STEP_MS, Math.max(until - Date.now(), 0)));
        }
    },

    async seats(req, ctx) {
        const room = savedRoom(ctx, req.id);
        const listed = await withRoom(ctx, room, (s) => guest.call(s, "GET", "/_benchbar/seats"));
        const seats = (Array.isArray(listed) ? listed : []).filter((s) => s && SEAT_ID.test(s.seat_id)).map((s) => ({
            seat_id: s.seat_id, full_name: guest.clean(s.full_name), roles: (Array.isArray(s.roles) ? s.roles : []).map(guest.clean).filter(Boolean).slice(0, 30),
            taken_by: typeof s.taken_by === "string" ? guest.clean(s.taken_by) : null
        }));
        const hostAssigns = Array.isArray(listed) && listed.some((s) => s && s.host_assigns === true);
        return { host_assigns: hostAssigns, seats, rows: seats.map((s) => [s.seat_id, s.full_name, s.taken_by ?? ""].join(SEP)) };
    },

    // J10: the seat id as the host listed it, matched exactly there.
    async seat(req, ctx) {
        const room = savedRoom(ctx, req.id);
        if (!SEAT_ID.test(String(req.seat_id))) throw new Refusal("no_such_seat");
        await withRoom(ctx, room, (s) => guest.call(s, "POST", "/_benchbar/seat", { seat_id: req.seat_id }));
        return live(room, await forwarderOf(ctx, room));
    },

    // The rooms this computer joined. Only the forwarders are asked, on their local sockets: no room is dialled.
    async joined(req, ctx) {
        const rooms = await Promise.all(ctx.rooms.load().map(async (room) => live(room, await forward.ask(ctx.dir, room.id, "status", 2_000), ctx.hideUrl)));
        return { rooms, rows: rooms.map((r) => [r.id, r.room, r.host, r.state, r.seat ?? "", r.url ?? "", `${r.address}:${r.port}`].join(SEP)) };
    },

    // Stops every forwarder and tells no host: the lan-rooms Lab was turned off.
    async close(req, ctx) {
        const rooms = ctx.rooms.load();
        let stuck = 0;
        for (const room of rooms) if (!(await stopForwarder(ctx, room.id))) stuck++;
        return { closed: rooms.length - stuck, forwarders_left: stuck };
    },

    // Tells the host, best effort, so the seat is free and its sessions end there; then the forwarder stops.
    // The room and the key stay: joining that host again shows the same key.
    async leave(req, ctx) {
        const room = savedRoom(ctx, req.id);
        const told = await withRoom(ctx, room, (s) => guest.call(s, "POST", "/_benchbar/leave", {})).then(() => true, () => false);
        const stopped = await stopForwarder(ctx, room.id);
        return { id: room.id, room: room.room, host: room.host, told_host: told, forwarder_stopped: stopped };
    },

    // leave, then the saved room and this computer's key for its host are deleted.
    async forget(req, ctx) {
        const room = savedRoom(ctx, req.id);
        const left = await ops.leave(req, ctx);
        ctx.rooms.forget(room.id);
        ctx.keys.remove(room.host_fp.slice(7));
        return { ...left, forgotten: true };
    }
};

const flat = (value) => String(value).replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, " ");

function print(result) {
    const { rows = [], ...doc } = result;
    const lines = [];
    for (const [key, value] of Object.entries(doc)) {
        if (value === null) lines.push(`${key}=`);
        else if (["string", "number", "boolean"].includes(typeof value)) lines.push(`${key}=${flat(value)}`);
    }
    for (const row of rows) lines.push(`row=${row.split(SEP).map(flat).join(SEP)}`);
    lines.push(`doc=${JSON.stringify(doc).slice(1, -1)}`);
    process.stdout.write(lines.join("\n") + "\n");
}

async function main(op) {
    process.umask(0o077);
    let text = "";
    for await (const chunk of process.stdin) {
        text += chunk;
        if (text.length > 65536) break;
    }
    try {
        if (!Object.hasOwn(ops, op)) throw new Refusal("failed");
        const req = JSON.parse(text);
        const ctx = context(req);
        forward.here(ctx.dir);
        print(await ops[op](req, ctx));
        process.exit(0);
    } catch (e) {
        const refusal = e instanceof Refusal ? e : new Refusal("failed");
        const lines = [`error=${/^[a-z_]{1,32}$/.test(refusal.code) ? refusal.code : "failed"}`];
        if (Number.isInteger(refusal.retryAfter)) lines.push(`retry_after=${refusal.retryAfter}`);
        if (ROOM_ID.test(String(refusal.room))) lines.push(`room=${refusal.room}`);
        process.stdout.write(lines.join("\n") + "\n");
        process.exit(1);
    }
}

if (require.main === module) main(process.argv[2]);

module.exports = { ops, context, print, stopForwarder };
