"use strict";
// The CLI guest's protocol module (lib/frappe-local/share/guest.js) against a real gateway the test starts
// on loopback: the invite, the key check before anything is written, the join, this computer's key for a
// host, and the rooms file.
const test = require("node:test");
const assert = require("node:assert");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const util = require("node:util");
const { spawn } = require("node:child_process");
const H = require("./helpers.js");
const guest = require("../../lib/frappe-local/share/guest.js");

const { startGateway, roomCode } = H;
const LOOPBACK = "127.0.0.1";

async function withGateway(opts, fn) {
    const gw = await startGateway(opts);
    try {
        await fn(gw);
    } finally {
        await gw.stop();
    }
}

const refused = (code) => (e) => e instanceof guest.Refusal && e.code === code;
const people = async (gw) => (await gw.control({ op: "people" })).people;
const budget = async (gw) => (await gw.control({ op: "status" })).budget_left;

function inviteLink(over = {}) {
    const q = { v: "1", r: "Test%20Room", h: "ab".repeat(32), s: "cd".repeat(16), c: "482913", a: "192.168.1.20%3A8443", x: "1900000000", ...over };
    return "benchbar://share/join?" + Object.entries(q).filter(([, v]) => v !== null).map(([k, v]) => `${k}=${v}`).join("&");
}

// A child process that runs beside the others.
function start(args) {
    return new Promise((resolve) => {
        const child = spawn(process.execPath, args, { stdio: ["ignore", "pipe", "pipe"] });
        let text = "";
        child.stdout.on("data", (c) => (text += c));
        child.stderr.on("data", (c) => (text += c));
        child.on("close", (code) => resolve({ code, text }));
    });
}

test("an invite: the fields, a chat's wrapping, and the code in no JSON and no inspect of it", () => {
    const invite = guest.parseInvite(`Join my room <${inviteLink()}|here>.`);
    assert.deepStrictEqual({ ...invite, hostPin: invite.hostPin.toString("hex") },
        { room: "Test Room", hostPin: "ab".repeat(32), salt: "cd".repeat(16), address: { host: "192.168.1.20", port: 8443 }, expires: 1900000000 });
    assert.strictEqual(invite.code, "482913");
    assert.ok(!JSON.stringify(invite).includes("482913") && !util.inspect(invite).includes("482913"));
    assert.strictEqual(guest.parseInvite(inviteLink() + ").").code, "482913");
    assert.strictEqual(guest.parseInvite(inviteLink({ a: "8.8.8.8%3A8443" })).address.host, "8.8.8.8");
    assert.strictEqual(guest.parseInvite(inviteLink({ a: "host.example%3A8443" })).address, null);
    assert.throws(() => guest.parseInvite("no link here"), refused("invite_not_found"));
    assert.throws(() => guest.parseInvite(inviteLink({ v: "2" })), refused("invite_newer"));
    for (const bad of [inviteLink() + "&h=" + "cd".repeat(32), inviteLink() + "&c=111111", inviteLink({ c: "4829134" }), inviteLink({ c: "48 2913" }),
        inviteLink({ h: "ab" }), inviteLink({ s: "zz".repeat(16) }), inviteLink({ x: "0" }), inviteLink({ r: "%00" }), inviteLink({ r: "%E0%A4%A" }), inviteLink() + "#c=1"]) {
        assert.throws(() => guest.parseInvite(bad), refused("invite_malformed"), bad);
    }
});

test("the code, the addresses that are dialled, and the local name of a room", () => {
    assert.strictEqual(guest.normalizeCode("482 913"), "482913");
    for (const bad of ["48291", "4829133", "48291a", "\u0664\u0668\u0662\u0669\u0661\u0663", ""]) assert.strictEqual(guest.normalizeCode(bad), null);
    for (const local of ["10.0.0.5", "192.168.1.20", "172.16.0.1", "172.31.9.9", "169.254.1.1", "100.64.0.1"]) assert.ok(guest.isLocalNetwork(local), local);
    for (const far of ["8.8.8.8", "172.32.0.1", "100.128.0.1", "127.0.0.1", "192.169.1.1"]) assert.ok(!guest.isLocalNetwork(far), far);
    assert.strictEqual(guest.parseAddress("192.168.1.300:8443"), null);
    assert.strictEqual(guest.parseAddress("192.168.1.20:0"), null);
    assert.strictEqual(guest.slug("Priya\u2019s R\u00f6om!! "), "priyas-room");
    assert.strictEqual(guest.slug("\u65e5\u672c"), "room");
    const pin = Buffer.alloc(32, 7);
    const name = guest.localHost("Test Room", "0a1b2c3d", pin);
    assert.match(name, /^test-room-[0-9a-f]{16}\.localhost$/);
    assert.notStrictEqual(name, guest.localHost("Test Room", "0a1b2c3d", Buffer.alloc(32, 8)), "another host with the same label shares the cookie jar");
    assert.notStrictEqual(name, guest.localHost("Test Room", "ffffffff", pin), "another install shares the cookie jar");
    assert.strictEqual(guest.clean(" a\u202eb\u0007 \n c "), "a b c");
    assert.strictEqual(guest.clip("ab\u{1f600}cd", 3), "ab");
});

test("a join: the host's key is read without a certificate, the join is pinned to it, and the same key is known again", async () => {
    await withGateway({}, async (gw) => {
        const first = await guest.dial({ host: LOOPBACK, port: gw.port });
        const pin = first.bbSpki;
        const hello = await guest.roomHello(first);
        first.destroy();
        assert.strictEqual("sha256:" + pin.toString("hex"), gw.host.fp);
        assert.deepStrictEqual([hello.room, hello.host, hello.site, hello.people], ["Test Room", "Test Host", "", 0]);
        assert.deepStrictEqual(await people(gw), [], "a look left somebody in the room");

        const key = guest.newKey();
        const identity = guest.identityOf(key);
        const socket = await guest.dial({ host: LOOPBACK, port: gw.port, pin, identity });
        const joined = await guest.join(socket, { code: await roomCode(gw), name: "Lab PC", model: "Linux", fg: identity.fg });
        socket.destroy();
        assert.ok(joined.hostPin.equals(pin));
        const [row] = await people(gw);
        assert.deepStrictEqual([row.id, row.name, row.model, row.fp], [joined.deviceId, "Lab PC", "Linux", "sha256:" + identity.fg.toString("hex")]);

        // a certificate made anew around the same key is the same guest to the host
        const later = guest.identityOf(key);
        assert.notStrictEqual(later.cert, identity.cert);
        const again = await guest.dial({ host: LOOPBACK, port: gw.port, pin, identity: later });
        assert.strictEqual((await guest.call(again, "GET", "/_benchbar/hello")).device, joined.deviceId);
        again.destroy();
        const stranger = await guest.dial({ host: LOOPBACK, port: gw.port, pin, identity: guest.identityOf(guest.newKey()) });
        await assert.rejects(guest.call(stranger, "GET", "/_benchbar/hello"), refused("removed"));
        stranger.destroy();
    });
});

test("a host that shows another key is refused before a byte is written; a wrong code costs one try, a stale or foreign invite none", async () => {
    await withGateway({}, async (gw) => {
        await assert.rejects(guest.dial({ host: LOOPBACK, port: gw.port, pin: crypto.randomBytes(32) }), refused("identity_changed"));
        // the gateway sees the end of the connection a moment after this side closed it
        for (let i = 0; i < 80 && (await gw.control({ op: "status" })).conns !== 0; i++) await H.sleep(25);
        assert.strictEqual((await gw.control({ op: "status" })).conns, 0, "the refused connection stayed open");
        await assert.rejects(guest.dial({ host: LOOPBACK, port: await H.freePort(), timeoutMs: 2000 }), refused("unreachable"));

        const code = await roomCode(gw);
        const { salt } = await gw.control({ op: "code" });
        const identity = guest.identityOf(guest.newKey());
        const before = await budget(gw);
        const attempt = async (options) => {
            const socket = await guest.dial({ host: LOOPBACK, port: gw.port, pin: Buffer.from(gw.host.fp.slice(7), "hex"), identity });
            try {
                return await guest.join(socket, { name: "Lab PC", model: "Linux", fg: identity.fg, ...options });
            } finally {
                socket.destroy();
            }
        };
        const hostHex = gw.host.fp.slice(7);
        const invite = (over) => guest.parseInvite(inviteLink({ h: hostHex, s: salt, c: code, ...over }));
        await assert.rejects(attempt({ code: "12345" }), refused("invalid_code"));
        await assert.rejects(attempt({ code, invite: invite({ s: "00".repeat(16) }) }), refused("invite_out_of_date"));
        await assert.rejects(attempt({ code, invite: invite({ h: "ab".repeat(32) }) }), refused("not_the_invited_room"));
        assert.strictEqual(await budget(gw), before, "an invite that was stopped early was charged");
        await assert.rejects(attempt({ code: code === "000000" ? "111111" : "000000" }), refused("wrong_code"));
        assert.strictEqual(await budget(gw), before - 1);
        assert.deepStrictEqual(await people(gw), []);
        // the cooldown of the wrong code is for this address: the next try is told to wait, not let in
        await assert.rejects(attempt({ code, invite: invite({}) }), (e) => refused("rate_limited")(e) && e.retryAfter > 0);
        await gw.control({ op: "lock" });
        await assert.rejects(attempt({ code }), refused("locked"));
    });
});

test("this computer's key for a host: a 0600 file, or a Keychain item written on stdin; a store that cannot be read never gives a new key", () => {
    const dir = H.tmpDir();
    const host = "ab".repeat(32);
    const files = guest.keyStore({ kind: "file", dir });
    assert.strictEqual(files.load(host), null);
    const key = files.create(host);
    const file = path.join(dir, "keys", `${host}.pem`);
    assert.strictEqual(fs.statSync(file).mode & 0o777, 0o600);
    assert.strictEqual(fs.statSync(path.dirname(file)).mode & 0o777, 0o700);
    assert.ok(files.load(host).equals(key));
    assert.ok(guest.identityOf(files.load(host)).fg.equals(guest.identityOf(key).fg));
    fs.writeFileSync(file, "not a key");
    assert.throws(() => files.load(host), refused("key_store"));
    files.remove(host);
    assert.strictEqual(files.load(host), null);

    // a stand-in for /usr/bin/security: items are files, every argument list is recorded
    const security = path.join(dir, "security");
    fs.writeFileSync(security, `#!/bin/bash
printf '%s\\n' "$*" >>"${dir}/security.argv"
[[ -f "${dir}/locked" ]] && exit 36
if [[ "$1" == -i ]]; then
  IFS= read -r line
  [[ "$line" =~ -a\\ \\"([0-9a-f]+)\\".*-w\\ \\"([A-Za-z0-9+/=]+)\\" ]] || exit 1
  printf '%s\\n' "\${BASH_REMATCH[2]}" >"${dir}/item-\${BASH_REMATCH[1]}"; exit 0
fi
item="${dir}/item-$5"
case "$1" in
  find-generic-password) [[ -f "$item" ]] || exit 44; cat "$item" ;;
  delete-generic-password) rm -f "$item" ;;
esac
`, { mode: 0o700 });
    const chain = guest.keyStore({ kind: "keychain", dir, security });
    assert.strictEqual(chain.load(host), null);
    const kept = chain.create(host);
    assert.ok(chain.load(host).equals(kept));
    const secret = kept.export({ type: "pkcs8", format: "der" }).toString("base64");
    assert.strictEqual(fs.readFileSync(path.join(dir, `item-${host}`), "utf8").trim(), secret);
    assert.ok(!fs.readFileSync(path.join(dir, "security.argv"), "utf8").includes(secret.slice(0, 40)), "the key was an argument of security");
    fs.writeFileSync(path.join(dir, "locked"), "");
    assert.throws(() => chain.load(host), refused("key_store"));
    assert.throws(() => chain.create("cd".repeat(32)), refused("key_store"));
    fs.rmSync(path.join(dir, "locked"));
    chain.remove(host);
    assert.strictEqual(chain.load(host), null);
});

test("several joins at once: every room ends up in the rooms file", async () => {
    const shared = H.tmpDir();
    const save = `const hex = process.argv[1].repeat(64);
        require(${JSON.stringify(path.join(__dirname, "../../lib/frappe-local/share/guest.js"))}).roomsStore(${JSON.stringify(shared)}).save({ id: hex.slice(0, 16),
            host_fp: "sha256:" + hex, device_id: "d_00000001", room: "Room " + process.argv[1], host: "Host", site: "", address: "192.168.1.2", port: 8443,
            local_port: null, joined_at: "2026-11-25T00:00:00.000Z", salt: "00".repeat(16) });`;
    const digits = "0123456789abcdef".split("");
    const saved = await Promise.all(digits.map((digit) => start(["-e", save, digit])));
    assert.deepStrictEqual(saved.map((r) => r.code), digits.map(() => 0), saved.map((r) => r.text).join(""));
    assert.deepStrictEqual(guest.roomsStore(shared).load().map((r) => r.room).sort(), digits.map((digit) => `Room ${digit}`));
    assert.ok(!fs.existsSync(path.join(shared, "rooms.lock")), "the lock of the rooms file was left behind");
    // the suffix behind the local names: 128 bits, the same at every call
    const suffix = guest.roomsStore(shared).suffix();
    assert.match(suffix, /^[0-9a-f]{32}$/);
    assert.strictEqual(guest.roomsStore(shared).suffix(), suffix);
    assert.strictEqual(fs.statSync(path.join(shared, "rooms.json")).mode & 0o777, 0o600);
});

// A TLS 1.3 server for one made-up host: it counts every byte a guest writes, and answers with `reply(socket)`.
function fakeHost(reply) {
    const identity = guest.identityOf(guest.newKey());
    const seen = { bytes: 0, connections: 0 };
    const tlsServer = require("node:tls").createServer({ key: identity.key, cert: identity.cert, minVersion: "TLSv1.3", maxVersion: "TLSv1.3" }, (socket) => {
        seen.connections++;
        socket.on("error", () => {});
        socket.on("data", (chunk) => {
            seen.bytes += chunk.length;
            if (reply) reply(socket);
        });
    });
    return new Promise((resolve) => tlsServer.listen(0, LOOPBACK, () => resolve({ pin: identity.fg, port: tlsServer.address().port, seen, close: () => tlsServer.close() })));
}

test("a wrong key is refused before one byte is written, the right key lets the request through", async () => {
    const host = await fakeHost();
    try {
        await assert.rejects(guest.dial({ host: LOOPBACK, port: host.port, pin: crypto.randomBytes(32) }), refused("identity_changed"));
        await H.sleep(150);
        assert.strictEqual(host.seen.bytes, 0, "a request went out before the key was compared");
        const socket = await guest.dial({ host: LOOPBACK, port: host.port, pin: host.pin });
        guest.exchange(socket, "GET", "/room/hello", null, 200).catch(() => {});
        await H.sleep(150);
        assert.ok(host.seen.bytes > 0, "the stand in host does not see a request, so the check above proves nothing");
        socket.destroy();
        // a guest key is only ever shown to a pinned host
        await assert.rejects(guest.dial({ host: LOOPBACK, port: host.port, identity: guest.identityOf(guest.newKey()) }), refused("failed"));
    } finally {
        host.close();
    }
});

test("a reply is capped and a silent host times out", async () => {
    const big = await fakeHost((socket) => socket.write(`HTTP/1.1 200 OK\r\nContent-Length: 999999\r\n\r\n${"x".repeat(300_000)}`));
    const silent = await fakeHost();
    try {
        let socket = await guest.dial({ host: LOOPBACK, port: big.port, pin: big.pin });
        await assert.rejects(guest.exchange(socket, "GET", "/room/hello"), refused("failed"));
        socket.destroy();
        socket = await guest.dial({ host: LOOPBACK, port: silent.port, pin: silent.pin });
        const began = Date.now();
        await assert.rejects(guest.exchange(socket, "GET", "/room/hello", null, 300), refused("unreachable"));
        assert.ok(Date.now() - began < 3000);
        socket.destroy();
    } finally {
        big.close();
        silent.close();
    }
});

test("an invite with huge values, %26 and other cases", () => {
    const long = (n, ch) => ch.repeat(n);
    assert.strictEqual(guest.parseInvite(inviteLink({ r: long(200_000, "a") })).room.length, 40);
    for (const bad of [inviteLink({ x: long(5000, "9") }), inviteLink({ h: long(100_000, "a") }), inviteLink({ s: long(100_000, "b") }), inviteLink({ c: long(100_000, "1") })]) {
        assert.throws(() => guest.parseInvite(bad), refused("invite_malformed"));
    }
    assert.strictEqual(guest.parseInvite(inviteLink({ r: "a%26b" })).room, "a&b");
    // an encoded & stays inside its value: it never starts a second field
    assert.strictEqual(guest.parseInvite(inviteLink({ r: "a%26c%3D111111" })).code, "482913");
    assert.strictEqual(guest.parseInvite(inviteLink({ a: "192.168.1.20%3A8443%26x%3D1" })).address, null);
    assert.throws(() => guest.parseInvite(inviteLink({ c: "48%2029" })), refused("invite_malformed"));
    // names are case sensitive (an upper case H is not h), hex digits and the scheme are not
    assert.throws(() => guest.parseInvite(inviteLink().replace("&h=", "&H=")), refused("invite_malformed"));
    assert.strictEqual(guest.parseInvite(inviteLink({ h: "AB".repeat(32), s: "CD".repeat(16) })).salt, "cd".repeat(16));
    assert.strictEqual(guest.parseInvite(inviteLink().replace("benchbar://share/join", "BenchBar://Share/Join")).code, "482913");
});

test("only four plain octets are a local network", () => {
    for (const bad of ["10.evil.com", "192.168.1", "10", "10.0.0", "10.0.0.1.1", "10.0.0.256", "0x0a.0.0.1", "10..0.1", "10.0.0.1 ", "", "10.0.0.-1"]) assert.ok(!guest.isLocalNetwork(bad), bad);
    assert.ok(guest.isLocalNetwork("10.0.0.255"));
});

test("a hello without a site is not a room", async () => {
    const host = await fakeHost((socket) => {
        const body = JSON.stringify({ v: 3, room: "R", host: "H", salt: "00".repeat(16), locked: false, full: false, people: 0, seats: 0 });
        socket.write(`HTTP/1.1 200 OK\r\nContent-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
    });
    try {
        const socket = await guest.dial({ host: LOOPBACK, port: host.port, pin: host.pin });
        await assert.rejects(guest.roomHello(socket), refused("failed"));
        socket.destroy();
    } finally {
        host.close();
    }
});

test("a lock is broken by one waiter, never under a live holder, and never takes a fresh lock away", async () => {
    const dir = H.tmpDir();
    const lock = path.join(dir, "x.lock");
    // a long holder keeps its lock alive: a second taker times out while the work waits longer than the stale limit
    const slow = guest.locked(lock, async () => { await H.sleep(900); return "done"; }, { staleMs: 300 });
    await H.sleep(100);
    await assert.rejects(guest.locked(lock, async () => "second", { staleMs: 300, timeoutMs: 600 }), refused("busy"));
    assert.strictEqual(await slow, "done");
    assert.ok(!fs.existsSync(lock));

    // a lock whose owner died is broken, by one of many waiters at a time: the work never overlaps
    const log = path.join(dir, "log");
    fs.writeFileSync(lock, "dead");
    const past = new Date(Date.now() - 600_000);
    fs.utimesSync(lock, past, past);
    const work = `const g = require(${JSON.stringify(path.join(__dirname, "../../lib/frappe-local/share/guest.js"))});
        const fs = require("fs");
        g.lockedSync(${JSON.stringify(lock)}, () => { fs.appendFileSync(${JSON.stringify(log)}, "in\\n"); const end = Date.now() + 25; while (Date.now() < end); fs.appendFileSync(${JSON.stringify(log)}, "out\\n"); });`;
    const runs = await Promise.all(Array.from({ length: 12 }, () => start(["-e", work])));
    assert.deepStrictEqual(runs.map((r) => r.code), runs.map(() => 0), runs.map((r) => r.text).join(""));
    assert.strictEqual(fs.readFileSync(log, "utf8"), "in\nout\n".repeat(12), "two holders were inside at once");
    assert.deepStrictEqual(fs.readdirSync(dir).filter((n) => n.startsWith("x.lock")), [], "the lock or its helper files were left behind");
});

test("a rooms file that cannot be read is refused and kept, and the suffix does not change", () => {
    const dir = H.tmpDir();
    const store = guest.roomsStore(dir);
    const suffix = store.suffix();
    assert.strictEqual(store.suffix(), suffix);
    const file = path.join(dir, "rooms.json");
    const room = { id: "ab".repeat(8), host_fp: "sha256:" + "ab".repeat(32), device_id: "d_00000001", room: "R", host: "H", site: "", address: "192.168.1.2", port: 8443, local_port: null, joined_at: "2026-11-25T00:00:00.000Z", salt: "00".repeat(16) };
    store.save(room);
    for (const bad of ["{ not json", "[]", "null", "42"]) {
        fs.writeFileSync(file, bad);
        assert.throws(() => store.load(), refused("rooms_file"), bad);
        assert.throws(() => store.suffix(), refused("rooms_file"), bad);
        assert.throws(() => store.save(room), refused("rooms_file"), bad);
        assert.throws(() => store.forget(room.id), refused("rooms_file"), bad);
        assert.strictEqual(fs.readFileSync(file, "utf8"), bad, "the unreadable file was written over");
    }
    // a file without a suffix gets one, once
    fs.writeFileSync(file, JSON.stringify({ v: 1, rooms: [] }));
    const made = store.suffix();
    assert.match(made, /^[0-9a-f]{32}$/);
    assert.strictEqual(store.suffix(), made);
});

test("the key store takes only a 64 digit host, hands out one key to two callers, and loads a loose file as private", () => {
    const dir = H.tmpDir();
    const files = guest.keyStore({ kind: "file", dir });
    for (const bad of ["", "ab", "../../etc/x", "ab".repeat(32) + "\n", "AB".repeat(32)]) {
        for (const op of ["load", "create", "remove", "obtain"]) assert.throws(() => files[op](bad), refused("key_store"), `${op} ${JSON.stringify(bad)}`);
    }
    const host = "cd".repeat(32);
    const first = files.obtain(host);
    assert.strictEqual(first.fresh, true);
    const second = files.obtain(host);
    assert.deepStrictEqual([second.fresh, second.key.equals(first.key)], [false, true]);
    assert.ok(!fs.existsSync(path.join(dir, "keys.lock")));
    const file = path.join(dir, "keys", `${host}.pem`);
    fs.chmodSync(file, 0o644);
    assert.ok(files.load(host).equals(first.key));
    assert.strictEqual(fs.statSync(file).mode & 0o777, 0o600);

    // a Keychain that refuses the delete is told to the caller, a missing item is nothing to do
    const security = path.join(dir, "security");
    fs.writeFileSync(security, "#!/bin/bash\n[[ -f \"" + dir + "/locked\" ]] && exit 36\nexit 44\n", { mode: 0o700 });
    const chain = guest.keyStore({ kind: "keychain", dir, security });
    chain.remove(host);
    fs.writeFileSync(path.join(dir, "locked"), "");
    assert.throws(() => chain.remove(host), refused("key_store"));
});
