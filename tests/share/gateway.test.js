"use strict";
const test = require("node:test");
const assert = require("node:assert");
const crypto = require("node:crypto");
const fs = require("node:fs");
const https = require("node:https");
const net = require("node:net");
const path = require("node:path");
const tls = require("node:tls");
const H = require("./helpers.js");

const { request, rawTls, startGateway, deviceRow, sleep, sinkAgent, GuestSession, roomCode, SEATS } = H;
const certDir = H.tmpDir();
const certs = {};
const cert = (name) => (certs[name] ||= H.makeCert(certDir, name));

async function withGateway(opts, fn) {
    const gw = await startGateway(opts);
    try {
        await fn(gw);
    } finally {
        await gw.stop();
    }
}

async function until(fn, ms = 2000) {
    const end = Date.now() + ms;
    for (;;) {
        const v = await fn();
        if (v) return v;
        if (Date.now() > end) throw new Error("condition not met in time");
        await sleep(25);
    }
}

const rawReq = (target, { host = "share.localhost:8443", method = "GET", extra = "" } = {}) =>
    `${method} ${target} HTTP/1.1\r\nHost: ${host}\r\n${extra}Connection: close\r\n\r\n`;

const seatless = (c, extra = {}) => deviceRow(c, { seat_id: null, user: null, ...extra });
const people = async (gw) => (await gw.control({ op: "people" })).people;
const status = (gw) => gw.control({ op: "status" });
const AS_JSON = { accept: "application/json" };

// A guest that joins over real TLS from its own address; returns the finished session.
async function joinGuest(gw, c, ip, opts = {}) {
    const s = new GuestSession(gw, c, { ip, ...opts });
    const r = await s.join(await roomCode(gw));
    assert.strictEqual(r.status, 200, r.text);
    return s;
}

// A man in the middle that terminates TLS on both sides and forwards each request's JSON verbatim.
async function startMitm(gw, serverCert, clientCert) {
    const server = https.createServer({ key: serverCert.key, cert: serverCert.cert, minVersion: "TLSv1.3" }, (req, res) => {
        const chunks = [];
        req.on("data", (c) => chunks.push(c));
        req.on("end", async () => {
            const body = Buffer.concat(chunks).toString("utf8");
            const r = await request(gw, { method: req.method, path: req.url, cert: clientCert, ip: "10.30.0.9", body: req.method === "POST" ? body : undefined });
            res.writeHead(r.status, { "Content-Type": "application/json" });
            res.end(r.text);
        });
    });
    await new Promise((r) => server.listen(0, "127.0.0.1", r));
    return { port: server.address().port, close: () => { server.closeAllConnections(); server.close(); } };
}

test("an unknown client certificate gets 403 not_paired, the connection closes, upstream sees nothing", async () => {
    await withGateway({}, async (gw) => {
        const r = await request(gw, { path: "/app", cert: cert("stranger"), headers: { accept: "application/json" } });
        assert.strictEqual(r.status, 403);
        assert.strictEqual(r.json.error, "not_paired");
        await until(() => r.socket.destroyed);
        assert.strictEqual(gw.upstream.hits.length, 0);
    });
});

test("no client certificate: hello answers, a join is refused, and so is everything else", async () => {
    await withGateway({}, async (gw) => {
        const hello = await request(gw, { path: "/room/hello" });
        assert.strictEqual(hello.status, 200);
        const start = await request(gw, { method: "POST", path: "/room/join/start", body: JSON.stringify({ v: 3, name: "x", model: "y", Ya: "0".repeat(64) }) });
        assert.strictEqual(start.status, 403);
        assert.strictEqual(start.json.error, "certificate_required");
        const finish = await request(gw, { method: "POST", path: "/room/join/finish", body: "{}" });
        assert.strictEqual(finish.status, 403);
        const app = await request(gw, { path: "/app" });
        assert.strictEqual(app.status, 403);
        assert.strictEqual(gw.upstream.hits.length, 0);
    });
});

test("a certificate alone is not an identity: a client that holds the certificate but not its key cannot present it", async () => {
    const victim = cert("victim");
    const attacker = cert("attacker");
    await withGateway({ devices: [deviceRow(victim)] }, async (gw) => {
        const attempt = (opts) => new Promise((resolve) => {
            try {
                const s = tls.connect({ host: "127.0.0.1", port: gw.port, rejectUnauthorized: false, minVersion: "TLSv1.3", ...opts }, () => { s.destroy(); resolve("connected"); });
                s.on("error", (e) => resolve(`refused: ${e.code || e.message}`));
            } catch (e) {
                resolve(`refused: ${e.code || e.message}`);
            }
        });
        // Node's own client refuses a certificate whose key does not match, so the forged
        // CertificateVerify never reaches the gateway; OpenSSL on the gateway side checks it too.
        assert.match(await attempt({ cert: victim.cert, key: attacker.key }), /refused/);
        assert.match(await attempt({ cert: victim.cert }), /connected/, "with no key the certificate is simply not sent");
        const r = await request(gw, { path: "/app", cert: undefined });
        assert.strictEqual(r.status, 403);
        assert.strictEqual(gw.upstream.hits.length, 0);
    });
});

test("the TLS exporter with an empty context equals the exporter with no context, on both ends", async () => {
    const host = cert("exporter-host");
    const server = tls.createServer({ key: host.key, cert: host.cert, minVersion: "TLSv1.3" });
    const seen = new Promise((resolve) => server.on("secureConnection", (s) => { resolve([s.exportKeyingMaterial(32, "EXPORTER-bb-join-v3", Buffer.alloc(0)), s.exportKeyingMaterial(32, "EXPORTER-bb-join-v3")]); s.end(); }));
    await new Promise((r) => server.listen(0, "127.0.0.1", r));
    const client = await new Promise((resolve) => {
        const c = tls.connect({ port: server.address().port, host: "127.0.0.1", rejectUnauthorized: false, minVersion: "TLSv1.3" }, () => resolve([c.exportKeyingMaterial(32, "EXPORTER-bb-join-v3", Buffer.alloc(0)), c.exportKeyingMaterial(32, "EXPORTER-bb-join-v3")]));
        c.on("error", () => {});
    });
    const [srvEmpty, srvNone] = await seen;
    server.close();
    assert.deepStrictEqual(client[0], client[1]);
    assert.deepStrictEqual(srvEmpty, srvNone);
    assert.deepStrictEqual(client[0], srvEmpty);
});

test("seatless: only room, seats, seat, hello and leave answer; the proxy and sign-in are refused; 120 s removes it", async () => {
    const c = cert("seatless1");
    await withGateway({ devices: [seatless(c)] }, async (gw) => {
        for (const p of ["/app", "/api/method/ping", "/_benchbar/signin?next=/app"]) {
            const r = await request(gw, { path: p, cert: c, headers: AS_JSON });
            assert.strictEqual(r.status, 403, p);
        }
        assert.deepStrictEqual(gw.helper.calls(), []);
        for (const p of ["/_benchbar/room", "/_benchbar/seats", "/_benchbar/hello"]) assert.strictEqual((await request(gw, { path: p, cert: c })).status, 200, p);
        assert.strictEqual(gw.upstream.hits.length, 0);

        gw.jump(121_000);
        await until(async () => (await people(gw)).length === 0, 2000);
        const gone = await request(gw, { path: "/_benchbar/room", cert: c, headers: AS_JSON });
        assert.strictEqual(gone.status, 403);
        assert.strictEqual(gone.json.error, "not_paired");
    });
});

test("a seated device is not removed at 120 s", async () => {
    const c = cert("seated1");
    await withGateway({ devices: [deviceRow(c)] }, async (gw) => {
        gw.jump(600_000);
        await sleep(400);
        assert.strictEqual((await request(gw, { path: "/app", cert: c })).status, 200);
        assert.strictEqual((await people(gw)).length, 1);
    });
});

test("sign-in: 302 to safeNext with the sid cookie; the user comes from the seat; the sid is recorded nowhere", async () => {
    const c = cert("paired5");
    const row = deviceRow(c, { user: "mapped@example.com", seat_id: "seat2" });
    await withGateway({ devices: [row] }, async (gw) => {
        const r = await request(gw, { path: "/_benchbar/signin?next=/app/home&user=Administrator", cert: c, headers: { "x-user": "Administrator" } });
        assert.strictEqual(r.status, 302);
        assert.strictEqual(r.headers.location, "/app/home");
        const expires = new Date(gw.cfg.deadline_epoch * 1000).toUTCString();
        assert.strictEqual(r.headers["set-cookie"][0], `sid=${H.SID}; Path=/; HttpOnly; SameSite=Lax; Expires=${expires}`);
        assert.deepStrictEqual(gw.helper.calls(), [["share.localhost", "mapped@example.com"]]);

        for (const [next, want] of [["//evil.example", "/app"], ["/api/method/x", "/app"], [undefined, "/app"], ["/app/a%20b?x=1", "/app/a%20b?x=1"]]) {
            const q = next === undefined ? "" : `?next=${encodeURIComponent(next)}`;
            const n = await request(gw, { path: `/_benchbar/signin${q}`, cert: c });
            assert.strictEqual(n.status, 302, String(next));
            assert.strictEqual(n.headers.location, want, String(next));
        }
        assert.strictEqual(gw.upstream.hits.length, 0);
        await until(() => fs.existsSync(gw.logDir));
        for (const f of fs.readdirSync(gw.logDir)) assert.ok(!fs.readFileSync(path.join(gw.logDir, f), "utf8").includes(H.SID));
        assert.ok(!gw.output().includes(H.SID));
        const ctl = JSON.stringify([await status(gw), await gw.control({ op: "people" })]);
        assert.ok(!ctl.includes(H.SID));
    });
});

test("sign-in is refused for strangers and seatless devices; the helper never runs", async () => {
    const nu = cert("nouser");
    await withGateway({ devices: [seatless(nu)] }, async (gw) => {
        for (const c of [cert("stranger2"), nu]) {
            const r = await request(gw, { path: "/_benchbar/signin?next=/app", cert: c });
            assert.strictEqual(r.status, 403);
            assert.ok(!r.headers["set-cookie"]);
        }
        assert.deepStrictEqual(gw.helper.calls(), []);
    });
});

test("sign-in: the 7th in a minute is 429; a helper failure is the friendly 503", async () => {
    const c = cert("paired6");
    const bad = cert("paired7");
    await withGateway({ devices: [deviceRow(c), deviceRow(bad, { user: "failuser", seat_id: "seat2" })] }, async (gw) => {
        for (let i = 0; i < 6; i++) assert.strictEqual((await request(gw, { path: "/_benchbar/signin", cert: c })).status, 302);
        const seventh = await request(gw, { path: "/_benchbar/signin", cert: c });
        assert.strictEqual(seventh.status, 429);
        assert.strictEqual(gw.helper.calls().length, 6);

        const f = await request(gw, { path: "/_benchbar/signin", cert: bad, headers: { accept: "text/html" } });
        assert.strictEqual(f.status, 503);
        assert.match(f.text, /Test Host's bench is restarting, try again in a moment|Test Host&#39;s bench is restarting/);
        assert.ok(!f.text.includes(H.SID) && !f.text.includes("boom"));
    });
});

test("hello: the documented fields, no names, the code never; a new code changes the salt", async () => {
    await withGateway({}, async (gw) => {
        const code = await roomCode(gw);
        const r = await request(gw, { path: "/room/hello", ip: "10.31.0.1" });
        assert.strictEqual(r.status, 200);
        assert.deepStrictEqual(Object.keys(r.json), ["v", "room", "host", "site", "salt", "locked", "full", "people", "seats"]);
        assert.deepStrictEqual([r.json.v, r.json.room, r.json.host, r.json.site, r.json.locked, r.json.full, r.json.people, r.json.seats],
            [3, "Test Room", "Test Host", "macdev", false, false, 0, 6]);
        assert.ok(!r.text.includes(code));
        assert.ok([403, 405].includes((await request(gw, { method: "POST", path: "/room/hello", ip: "10.31.0.1", body: "" })).status));
        await gw.control({ op: "rotate" });
        const again = await request(gw, { path: "/room/hello", ip: "10.31.0.2" });
        assert.notStrictEqual(again.json.salt, r.json.salt);
    });
});

test("hello is 10 per minute per IP, with a real retry_after; another IP is unaffected", async () => {
    await withGateway({}, async (gw) => {
        for (let i = 0; i < 10; i++) assert.strictEqual((await request(gw, { path: "/room/hello", ip: "10.32.0.1" })).status, 200, String(i));
        const limited = await request(gw, { path: "/room/hello", ip: "10.32.0.1" });
        assert.strictEqual(limited.status, 429);
        assert.strictEqual(limited.json.status, "rate_limited");
        assert.ok(limited.json.retry_after >= 1 && limited.json.retry_after <= 60);
        assert.strictEqual((await request(gw, { path: "/room/hello", ip: "10.32.0.2" })).status, 200);
        gw.jump(61_000);
        assert.strictEqual((await request(gw, { path: "/room/hello", ip: "10.32.0.1" })).status, 200);
    });
});

test("join happy path over real TLS: Tb verifies, the device is stored seatless, the proxy stays closed", async () => {
    const c = cert("guest1");
    await withGateway({}, async (gw) => {
        const code = await roomCode(gw);
        assert.match(code, /^[0-9]{6}$/);
        const s = new GuestSession(gw, c, { ip: "10.33.0.1" });
        const start = await s.start(code);
        assert.strictEqual(start.status, 200, start.text);
        assert.match(start.json.request_id, /^j_[0-9a-f]{32}$/);
        assert.match(start.json.Yb, /^[0-9a-f]{64}$/);
        assert.strictEqual(start.json.v, 3);
        const fin = await s.finish();
        assert.strictEqual(fin.status, 200, fin.text);
        assert.deepStrictEqual([fin.json.v, fin.json.status], [3, "joined"]);
        assert.match(fin.json.device_id, /^d_[0-9a-f]{8}$/);
        assert.match(fin.json.Tb, /^[0-9a-f]{128}$/);
        assert.strictEqual(s.tbValid(), true);

        const [row] = await people(gw);
        assert.deepStrictEqual([row.id, row.name, row.model, row.fp, row.user, row.seat_id, row.paired_ip], [fin.json.device_id, "Priya's Mac", "Mac14,2", c.fp, null, null, "10.33.0.1"]);
        assert.strictEqual((await request(gw, { path: "/app", cert: c })).status, 403);
        const room = await request(gw, { path: "/_benchbar/room", cert: c });
        assert.strictEqual(room.status, 200);
        assert.strictEqual(room.json.you, fin.json.device_id);
        assert.strictEqual(gw.upstream.hits.length, 0);
        assert.ok(!fin.text.includes(code) && !start.text.includes(code));
        s.close();
    });
});

test("join: start and finish on different TLS connections still verify (each side uses the finish connection's exporter)", async () => {
    const c = cert("guest-split");
    await withGateway({}, async (gw) => {
        const code = await roomCode(gw);
        const s = new GuestSession(gw, c, { ip: "10.33.1.1" });
        assert.strictEqual((await s.start(code)).status, 200);
        const second = sinkAgent(c);
        const warm = await request(gw, { path: "/room/hello", cert: c, agent: second, ip: "10.33.1.2" });
        assert.notStrictEqual(warm.socket, s.helloReply.socket);
        const fin = await s.finish({ socket: warm.socket, agent: second });
        assert.strictEqual(fin.status, 200, fin.text);
        assert.strictEqual(s.tbValid(), true);
        second.destroy(); s.close();
    });
});

test("a Ta computed over another connection's exporter is wrong_code and charged", async () => {
    const c = cert("guest-exp");
    await withGateway({}, async (gw) => {
        const s = new GuestSession(gw, c, { ip: "10.33.2.1" });
        await s.start(await roomCode(gw));
        const second = sinkAgent(c);
        const warm = await request(gw, { path: "/room/hello", cert: c, agent: second, ip: "10.33.2.2" });
        const fin = await s.finish({ socket: s.helloReply.socket, agent: second });
        assert.strictEqual(fin.status, 403);
        assert.strictEqual(fin.json.status, "wrong_code");
        assert.strictEqual((await status(gw)).budget_left, 9);
        assert.ok(warm);
        second.destroy(); s.close();
    });
});

test("wrong code: 403 wrong_code and the budget drops; ten wrong lock the room; unlock keeps the budget; a new code resets it", async () => {
    await withGateway({}, async (gw) => {
        const wrongCode = async (n) => {
            const s = new GuestSession(gw, cert(`wc${n}`), { ip: `10.34.0.${n}` });
            const code = await roomCode(gw);
            await s.start(code === "000000" ? "111111" : "000000");
            const r = await s.finish();
            s.close();
            return r;
        };
        const first = await wrongCode(1);
        assert.deepStrictEqual([first.status, first.json], [403, { status: "wrong_code" }]);
        assert.strictEqual((await status(gw)).budget_left, 9);
        for (let n = 2; n <= 10; n++) assert.strictEqual((await wrongCode(n)).status, 403);
        let st = await status(gw);
        assert.deepStrictEqual([st.locked, st.lock_reason, st.budget_left], [true, "budget", 0]);
        const locked = await request(gw, { path: "/room/hello", ip: "10.34.1.1" });
        assert.strictEqual(locked.json.locked, true);
        const refused = await new GuestSession(gw, cert("wc-late"), { ip: "10.34.1.2" }).start(await roomCode(gw));
        assert.deepStrictEqual([refused.status, refused.json], [423, { status: "locked" }]);

        assert.strictEqual((await gw.control({ op: "unlock" })).locked, true);
        st = await status(gw);
        assert.deepStrictEqual([st.locked, st.budget_left], [true, 0]);
        await gw.control({ op: "rotate" });
        st = await status(gw);
        assert.deepStrictEqual([st.locked, st.lock_reason, st.budget_left], [false, null, 10]);
        const s = await joinGuest(gw, cert("wc-ok"), "10.34.2.1");
        s.close();
    });
});

test("J1: a spent request id is refused, whether the finish worked or not", async () => {
    await withGateway({}, async (gw) => {
        const s = new GuestSession(gw, cert("j1"), { ip: "10.35.0.1" });
        await s.start(await roomCode(gw));
        assert.strictEqual((await s.finish()).status, 200);
        const again = await s.finish();
        assert.deepStrictEqual([again.status, again.json.status], [404, "unknown_request"]);
        assert.strictEqual((await status(gw)).budget_left, 10);
        s.close();
    });
});

test("J2: finish after a new code or a lock is refused and costs nothing", async () => {
    await withGateway({}, async (gw) => {
        const code = await roomCode(gw);
        const a = new GuestSession(gw, cert("j2a"), { ip: "10.36.0.1" });
        const b = new GuestSession(gw, cert("j2b"), { ip: "10.36.0.2" });
        await a.start(code); await b.start(code);
        await gw.control({ op: "rotate" });
        assert.strictEqual((await a.finish()).status, 404);
        const c = new GuestSession(gw, cert("j2c"), { ip: "10.36.0.3" });
        await c.start(await roomCode(gw));
        await gw.control({ op: "lock" });
        assert.strictEqual((await c.finish()).status, 423);
        await gw.control({ op: "unlock" });
        assert.strictEqual((await b.finish()).status, 404, "unlock does not bring a dropped request back");
        assert.strictEqual((await c.finish()).status, 404);
        assert.strictEqual((await status(gw)).budget_left, 10);
        assert.deepStrictEqual(await people(gw), []);
        for (const s of [a, b, c]) s.close();
    });
});

test("relay: a finish from a different client certificate is 403 wrong_code, charged, and stores nobody", async () => {
    await withGateway({}, async (gw) => {
        const victim = new GuestSession(gw, cert("relay-v"), { ip: "10.37.0.1" });
        await victim.start(await roomCode(gw));
        const other = cert("relay-o");
        const otherAgent = sinkAgent(other);
        const warm = await request(gw, { path: "/room/hello", cert: other, agent: otherAgent, ip: "10.37.0.2" });
        const fin = await victim.finish({ cert: other, agent: otherAgent, socket: warm.socket, ta: victim.tag("guest", H.exporterOf(warm.socket), other.fp) });
        assert.deepStrictEqual([fin.status, fin.json.status], [403, "wrong_code"]);
        assert.strictEqual((await status(gw)).budget_left, 9);
        assert.deepStrictEqual(await people(gw), []);
        otherAgent.destroy(); victim.close();
    });
});

test("TLS relay: a man in the middle that terminates TLS on both sides and forwards the JSON verbatim fails at the host", async () => {
    await withGateway({}, async (gw) => {
        const mitm = await startMitm(gw, cert("mitm-srv"), cert("mitm-cli"));
        try {
            const guest = new GuestSession({ port: mitm.port, control: gw.control }, cert("mitm-guest"), { ip: "10.38.0.1" });
            const start = await guest.start(await roomCode(gw));
            assert.strictEqual(start.status, 200, "the relay reaches the host and the code is right");
            assert.notDeepStrictEqual(guest.fh, H.serverSpkiRaw((await request(gw, { path: "/room/hello", ip: "10.38.0.9" })).socket), "the guest saw the relay's certificate");
            const fin = await guest.finish();
            assert.deepStrictEqual([fin.status, fin.json.status], [403, "wrong_code"]);
            assert.strictEqual((await status(gw)).budget_left, 9);
            assert.deepStrictEqual(await people(gw), []);
            guest.close();
        } finally {
            mitm.close();
        }
    });
});

test("finish after the deadline is refused before the room sees it", async () => {
    await withGateway({ tickMs: 600_000 }, async (gw) => {
        const s = new GuestSession(gw, cert("late-finish"), { ip: "10.36.5.1" });
        await s.start(await roomCode(gw));
        gw.jump(2 * 3600_000);
        const fin = await s.finish();
        assert.deepStrictEqual([fin.status, fin.json], [403, { error: "ended" }]);
        s.close();
    });
});

test("J5: three concurrent finishes with two seats store exactly two people", async () => {
    await withGateway({ config: { seats: SEATS.slice(0, 2) } }, async (gw) => {
        const code = await roomCode(gw);
        const guests = [1, 2, 3].map((n) => new GuestSession(gw, cert(`cap${n}`), { ip: `10.39.0.${n}` }));
        for (const g of guests) assert.strictEqual((await g.start(code)).status, 200);
        const results = await Promise.all(guests.map((g) => g.finish()));
        assert.deepStrictEqual(results.map((r) => r.status).sort(), [200, 200, 409]);
        assert.strictEqual((await people(gw)).length, 2);
        assert.strictEqual((await status(gw)).budget_left, 10);
        const full = await request(gw, { path: "/room/hello", ip: "10.39.1.1" });
        assert.strictEqual(full.json.full, true);
        guests.forEach((g) => g.close());
    });
});

test("J4: near exhaustion, concurrent starts cannot add up to more failures than the budget", async () => {
    await withGateway({}, async (gw) => {
        const wrongFrom = async (n) => {
            const g = new GuestSession(gw, cert(`j4w${n}`), { ip: `10.40.0.${n}` });
            await g.start((await roomCode(gw)) === "000000" ? "111111" : "000000");
            const r = await g.finish();
            g.close();
            return r.status;
        };
        for (let n = 1; n <= 8; n++) assert.strictEqual(await wrongFrom(n), 403);
        const code = await roomCode(gw);
        const guests = [1, 2, 3].map((n) => new GuestSession(gw, cert(`j4s${n}`), { ip: `10.40.1.${n}` }));
        const statuses = await Promise.all(guests.map((g) => g.start(code === "000000" ? "111111" : "000000").then((r) => r.status)));
        assert.deepStrictEqual(statuses.sort(), [200, 200, 423]);
        guests.forEach((g) => g.close());
    });
});

test("a removed person is blocked for the room: start is 403 and costs nothing; a new code does not lift it", async () => {
    await withGateway({}, async (gw) => {
        const c = cert("blockme");
        const s = await joinGuest(gw, c, "10.41.0.1");
        s.close();
        const [row] = await people(gw);
        assert.deepStrictEqual(await gw.control({ op: "remove", device: row.id }), { ok: true, user: null });
        const again = new GuestSession(gw, c, { ip: "10.41.0.2" });
        const r = await again.start(await roomCode(gw));
        assert.deepStrictEqual([r.status, r.json.status], [403, "blocked"]);
        assert.strictEqual((await status(gw)).budget_left, 10);
        await gw.control({ op: "rotate" });
        assert.strictEqual((await again.start(await roomCode(gw))).status, 403);
        const fresh = await joinGuest(gw, cert("blockme-not"), "10.41.0.3");
        fresh.close(); again.close();
    });
});

test("a low-order Ya at start is 400, uncharged, whichever the code", async () => {
    await withGateway({}, async (gw) => {
        const c = cert("loworder");
        const send = (Ya, ip) => request(gw, { method: "POST", path: "/room/join/start", cert: c, ip, body: JSON.stringify({ v: 3, name: "n", model: "m", Ya }) });
        const a = await send("00".repeat(32), "10.42.0.1");
        await gw.control({ op: "rotate" });
        const b = await send("00".repeat(32), "10.42.0.1");
        assert.deepStrictEqual([a.status, b.status, a.text], [400, 400, b.text]);
        assert.strictEqual((await send("01" + "00".repeat(31), "10.42.0.1")).status, 400);
        assert.strictEqual((await status(gw)).budget_left, 10);
    });
});

test("an unfinished start is charged when it expires and raises join_trouble", async () => {
    await withGateway({}, async (gw) => {
        const s = new GuestSession(gw, cert("slowpoke"), { ip: "10.43.0.1" });
        await s.start(await roomCode(gw));
        assert.strictEqual((await status(gw)).join_trouble, false);
        gw.jump(31_000);
        const st = await until(async () => { const x = await status(gw); return x.budget_left === 9 ? x : null; });
        assert.strictEqual(st.join_trouble, true);
        assert.strictEqual((await s.finish()).status, 404);
        assert.strictEqual((await status(gw)).budget_left, 9);
        s.close();
    });
});

test("start limits at the gateway: one in flight per IP, three in total, retry_after is the real wait", async () => {
    await withGateway({}, async (gw) => {
        const code = await roomCode(gw);
        const startFrom = async (n, ip) => {
            const g = new GuestSession(gw, cert(`lim${n}`), { ip });
            const r = await g.start(code);
            g.close();
            return r;
        };
        assert.strictEqual((await startFrom(1, "10.44.0.1")).status, 200);
        gw.jump(10_000);
        const second = await startFrom(2, "10.44.0.1");
        assert.strictEqual(second.status, 429);
        assert.deepStrictEqual([second.json.status, second.json.retry_after >= 19 && second.json.retry_after <= 21], ["rate_limited", true]);
        assert.strictEqual((await startFrom(3, "10.44.0.2")).status, 200);
        assert.strictEqual((await startFrom(4, "10.44.0.3")).status, 200);
        assert.strictEqual((await startFrom(5, "10.44.0.4")).status, 429);
    });
});

test("body limits and schema: 1025 bytes is 413 and closes, an extra key is 400, v:2 is 426", async () => {
    const c = cert("guest6");
    await withGateway({}, async (gw) => {
        const start = (body, ip) => request(gw, { method: "POST", path: "/room/join/start", cert: c, ip, body });
        const big = await start(JSON.stringify({ pad: "x".repeat(1025 - 10) }).padEnd(1025, " "), "10.45.0.1");
        assert.strictEqual(big.status, 413);
        await until(() => big.socket.destroyed);
        const ya = "00".repeat(31) + "09";
        assert.strictEqual((await start(JSON.stringify({ v: 3, name: "n", model: "m", Ya: ya, extra: 1 }), "10.45.0.2")).status, 400);
        const v2 = await start(JSON.stringify({ v: 2, name: "n", model: "m", commit: "0".repeat(64) }), "10.45.0.3");
        assert.strictEqual(v2.status, 426);
        assert.deepStrictEqual(v2.json, { error: "protocol", need: 3 });
        for (const bad of [{ v: 3, name: "", model: "m", Ya: ya }, { v: 3, name: "a".repeat(41), model: "m", Ya: ya }, { v: 3, name: "n", model: "m", Ya: "XYZ" }, [1, 2]]) {
            assert.strictEqual((await start(JSON.stringify(bad), "10.45.0.4")).status, 400, JSON.stringify(bad));
        }
    });
});

test("a body that is slower than 5 s is dropped (408 or close)", { timeout: 15000 }, async () => {
    const c = cert("guest7");
    await withGateway({}, async (gw) => {
        const started = Date.now();
        const r = await rawTls(gw, "POST /room/join/start HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n{", { cert: c, waitMs: 8000 });
        assert.ok(Date.now() - started < 7500);
        assert.ok(r.status === 408 || r.status === 0, `gave ${r.status}`);
    });
});

test("the old pairing routes are gone", async () => {
    const c = cert("oldpair");
    await withGateway({ devices: [deviceRow(c)] }, async (gw) => {
        for (const p of ["/pair/start", "/pair/reveal", "/pair/confirm", "/pair/cancel"]) {
            const r = await request(gw, { method: "POST", path: p, cert: c, body: "{}" });
            assert.ok([403, 404].includes(r.status), `${p} gave ${r.status}`);
        }
        for (const op of ["pending", "approve", "deny"]) assert.strictEqual((await gw.control({ op })).error, "unknown_op", op);
        assert.strictEqual(gw.upstream.hits.length, 0);
    });
});

test("a paired certificate reaches upstream with stripped headers and only the normalised path", async () => {
    const c = cert("paired1");
    await withGateway({ devices: [deviceRow(c)] }, async (gw) => {
        const r = await request(gw, {
            path: "/app/sales%20order/SO%2D1?x=1&y=a%20b", cert: c, headers: {
                "x-forwarded-for": "9.9.9.9", "x-frappe-site-name": "evil.localhost", cookie: "sid=abc; theme=dark; foo=bar", "x-forwarded-host": "z",
                "user-agent": "t"
            }
        });
        assert.strictEqual(r.status, 200);
        assert.strictEqual(r.text, "upstream-ok");
        assert.match(String(r.headers["set-cookie"]), /up=1/);
        assert.strictEqual(gw.upstream.hits.length, 1);
        const hit = gw.upstream.hits[0];
        assert.strictEqual(hit.url, "/app/sales%20order/SO-1?x=1&y=a%20b");
        assert.strictEqual(hit.headers.host, "share.localhost:8443");
        assert.strictEqual(hit.headers["x-forwarded-for"], undefined);
        assert.strictEqual(hit.headers["x-forwarded-host"], undefined);
        assert.strictEqual(hit.headers["x-frappe-site-name"], undefined);
        assert.strictEqual(hit.headers.cookie, "sid=abc");
        assert.strictEqual(hit.headers["user-agent"], "t");
    });
});

test("a POST body is streamed to upstream and a body over max_body_mb is 413", async () => {
    const c = cert("paired2");
    await withGateway({ devices: [deviceRow(c)] }, async (gw) => {
        const ok = await request(gw, { method: "POST", path: "/api/method/ping", cert: c, body: "hello", headers: { "content-type": "text/plain" } });
        assert.strictEqual(ok.status, 200);
        assert.strictEqual(gw.upstream.hits[0].body.toString(), "hello");
        const before = gw.upstream.hits.length;
        const big = await request(gw, { method: "POST", path: "/api/method/ping", cert: c, body: "x".repeat(1024 * 1024 + 1) }).catch((e) => ({ status: 0, err: e }));
        assert.ok(big.status === 413 || big.status === 0, `big gave ${big.status}`);
        assert.strictEqual(gw.upstream.hits.length, before);
    });
});

test("every bypass attempt is 400, 403 or 404 and upstream records zero hits", async () => {
    const c = cert("paired3");
    await withGateway({ devices: [deviceRow(c)] }, async (gw) => {
        const cases = [
            ["/%63onsole"], ["/console"], ["/%2e%2e/"], ["//"], ["/\\console"], ["/%00"], ["/app%00"], ["/%252f"], ["/console;x"],
            ["http://127.0.0.1:8000/app"], ["/app?__debugger__=yes"], ["/app?%5f%5fdebugger%5f%5f=yes"],
            ["/socket.io/?EIO=4&transport=polling"], ["/SOCKET.IO/"], ["/%73ocket.io/"], ["/app", { host: "127.0.0.1:8000" }],
            ["/app", { host: "share.localhost:8443", extra: "Host: other.localhost\r\n" }],
            ["/app", { extra: "Sec-Fetch-Site: cross-site\r\n" }], ["/app", { extra: "Origin: http://evil.example\r\n" }],
            ["/app", { host: "evil.example" }], ["/api/resource"], ["/private/files"], ["/_benchbar/nope"], ["/" + "a".repeat(3000)],
            ["/app", { extra: `X-Big: ${"b".repeat(20000)}\r\n` }]
        ];
        for (const [target, opts] of cases) {
            const r = await rawTls(gw, rawReq(target, opts), { cert: c });
            assert.ok([400, 403, 404].includes(r.status), `${target.slice(0, 40)} ${JSON.stringify(opts || {}).slice(0, 40)} gave ${r.status}`);
        }
        assert.strictEqual(gw.upstream.hits.length, 0);
    });
});

test("socket.io, including a WebSocket upgrade, is 404 and reaches nothing", async () => {
    const c = cert("paired4");
    await withGateway({ devices: [deviceRow(c)] }, async (gw) => {
        const poll = await request(gw, { path: "/socket.io/?EIO=4&transport=polling", cert: c });
        assert.strictEqual(poll.status, 404);
        const ws = await rawTls(gw, "GET /socket.io/?EIO=4&transport=websocket HTTP/1.1\r\nHost: share.localhost:8443\r\nUpgrade: websocket\r\n" +
            "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n", { cert: c });
        assert.strictEqual(ws.status, 404);
        const ws2 = await rawTls(gw, "GET /app HTTP/1.1\r\nHost: share.localhost:8443\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n", { cert: c });
        assert.strictEqual(ws2.status, 404);
        assert.strictEqual(gw.upstream.hits.length, 0);
    });
});

test("a client that sends no ClientHello within 5 s is closed", { timeout: 15000 }, async () => {
    await withGateway({}, async (gw) => {
        const started = Date.now();
        await new Promise((resolve, reject) => {
            const s = net.connect(gw.port, "127.0.0.1");
            s.on("close", resolve);
            s.on("error", () => {});
            setTimeout(() => { s.destroy(); reject(new Error("not closed within 8 s")); }, 8000);
        });
        const took = Date.now() - started;
        assert.ok(took >= 4000 && took < 7000, `closed after ${took} ms`);
    });
});

test("the 5th unpaired connection from one IP is refused; a slot frees when one closes", async () => {
    await withGateway({}, async (gw) => {
        const open = () => new Promise((resolve) => {
            const s = tls.connect({ host: "127.0.0.1", port: gw.port, rejectUnauthorized: false, minVersion: "TLSv1.3" });
            s.on("secureConnect", () => resolve({ ok: true, s }));
            s.on("error", () => resolve({ ok: false, s }));
            s.on("close", () => resolve({ ok: false, s }));
        });
        const held = [];
        for (let i = 0; i < 4; i++) {
            const r = await open();
            assert.strictEqual(r.ok, true, `connection ${i + 1}`);
            held.push(r.s);
        }
        const fifth = await open();
        assert.strictEqual(fifth.ok, false);
        held[0].destroy();
        await until(async () => { const r = await open(); if (r.ok) r.s.destroy(); return r.ok; }, 2000);
        held.forEach((s) => s.destroy());
    });
});

test("session resumption is not offered", async () => {
    const c = cert("g14");
    await withGateway({ devices: [deviceRow(c)] }, async (gw) => {
        const connect = (session) => new Promise((resolve, reject) => {
            const s = tls.connect({ host: "127.0.0.1", port: gw.port, rejectUnauthorized: false, key: c.key, cert: c.cert, minVersion: "TLSv1.3", session });
            let ticket = null;
            let reused = null;
            s.on("session", (t) => (ticket = t));
            s.on("secureConnect", () => {
                reused = s.isSessionReused();
                s.write("GET /_benchbar/hello HTTP/1.1\r\nHost: share.localhost:8443\r\nConnection: close\r\n\r\n");
            });
            s.on("data", () => {});
            s.on("close", () => resolve({ ticket, reused }));
            s.on("error", reject);
        });
        const first = await connect();
        const second = await connect(first.ticket || undefined);
        assert.strictEqual(second.reused, false);
    });
});

test("TLS 1.2 is refused and the ALPN is http/1.1", async () => {
    await withGateway({}, async (gw) => {
        const old = await new Promise((resolve) => {
            const s = tls.connect({ host: "127.0.0.1", port: gw.port, rejectUnauthorized: false, maxVersion: "TLSv1.2" });
            s.on("secureConnect", () => resolve("connected"));
            s.on("error", () => resolve("refused"));
        });
        assert.strictEqual(old, "refused");
        const proto = await new Promise((resolve) => {
            const s = tls.connect({ host: "127.0.0.1", port: gw.port, rejectUnauthorized: false, ALPNProtocols: ["http/1.1", "h2"] }, () => {
                resolve(s.alpnProtocol);
                s.destroy();
            });
            s.on("error", () => resolve(null));
        });
        assert.strictEqual(proto, "http/1.1");
    });
});

test("seats: the list has ids, names, roles and holders and no email; the roster shows people and seats", async () => {
    const a = cert("seat-a");
    const b = cert("seat-b");
    await withGateway({ devices: [seatless(a, { name: "Asha" }), deviceRow(b, { name: "Ben", seat_id: "seat3", user: "seat3@example.com" })] }, async (gw) => {
        const seats = await request(gw, { path: "/_benchbar/seats", cert: a });
        assert.strictEqual(seats.status, 200);
        assert.ok(Array.isArray(seats.json));
        assert.deepStrictEqual(seats.json[2], { seat_id: "seat3", full_name: "Seat 3", roles: ["Sales User"], taken_by: "Ben" });
        assert.deepStrictEqual(seats.json[0], { seat_id: "seat1", full_name: "Seat 1", roles: ["Sales User"], taken_by: null });
        assert.ok(!seats.text.includes("@"));
        const room = await request(gw, { path: "/_benchbar/room", cert: a });
        assert.strictEqual(room.status, 200);
        assert.deepStrictEqual(Object.keys(room.json), ["room", "host", "site", "deadline_epoch", "you", "people"]);
        assert.deepStrictEqual(room.json.people.map((p) => [p.name, p.seat]), [["Asha", null], ["Ben", "Seat 3"]]);
        assert.ok(!room.text.includes("@"));
        assert.strictEqual(room.json.deadline_epoch, gw.cfg.deadline_epoch);
        assert.strictEqual((await request(gw, { path: "/_benchbar/seats", cert: cert("nobody") })).status, 403);
    });
});

test("take a seat, switch (the old user is wiped, canonical user only), a held seat is 409, an unknown id 404; no email crosses the wire", async () => {
    const a = cert("take-a");
    const b = cert("take-b");
    await withGateway({ devices: [seatless(a), seatless(b)] }, async (gw) => {
        const pick = (c, seat_id, headers = AS_JSON) => request(gw, { method: "POST", path: "/_benchbar/seat", cert: c, headers, body: JSON.stringify({ seat_id }) });
        const first = await pick(a, "seat2");
        assert.deepStrictEqual([first.status, first.json], [200, { ok: true, seat_id: "seat2", full_name: "Seat 2" }]);
        assert.deepStrictEqual(gw.helper.calls(), [], "no wipe on a first seat");
        assert.strictEqual((await request(gw, { path: "/app", cert: a })).status, 200, "a seat opens the proxy");
        const si = await request(gw, { path: "/_benchbar/signin?next=/app", cert: a });
        assert.strictEqual(si.status, 302);
        assert.deepStrictEqual(gw.helper.calls(), [["share.localhost", "seat2@example.com"]]);

        const held = await pick(b, "seat2");
        assert.deepStrictEqual([held.status, held.json.status], [409, "seat_taken"]);
        assert.strictEqual((await pick(b, "nope")).status, 404);
        assert.strictEqual((await pick(b, "SEAT3")).status, 404);

        const switched = await pick(a, "seat4");
        assert.strictEqual(switched.status, 200);
        assert.deepStrictEqual(gw.helper.calls()[1], ["wipe", "share.localhost", "seat2@example.com"]);
        assert.strictEqual((await pick(b, "seat2")).status, 200, "the released seat is free");

        const html = await pick(a, "seat5", { accept: "text/html" });
        assert.strictEqual(html.status, 302);
        assert.strictEqual(html.headers.location, "/_benchbar/signin?next=/app");
        const wire = JSON.stringify([first.json, held.json, switched.json, html.text]) + (await request(gw, { path: "/_benchbar/seats", cert: a })).text;
        assert.ok(!wire.includes("@"));
        for (const bad of ['{"seat_id":5}', '{"seat_id":"seat1","x":1}', "{}", "[]"]) {
            assert.strictEqual((await request(gw, { method: "POST", path: "/_benchbar/seat", cert: a, body: bad })).status, 400, bad);
        }
    });
});

test("a failed wipe moves nothing: the device keeps its seat and gets the friendly 503", async () => {
    const c = cert("wipefail");
    await withGateway({ devices: [deviceRow(c, { user: "wipefail@example.com", seat_id: "seat5" })] }, async (gw) => {
        const r = await request(gw, { method: "POST", path: "/_benchbar/seat", cert: c, body: JSON.stringify({ seat_id: "seat6" }) });
        assert.strictEqual(r.status, 503);
        assert.strictEqual((await people(gw))[0].seat_id, "seat5");
    });
});

test("seat changes are 6 a minute per device", async () => {
    const c = cert("seatrate");
    await withGateway({ devices: [seatless(c)] }, async (gw) => {
        for (let i = 0; i < 6; i++) {
            const r = await request(gw, { method: "POST", path: "/_benchbar/seat", cert: c, body: JSON.stringify({ seat_id: `seat${(i % 2) + 1}` }) });
            assert.strictEqual(r.status, 200, String(i));
        }
        const seventh = await request(gw, { method: "POST", path: "/_benchbar/seat", cert: c, body: JSON.stringify({ seat_id: "seat3" }) });
        assert.strictEqual(seventh.status, 429);
    });
});

test("a cross-site seat, leave or removal request is refused and the device survives", async () => {
    const c = cert("xs1");
    const row = deviceRow(c);
    await withGateway({ devices: [row] }, async (gw) => {
        for (const headers of [{ "sec-fetch-site": "cross-site" }, { origin: "http://evil.example" }]) {
            const leave = await request(gw, { method: "POST", path: "/_benchbar/leave", cert: c, body: "", headers });
            assert.strictEqual(leave.status, 403, JSON.stringify(headers));
            const seat = await request(gw, { method: "POST", path: "/_benchbar/seat", cert: c, headers, body: JSON.stringify({ seat_id: "seat2" }) });
            assert.strictEqual(seat.status, 403, JSON.stringify(headers));
        }
        const bad = await request(gw, { method: "POST", path: "/_benchbar/leave", cert: c, body: "", headers: { origin: "http://share.localhost:8443", host: "evil.example" } });
        assert.strictEqual(bad.status, 400);
        const [only] = await people(gw);
        assert.deepStrictEqual([only.id, only.seat_id], [row.id, "seat1"]);
        assert.strictEqual((await request(gw, { method: "POST", path: "/_benchbar/leave", cert: c, body: "" })).status, 200);
    });
});

test("remove destroys keep-alive sockets within 1 s; the reply carries the user and no sid; it is unknown the second time", async () => {
    const c = cert("g15");
    const row = deviceRow(c, { user: "seat3@example.com", seat_id: "seat3" });
    await withGateway({ devices: [row] }, async (gw) => {
        const agent = sinkAgent(c);
        const first = await request(gw, { path: "/app", cert: c, agent });
        assert.strictEqual(first.status, 200);
        assert.strictEqual(first.socket.destroyed, false, "kept alive");
        const reply = await gw.control({ op: "remove", device: row.id });
        assert.deepStrictEqual(reply, { ok: true, user: "seat3@example.com" });
        await until(() => first.socket.destroyed, 1000);
        const hitsBefore = gw.upstream.hits.length;
        const next = await request(gw, { path: "/app", cert: c, agent });
        assert.strictEqual(next.status, 403);
        assert.strictEqual(gw.upstream.hits.length, hitsBefore);
        agent.destroy();
        assert.deepStrictEqual(await gw.control({ op: "remove", device: row.id }), { ok: false, error: "not_found" });
        assert.deepStrictEqual(await gw.control({ op: "revoke", device: row.id }), { ok: false, error: "not_found" });
    });
});

test("a device removed without closing its socket is still refused on the very next request (per-request lookup)", async () => {
    const c = cert("g16");
    const row = deviceRow(c);
    await withGateway({ devices: [row] }, async (gw) => {
        const agent = sinkAgent(c);
        assert.strictEqual((await request(gw, { path: "/app", cert: c, agent })).status, 200);
        H.writeDevices(gw.devicesFile, []);
        const r = await request(gw, { path: "/app", cert: c, agent });
        assert.strictEqual(r.status, 403);
        agent.destroy();
    });
});

test("leave removes the device, wipes its seat's sessions, and its next request is not_paired", async () => {
    const c = cert("g17");
    const row = deviceRow(c, { user: "seat4@example.com", seat_id: "seat4" });
    await withGateway({ devices: [row] }, async (gw) => {
        const r = await request(gw, { method: "POST", path: "/_benchbar/leave", cert: c, body: "" });
        assert.strictEqual(r.status, 200);
        assert.deepStrictEqual(await people(gw), []);
        await until(() => gw.helper.calls().length === 1);
        assert.deepStrictEqual(gw.helper.calls(), [["wipe", "share.localhost", "seat4@example.com"]]);
        const next = await request(gw, { path: "/app", cert: c, headers: AS_JSON });
        assert.strictEqual(next.status, 403);
        assert.strictEqual(next.json.error, "not_paired");
    });
});

test("device hello answers a device only, and carries the documented fields", async () => {
    const c = cert("g18");
    const row = deviceRow(c, { user: "seat1@example.com" });
    await withGateway({ devices: [row] }, async (gw) => {
        const r = await request(gw, { path: "/_benchbar/hello", cert: c });
        assert.strictEqual(r.status, 200);
        assert.deepStrictEqual(r.json, {
            ok: true, protocol: 3, device: row.id, user_label: "seat1@example.com", deadline_epoch: gw.cfg.deadline_epoch,
            label: "Test Host", site_label: "macdev", copy_made: "2026-11-02T09:00:00.000Z"
        });
        assert.strictEqual((await request(gw, { path: "/_benchbar/hello", cert: cert("stranger3") })).status, 403);
        assert.strictEqual((await request(gw, { method: "POST", path: "/_benchbar/hello", cert: c, body: "" })).status, 405);
    });
});

test("the control socket is 0600; status, code, lock, unlock, rotate, people, assign and remove behave; unknown ops are refused", async () => {
    const c = cert("g19");
    const row = deviceRow(c, { user: "seat1@example.com" });
    await withGateway({ devices: [row] }, async (gw) => {
        assert.strictEqual(fs.statSync(gw.cfg.control_sock).mode & 0o777, 0o600);
        const agent = sinkAgent(c);
        await request(gw, { path: "/app", cert: c, agent });
        const st = await status(gw);
        assert.strictEqual(st.ok, true);
        assert.strictEqual(st.deadline_epoch, gw.cfg.deadline_epoch);
        assert.deepStrictEqual(st.online, [row.id]);
        assert.deepStrictEqual([st.locked, st.lock_reason, st.budget_left, st.seats, st.people, st.join_trouble], [false, null, 10, 6, 1, false]);
        assert.ok(st.conns >= 1);
        assert.strictEqual(st.web_up, true);
        agent.destroy();

        const code = await gw.control({ op: "code" });
        assert.deepStrictEqual(Object.keys(code), ["ok", "code"]);
        assert.match(code.code, /^[0-9]{6}$/);
        assert.deepStrictEqual(await gw.control({ op: "lock" }), { ok: true });
        const locked = await status(gw);
        assert.deepStrictEqual([locked.locked, locked.lock_reason], [true, "host"]);
        assert.deepStrictEqual(await gw.control({ op: "unlock" }), { ok: true, locked: false, lock_reason: null });
        const rotated = await gw.control({ op: "rotate" });
        assert.deepStrictEqual([rotated.ok, rotated.budget_left], [true, 10]);
        assert.ok(!JSON.stringify(rotated).includes((await gw.control({ op: "code" })).code));

        const list = await gw.control({ op: "people" });
        assert.strictEqual(list.people.length, 1);
        assert.deepStrictEqual([list.people[0].id, list.people[0].full_name, list.people[0].online], [row.id, "Seat 1", false]);
        assert.deepStrictEqual((await gw.control({ op: "devices" })).people, list.people, "devices is an alias of people");

        const other = deviceRow(cert("g19b"), { seat_id: "seat2", user: "seat2@example.com" });
        H.writeDevices(gw.devicesFile, [row, other]);
        assert.strictEqual((await gw.control({ op: "assign", device: other.id, seat_id: "seat1" })).error, "seat_taken");
        assert.strictEqual((await gw.control({ op: "assign", device: other.id, seat_id: "ghost" })).error, "no_such_seat");
        assert.strictEqual((await gw.control({ op: "assign", device: "d_00000099", seat_id: "seat3" })).error, "not_found");
        assert.deepStrictEqual(await gw.control({ op: "assign", device: other.id, seat_id: "seat3" }), { ok: true });
        assert.deepStrictEqual(gw.helper.calls()[0], ["wipe", "share.localhost", "seat2@example.com"]);
        assert.strictEqual((await gw.control({ op: "assign", device: "bad", seat_id: "seat3" })).error, "bad_request");
        assert.strictEqual((await gw.control({ op: "frobnicate" })).error, "unknown_op");
        assert.strictEqual((await gw.control({ nothing: 1 })).ok, false);
    });
});

test("the room code is in no file, no log, no helper argument, no control reply but `code`, and no output", async () => {
    await withGateway({}, async (gw) => {
        const replies = [];
        const a = cert("hyg-a");
        const s = await joinGuest(gw, a, "10.50.0.1");
        const code = await roomCode(gw);
        const wrongGuest = new GuestSession(gw, cert("hyg-b"), { ip: "10.50.0.2" });
        await wrongGuest.start(code === "000000" ? "111111" : "000000");
        const wrongFinish = await wrongGuest.finish();
        const [row] = await people(gw);
        replies.push(wrongFinish.text, s.finishReply.text, s.startReply.text, s.helloReply.text);
        const pick = await request(gw, { method: "POST", path: "/_benchbar/seat", cert: a, body: JSON.stringify({ seat_id: "seat2" }) });
        replies.push(pick.text);
        replies.push((await request(gw, { path: "/_benchbar/signin?next=/app/x", cert: a })).text);
        replies.push((await request(gw, { path: "/app/sales-order/SO-9", cert: a })).text);
        replies.push((await request(gw, { path: "/_benchbar/room", cert: a })).text, (await request(gw, { path: "/_benchbar/seats", cert: a })).text);
        for (const op of [{ op: "status" }, { op: "people" }, { op: "lock" }, { op: "unlock" }, { op: "extend", seconds: 10 }, { op: "rotate" }, { op: "remove", device: row.id }, { op: "nope" }]) {
            replies.push(JSON.stringify(await gw.control(op)));
        }
        replies.push(JSON.stringify(await gw.control({ op: "remove", device: "d_00000001" })));
        const rotatedCode = await roomCode(gw);

        const standalone = (c) => new RegExp(`(?<![0-9A-Za-z])${c}(?![0-9A-Za-z])`);
        const walk = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(path.join(dir, e.name)) : [path.join(dir, e.name)]));
        const files = [...walk(gw.stateDir), ...(fs.existsSync(gw.logDir) ? walk(gw.logDir) : []), gw.cfgFile];
        assert.ok(files.length > 1);
        const haystacks = files.map((f) => [path.basename(f), fs.readFileSync(f, "utf8")]);
        haystacks.push(["output", gw.output()], ["helper argv", JSON.stringify(gw.helper.calls())], ["replies", replies.join("\n")]);
        for (const [name, text] of haystacks) {
            for (const c of [code, rotatedCode]) assert.ok(!standalone(c).test(text), `${name} holds a room code`);
        }
        assert.ok(!replies.join("\n").includes(H.SID));
        s.close(); wrongGuest.close();
    });
});

test("gateway.js ignores NODE_ENV=test and x-test-peer-ip: the limiter sees the real address", async () => {
    await withGateway({ production: true }, async (gw) => {
        const code = await roomCode(gw);
        assert.strictEqual((await new GuestSession(gw, cert("prod1"), { ip: "10.8.0.1" }).start(code)).status, 200);
        const second = await new GuestSession(gw, cert("prod2"), { ip: "10.8.0.2" }).start(code);
        assert.strictEqual(second.status, 429, "a forged address evaded the per-IP limit");
        gw.jump(2 * 3600_000);
        await sleep(300);
        assert.strictEqual((await status(gw)).ok, true, "the clock file was honoured");
    });
});

test("devices.json is emptied when the gateway starts and when it stops", async () => {
    const c = cert("empties");
    const gw = await startGateway({ devices: [deviceRow(c)], blocked: ["sha256:" + "ab".repeat(32)] });
    try {
        assert.strictEqual(JSON.parse(fs.readFileSync(gw.devicesFile, "utf8")).devices.length, 1);
        await gw.control({ op: "stop" });
        await gw.exited;
        assert.deepStrictEqual(JSON.parse(fs.readFileSync(gw.devicesFile, "utf8")), { v: 3, devices: [], blocked: [] });
    } finally {
        await gw.stop();
    }
});

test("a deadline 2 s ahead exits 0 within 3 s and closes every socket", { timeout: 15000 }, async () => {
    const c = cert("g20");
    const nowS = Math.floor(Date.now() / 1000);
    const gw = await startGateway({ devices: [deviceRow(c)], config: { deadline_epoch: nowS + 3 } });
    try {
        const agent = sinkAgent(c);
        const first = await request(gw, { path: "/app", cert: c, agent });
        assert.strictEqual(first.status, 200);
        const exit = await Promise.race([gw.exited, sleep(5000).then(() => "timeout")]);
        assert.deepStrictEqual(exit, { code: 0, signal: null });
        assert.strictEqual(first.socket.destroyed, true);
        agent.destroy();
    } finally {
        await gw.stop();
    }
});

test("with the clock jumped past the deadline the next request is refused before any timer fires", async () => {
    const c = cert("g21");
    await withGateway({ devices: [deviceRow(c)], tickMs: 600_000 }, async (gw) => {
        assert.strictEqual((await request(gw, { path: "/app", cert: c })).status, 200);
        gw.jump(2 * 3600_000);
        const hits = gw.upstream.hits.length;
        const r = await request(gw, { path: "/app", cert: c, headers: { accept: "text/html" } });
        assert.strictEqual(r.status, 403);
        assert.match(r.text, /Sharing has ended/);
        assert.strictEqual(gw.upstream.hits.length, hits);
        const exit = await Promise.race([gw.exited, sleep(3000).then(() => "timeout")]);
        assert.deepStrictEqual(exit, { code: 0, signal: null });
    });
});

test("a config with no deadline, a past deadline, a deadline beyond the cap, bad seats, or no file exits 78", { timeout: 40000 }, async () => {
    const nowS = Math.floor(Date.now() / 1000);
    const seat = (n) => ({ seat_id: `s${n}`, user: `u${n}@example.com`, full_name: `U${n}`, roles: [] });
    const cases = [
        { omit: ["deadline_epoch"] },
        { config: { deadline_epoch: nowS - 5 } },
        { config: { deadline_epoch: nowS - 10 + 43200 + 1 } },
        { config: { deadline_epoch: "soon" } },
        { config: { v: 2 } },
        { config: { protocol: 2 } },
        { config: { unexpected: true } },
        { config: { listen: { host: "0.0.0.0", port: 99999 } } },
        { omit: ["signin_helper"] },
        { omit: ["seats"] },
        { omit: ["room_label"] },
        { config: { seats: [] } },
        { config: { seats: [seat(1), { ...seat(2), seat_id: "s1" }] } },
        { config: { seats: [seat(1), { ...seat(2), user: "U1@example.com" }] } },
        { config: { seats: [{ ...seat(1), seat_id: "has space" }] } },
        { config: { seats: [{ ...seat(1), extra: 1 }] } },
        { config: { seats: [{ ...seat(1), roles: "Sales User" }] } },
        { config: { max_total_s: 99999, deadline_epoch: nowS + 60 } }
    ];
    for (const c of cases) {
        const gw = await startGateway({ ...c, expectExit: true });
        const exit = await Promise.race([gw.exited, sleep(5000).then(() => "timeout")]);
        assert.strictEqual(exit.code, 78, `${JSON.stringify(c)} gave ${JSON.stringify(exit)} ${gw.output()}`);
        await gw.stop();
    }
    const { spawnSync } = require("node:child_process");
    const GATEWAY = path.join(__dirname, "../../lib/frappe-local/share/gateway.js");
    assert.strictEqual(spawnSync(process.execPath, [GATEWAY, "/nonexistent/gateway.json"]).status, 78);
    assert.strictEqual(spawnSync(process.execPath, [GATEWAY]).status, 78);
});

test("extend moves the deadline, clamps at started + max_total_s, never lowers, and the file is valid JSON at every instant", async () => {
    await withGateway({}, async (gw) => {
        const cap = gw.cfg.started_epoch + gw.cfg.max_total_s;
        let stop = false;
        let bad = 0;
        let reads = 0;
        const reader = (async () => {
            while (!stop) {
                try { const j = JSON.parse(fs.readFileSync(gw.cfgFile, "utf8")); if (!Number.isInteger(j.deadline_epoch)) bad++; reads++; } catch { bad++; }
                await new Promise((r) => setImmediate(r));
            }
        })();
        const r1 = await gw.control({ op: "extend", seconds: 100 });
        assert.deepStrictEqual([r1.ok, r1.deadline_epoch], [true, gw.cfg.deadline_epoch + 100]);
        assert.strictEqual(JSON.parse(fs.readFileSync(gw.cfgFile, "utf8")).deadline_epoch, gw.cfg.deadline_epoch + 100);
        assert.strictEqual(fs.statSync(gw.cfgFile).mode & 0o777, 0o600);
        for (let i = 0; i < 20; i++) await gw.control({ op: "extend", seconds: 1 });
        const clamped = await gw.control({ op: "extend", seconds: 86400 });
        assert.strictEqual(clamped.deadline_epoch, cap);
        assert.strictEqual(clamped.capped, true);
        const again = await gw.control({ op: "extend", seconds: 5 });
        assert.strictEqual(again.deadline_epoch, cap);
        for (const seconds of [0, -5, 1.5, "10", null]) assert.strictEqual((await gw.control({ op: "extend", seconds })).ok, false, String(seconds));
        assert.strictEqual((await gw.control({ op: "status" })).deadline_epoch, cap);
        stop = true;
        await reader;
        assert.ok(reads > 5);
        assert.strictEqual(bad, 0, "the config file was unreadable at some instant");
        assert.deepStrictEqual(fs.readdirSync(path.dirname(gw.cfgFile)).filter((f) => f.includes("tmp")), []);
    });
});

test("stop replies, closes every connection and exits 0", async () => {
    const c = cert("g22");
    const gw = await startGateway({ devices: [deviceRow(c)] });
    try {
        const agent = sinkAgent(c);
        const first = await request(gw, { path: "/app", cert: c, agent });
        const reply = await gw.control({ op: "stop" });
        assert.deepStrictEqual(reply, { ok: true });
        assert.deepStrictEqual(await gw.exited, { code: 0, signal: null });
        assert.strictEqual(first.socket.destroyed, true);
        assert.ok(!fs.existsSync(gw.cfg.control_sock));
        agent.destroy();
    } finally {
        await gw.stop();
    }
});

test("friendly pages: exact copy and no script for text/html, JSON otherwise", async () => {
    const c = cert("g23");
    await withGateway({ devices: [deviceRow(c)] }, async (gw) => {
        const html = { accept: "text/html" };
        const forbidden = await request(gw, { path: "/console", cert: c, headers: html });
        assert.strictEqual(forbidden.status, 403);
        assert.match(forbidden.headers["content-type"], /text\/html/);
        assert.ok(forbidden.text.includes("This page isn't available through sharing"));
        assert.ok(!/<script/i.test(forbidden.text));
        const json = await request(gw, { path: "/console", cert: c, headers: { accept: "application/json" } });
        assert.strictEqual(json.status, 403);
        assert.match(json.headers["content-type"], /application\/json/);

        const np = await request(gw, { path: "/app", cert: cert("stranger4"), headers: html });
        assert.strictEqual(np.status, 403);
        assert.ok(np.text.includes("Test Host removed this Mac"));
        assert.ok(!/<script/i.test(np.text));

        await gw.upstream.close();
        const down = await request(gw, { path: "/app", cert: c, headers: html });
        assert.strictEqual(down.status, 503);
        assert.ok(down.text.includes("bench is restarting, try again in a moment"));
        assert.ok(!/<script/i.test(down.text));
        const downJson = await request(gw, { path: "/app", cert: c, headers: { accept: "application/json" } });
        assert.strictEqual(downJson.status, 503);
        assert.deepStrictEqual(downJson.json, { error: "upstream" });
        assert.strictEqual((await gw.control({ op: "status" })).web_up, false);
    });
});

test("the activity log keeps two path segments, nothing from the query, no names, no cookie; the file is 0600", async () => {
    const c = cert("g24");
    await withGateway({ devices: [deviceRow(c, { user: "seat1@example.com" })] }, async (gw) => {
        const r = await request(gw, { path: "/app/sales-order/SO-1?x=secret", cert: c, headers: { cookie: "sid=cookievalue123" } });
        assert.strictEqual(r.status, 200);
        const file = await until(() => fs.existsSync(gw.logDir) && fs.readdirSync(gw.logDir).find((f) => f.startsWith("activity-")));
        const full = path.join(gw.logDir, file);
        await until(() => fs.readFileSync(full, "utf8").includes("/app/sales-order"));
        const text = fs.readFileSync(full, "utf8");
        assert.strictEqual(fs.statSync(full).mode & 0o777, 0o600);
        for (const banned of ["secret", "SO-1", "cookievalue123", "x="]) assert.ok(!text.includes(banned), banned);
        const line = JSON.parse(text.trim().split("\n")[0]);
        assert.deepStrictEqual([line.user, line.method, line.path, line.status], ["seat1@example.com", "GET", "/app/sales-order", 200]);
    });
});

test("a control op after the deadline (sleep/wake) is refused and the gateway exits 0; extend cannot revive it", async () => {
    await withGateway({ tickMs: 600_000 }, async (gw) => {
        gw.jump(2 * 3600_000);
        const reply = await gw.control({ op: "extend", seconds: 3600 }).catch(() => ({ ok: false }));
        assert.notStrictEqual(reply.ok, true);
        const exit = await Promise.race([gw.exited, sleep(3000).then(() => "timeout")]);
        assert.deepStrictEqual(exit, { code: 0, signal: null });
        assert.strictEqual(JSON.parse(fs.readFileSync(gw.cfgFile, "utf8")).deadline_epoch, gw.cfg.deadline_epoch);
    });
});

