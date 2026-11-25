"use strict";
// The CLI guest (lib/frappe-local/share/guest*.js) against a real gateway the test starts on loopback:
// the invite, the key check before anything is written, the join, this computer's key for a host, the
// forwarder, and the rule that the room code and the keys are in no argument, no output and no other file.
const test = require("node:test");
const assert = require("node:assert");
const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const util = require("node:util");
const { spawn, spawnSync, execFileSync } = require("node:child_process");
const H = require("./helpers.js");
const guest = require("../../lib/frappe-local/share/guest.js");
const forward = require("../../lib/frappe-local/share/guest-forward.js");

const { startGateway, roomCode } = H;
const CLI = path.join(__dirname, "../../lib/frappe-local/share/guest-cli.js");
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

// One run of guest-cli.js, the way the shell runs it: the request on stdin, KEY=VALUE lines back.
function answer(code, stdout, stderr = "") {
    const out = { code, text: stdout + stderr, rows: [] };
    for (const line of stdout.split("\n").filter(Boolean)) {
        const [key, value] = [line.slice(0, line.indexOf("=")), line.slice(line.indexOf("=") + 1)];
        if (key === "row") out.rows.push(value.split("\x1f"));
        else if (key === "doc") out.doc = JSON.parse(`{${value}}`);
        else out[key] = value;
    }
    return out;
}

function cli(dir, op, req = {}) {
    const r = spawnSync(process.execPath, [CLI, op], { input: JSON.stringify({ dir, allow_loopback: true, ...req }), encoding: "utf8", timeout: 60_000 });
    return answer(r.status, r.stdout, r.stderr);
}

// A child process that runs beside the others; `input` goes to its stdin.
function start(args, input = "") {
    return new Promise((resolve) => {
        const child = spawn(process.execPath, args, { stdio: ["pipe", "pipe", "pipe"] });
        let stdout = "";
        child.stdout.on("data", (c) => (stdout += c));
        child.stderr.on("data", (c) => (stdout += c));
        child.on("close", (code) => resolve(answer(code, stdout)));
        child.stdin.end(input);
    });
}

// A request through the forwarder, as a browser sends it.
function browse(port, host, target, headers = {}) {
    return new Promise((resolve, reject) => {
        const req = http.request({ host: LOOPBACK, port, path: target, agent: false, headers: { host, accept: "text/html", ...headers } }, (res) => {
            let text = "";
            res.on("data", (c) => (text += c));
            res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, text }));
        });
        req.on("error", reject);
        req.end();
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
    // the suffix behind the local names: 128 bits, the same at every call
    const suffix = guest.roomsStore(shared).suffix();
    assert.match(suffix, /^[0-9a-f]{32}$/);
    assert.strictEqual(guest.roomsStore(shared).suffix(), suffix);
    assert.strictEqual(fs.statSync(path.join(shared, "rooms.json")).mode & 0o777, 0o600);
});

test("the forwarder's check of a browser's request: one Host, the same origin, no upgrade, and Connection: close", () => {
    const head = (lines) => Buffer.from(["GET /app HTTP/1.1", ...lines, "", "body"].join("\r\n"));
    const want = "room-0123456789abcdef.localhost:41000";
    const ok = forward.gate(head([`Host: ${want}`, "Connection: keep-alive", "Keep-Alive: 5", "Cookie: sid=1", `Origin: http://${want}`, "Sec-Fetch-Site: same-origin"]), want);
    assert.strictEqual(ok.verdict, "relay");
    assert.strictEqual(ok.head.toString(), ["GET /app HTTP/1.1", `Host: ${want}`, "Cookie: sid=1", `Origin: http://${want}`, "Sec-Fetch-Site: same-origin", "Connection: close", "", "body"].join("\r\n"));
    for (const lines of [["Host: evil.example"], [`Host: ${want}`, `Host: ${want}`], [], [`Host: ${want}`, "Origin: http://evil.example"], [`Host: ${want}`, "Sec-Fetch-Site: cross-site"],
        [`Host: ${want}`, "Sec-Fetch-Site: Same-Site"], [`Host: ${want}`, "Upgrade: websocket"], [`Host: ${want}`, " folded"], [`Host: ${want}`, "no colon"]]) {
        assert.strictEqual(forward.gate(head(lines), want).verdict, "refuse", lines.join(" | "));
    }
    assert.strictEqual(forward.gate(Buffer.from(`GET / HTTP/1.1\r\nHost: ${want}\r\n`), want).verdict, "more");
    assert.strictEqual(forward.gate(Buffer.alloc(33 * 1024, 65), want).verdict, "refuse");
    const shown = forward.page("removed", "<Priya>", true).toString();
    assert.match(shown, /^HTTP\/1\.1 403 /);
    assert.ok(shown.includes("&lt;Priya&gt; removed you") && !shown.includes("<Priya>") && shown.includes("default-src 'none'"));
});

test("guest-cli: look, join, a seat, the room through the forwarder, leave and forget; the code and the key are in no argument, output or other file", async () => {
    await withGateway({}, async (gw) => {
        const dir = H.tmpDir();
        const outputs = [];
        const run = (op, req) => { const r = cli(dir, op, req); outputs.push(r.text); return r; };
        const code = await roomCode(gw);
        const hostHex = gw.host.fp.slice(7);
        const id = hostHex.slice(0, 16);
        H.track(() => forward.ask(dir, id, "stop", 2000));

        assert.strictEqual(cli(dir, "look", { address: LOOPBACK, port: gw.port, allow_loopback: false }).error, "not_local");
        assert.strictEqual(run("look", { address: "192.168.1", port: 8443 }).error, "bad_address");
        const seen = run("look", { address: LOOPBACK, port: gw.port });
        assert.deepStrictEqual([seen.code, seen.host_key, seen.host_pin, seen.room, seen.host, seen.known, seen.paired, seen.locked],
            [0, id, hostHex, "Test Room", "Test Host", "false", "false", "false"]);

        const wrong = run("join", { address: LOOPBACK, port: gw.port, host_pin: hostHex, code: code === "000000" ? "111111" : "000000", name: "Lab PC", model: "Linux" });
        assert.deepStrictEqual([wrong.code, wrong.error], [1, "wrong_code"]);
        assert.ok(!fs.existsSync(path.join(dir, "keys", `${hostHex}.pem`)), "a join that was refused left its key behind");
        gw.jump(120_000);   // past the cooldown of the wrong code

        const joined = run("join", { address: LOOPBACK, port: gw.port, host_pin: hostHex, code, name: "Lab PC", model: "Linux" });
        assert.deepStrictEqual([joined.code, joined.id, joined.state, joined.forwarding], [0, id, "waiting", "true"], joined.text);
        const port = Number(joined.local_port);
        const name = new URL(joined.url).host;
        assert.match(name, /^test-room-[0-9a-f]{16}\.localhost:41[0-9]{3}$/);
        assert.strictEqual(joined.url, `http://${name}/_benchbar/signin?next=/app`);
        const noSeat = await browse(port, name, "/app");
        assert.ok(noSeat.status === 403 && noSeat.text.includes("has not given you a seat yet"), noSeat.text);

        const seats = run("seats", { id });
        assert.deepStrictEqual([seats.host_assigns, seats.rows.length, seats.rows[1].slice(0, 2)], ["false", 6, ["seat2", "Seat 2"]]);
        const seated = run("seat", { id, seat_id: "seat2" });
        assert.deepStrictEqual([seated.code, seated.state, seated.seat], [0, "ready", "seat2@example.com"]);
        assert.strictEqual(run("seat", { id, seat_id: "nope" }).error, "refused");

        const pageReply = await browse(port, name, "/app/sales-order");
        assert.deepStrictEqual([pageReply.status, pageReply.text], [200, "upstream-ok"]);
        const signin = await browse(port, name, "/_benchbar/signin?next=/app");
        assert.deepStrictEqual([signin.status, signin.headers.location], [302, "/app"]);
        assert.ok(signin.headers["set-cookie"][0].startsWith(`sid=${H.SID};`));
        assert.strictEqual((await browse(port, "evil.example", "/app")).status, 403);
        assert.strictEqual((await browse(port, name, "/app", { "sec-fetch-site": "cross-site" })).status, 403);
        assert.strictEqual(gw.upstream.hits.filter((h) => h.url === "/app").length, 0, "a refused request reached the host");

        const listed = run("joined");
        assert.deepStrictEqual(listed.doc.rooms.map((r) => [r.id, r.room, r.host, r.site, r.state, r.seat, r.forwarding, r.address, r.port, r.host_key]),
            [[id, "Test Room", "Test Host", "macdev", "ready", "seat2@example.com", true, LOOPBACK, gw.port, id]]);
        const known = run("look", { address: LOOPBACK, port: gw.port });
        assert.deepStrictEqual([known.known, known.paired], ["true", "true"]);

        // the secrets: the code, and the body of the key
        const keyFile = path.join(dir, "keys", `${hostHex}.pem`);
        const keyBody = fs.readFileSync(keyFile, "utf8").split("\n")[1];
        const standalone = new RegExp(`(?<![0-9A-Za-z])${code}(?![0-9A-Za-z])`);
        const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(path.join(d, e.name)) : e.isFile() ? [path.join(d, e.name)] : []));
        const argv = execFileSync("/bin/ps", ["-ax", "-o", "args="], { encoding: "utf8" }).split("\n").filter((line) => line.includes(dir));
        assert.ok(argv.some((line) => line.includes("guest-forward.js")), "the forwarder is not running");
        const files = [...walk(dir).filter((f) => f !== keyFile), ...walk(gw.stateDir), ...(fs.existsSync(gw.logDir) ? walk(gw.logDir) : [])];
        const haystacks = [["output", outputs.join("\n")], ["arguments", argv.join("\n")], ["the gateway's output", gw.output()], ...files.map((f) => [path.basename(f), fs.readFileSync(f, "utf8")])];
        for (const [what, text] of haystacks) {
            assert.ok(!standalone.test(text), `${what} holds the room code`);
            assert.ok(!text.includes(keyBody), `${what} holds the key`);
        }
        assert.strictEqual(fs.statSync(path.join(dir, "rooms.json")).mode & 0o777, 0o600);

        // the host removes this computer: the page says so, and the forwarder asks no more
        const [row] = await people(gw);
        await gw.control({ op: "remove", device: row.id });
        assert.strictEqual(run("wait", { id, timeout_s: 0 }).state, "removed");
        assert.ok((await browse(port, name, "/app")).text.includes("removed you from this room"));
        assert.deepStrictEqual([run("look", { address: LOOPBACK, port: gw.port }).paired, run("joined").doc.rooms[0].state], ["false", "removed"]);

        const left = run("forget", { id });
        assert.deepStrictEqual([left.code, left.forgotten, left.told_host], [0, "true", "false"]);
        assert.deepStrictEqual([run("joined").doc.rooms, fs.existsSync(keyFile), fs.existsSync(forward.sockPath(dir, id))], [[], false, false]);
        assert.strictEqual(run("open", { id }).error, "no_such_room");
        await assert.rejects(browse(port, name, "/app"), /ECONNREFUSED/);
    });
});

test("guest-cli: an invite joins without a typed code; leave tells the host; a host with another key at a joined address is refused", async () => {
    await withGateway({ config: { seat_mode: "host" } }, async (gw) => {
        const dir = H.tmpDir();
        const hostHex = gw.host.fp.slice(7);
        const id = hostHex.slice(0, 16);
        H.track(() => forward.ask(dir, id, "stop", 2000));
        const { salt, code } = await gw.control({ op: "code" });
        const link = (over = {}) => inviteLink({ r: "Whatever%20it%20says", h: hostHex, s: salt, c: code, a: `${LOOPBACK}%3A${gw.port}`, ...over });

        assert.strictEqual(cli(dir, "look", { invite: link({ a: "8.8.8.8%3A8443" }) }).error, "invite_no_address");
        assert.strictEqual(cli(dir, "look", { invite: link({ a: null }) }).error, "invite_no_address");
        assert.strictEqual(cli(dir, "look", { invite: link({ h: "ab".repeat(32) }) }).error, "not_the_invited_room");
        assert.strictEqual(cli(dir, "look", { invite: link({ s: "00".repeat(16) }) }).error, "invite_out_of_date");
        const seen = cli(dir, "look", { invite: link() });
        assert.deepStrictEqual([seen.code, seen.room, seen.from_invite, seen.host_key], [0, "Test Room", "true", id]);
        const joined = cli(dir, "join", { invite: link(), address: seen.address, port: Number(seen.port), host_pin: seen.host_pin, name: "Lab PC", model: "Linux" });
        assert.deepStrictEqual([joined.code, joined.state], [0, "waiting"], joined.text);
        assert.ok(!joined.text.includes(code));

        // the host gives out the seats: a pick is refused, the wait ends when the host gave one
        const seats = cli(dir, "seats", { id });
        assert.strictEqual(seats.host_assigns, "true");
        assert.strictEqual(cli(dir, "seat", { id, seat_id: "seat1" }).error, "host_assigns");
        assert.strictEqual(cli(dir, "wait", { id, timeout_s: 0 }).state, "waiting");
        const [row] = await people(gw);
        assert.strictEqual((await gw.control({ op: "assign", device: row.id, seat_id: "seat3" })).ok, true);
        const waited = cli(dir, "wait", { id, timeout_s: 20 });
        assert.deepStrictEqual([waited.state, waited.seat], ["ready", "seat3@example.com"]);

        const left = cli(dir, "leave", { id });
        assert.deepStrictEqual([left.code, left.told_host, left.room], [0, "true", "Test Room"]);
        assert.deepStrictEqual(await people(gw), []);
        assert.deepStrictEqual(cli(dir, "joined").doc.rooms.map((r) => [r.state, r.forwarding, r.url]), [["closed", false, null]]);
        assert.ok(fs.existsSync(path.join(dir, "keys", `${hostHex}.pem`)), "leave deleted the key: a rejoin would be a new guest to the host");

        // another host answers on the address this computer joined: its key is not taken over
        const port = gw.port;
        await gw.stop();
        const other = await startGateway({ config: { listen: { host: LOOPBACK, port } } });
        try {
            const changed = cli(dir, "look", { address: LOOPBACK, port });
            assert.deepStrictEqual([changed.code, changed.error, changed.room], [1, "identity_changed", id]);
            assert.strictEqual(cli(dir, "open", { id }).state, "identity_changed");
            const shown = await browse(Number(cli(dir, "open", { id }).local_port), new URL(cli(dir, "open", { id }).url).host, "/app");
            assert.ok(shown.status === 403 && shown.text.includes("looks different"), shown.text);
            assert.deepStrictEqual(await people(other), []);
        } finally {
            await other.stop();
        }
    });
});

test("several commands at once: a room gets one forwarder, on one port", async () => {
    await withGateway({}, async (gw) => {
        const dir = H.tmpDir();
        const hostHex = gw.host.fp.slice(7);
        const id = hostHex.slice(0, 16);
        H.track(() => forward.ask(dir, id, "stop", 2000));
        const joined = cli(dir, "join", { address: LOOPBACK, port: gw.port, host_pin: hostHex, code: await roomCode(gw), name: "Lab PC", model: "Linux" });
        assert.strictEqual(joined.code, 0, joined.text);
        await forward.ask(dir, id, "stop", 2000);
        while (await forward.ask(dir, id, "status", 200)) await H.sleep(50);

        const request = JSON.stringify({ dir, allow_loopback: true, id });
        const opened = await Promise.all([1, 2, 3, 4, 5, 6].map(() => start([CLI, "open"], request)));
        assert.deepStrictEqual(opened.map((r) => [r.code, r.forwarding]), opened.map(() => [0, "true"]), opened.map((r) => r.text).join(""));
        assert.strictEqual(new Set(opened.map((r) => r.local_port)).size, 1, "the commands were told different ports");
        const running = execFileSync("/bin/ps", ["-ax", "-o", "args="], { encoding: "utf8" }).split("\n").filter((line) => line.includes("guest-forward.js") && line.includes(dir));
        assert.strictEqual(running.length, 1, `${running.length} forwarders run for one room`);
        assert.ok(!fs.existsSync(path.join(dir, `${id}.start`)), "the lock of the start was left behind");
        assert.strictEqual(cli(dir, "forget", { id }).code, 0);
    });
});
