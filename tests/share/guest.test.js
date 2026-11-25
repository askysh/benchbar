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
            const socket = await guest.dial({ host: LOOPBACK, port: gw.port, identity });
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
});
