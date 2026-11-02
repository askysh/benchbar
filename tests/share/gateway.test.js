"use strict";
const test = require("node:test");
const assert = require("node:assert");
const crypto = require("node:crypto");
const fs = require("node:fs");
const https = require("node:https");
const net = require("node:net");
const path = require("node:path");
const tls = require("node:tls");
const sas = require("../../lib/frappe-local/share/sas.js");
const H = require("./helpers.js");

const { request, rawTls, startGateway, deviceRow, sleep } = H;
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

async function pairStart(gw, c, { ip = "10.1.1.1", name = "Priya's Mac", model = "Mac14,2", ng = crypto.randomBytes(16), body } = {}) {
    const r = await request(gw, {
        method: "POST", path: "/pair/start", cert: c, ip,
        body: body || JSON.stringify({ v: 2, name, model, commit: sas.commit(c.fp, ng) })
    });
    return { r, ng };
}

function pairReveal(gw, c, requestId, ng, { ip = "10.1.1.1" } = {}) {
    const handle = {};
    handle.done = request(gw, {
        method: "POST", path: "/pair/reveal", cert: c, ip, timeout: 60000, onReq: (req) => (handle.req = req),
        body: JSON.stringify({ v: 2, request_id: requestId, ng: ng.toString("hex") })
    });
    handle.done.catch(() => {});
    return handle;
}

const pending = async (gw) => (await gw.control({ op: "pending" })).pending;
const codeFor = (gw, c, ng, nh) => sas.sas(gw.host.fp, c.fp, ng, nh);

async function startAndReveal(gw, c, opts = {}) {
    const { r, ng } = await pairStart(gw, c, opts);
    assert.strictEqual(r.status, 200, r.text);
    const held = pairReveal(gw, c, r.json.request_id, ng, opts);
    await until(async () => (await pending(gw)).length === 1);
    return { id: r.json.request_id, ng, nh: r.json.nh, held };
}

async function fullPair(gw, c, { user = "priya@example.com", confirm = true, ...opts } = {}) {
    const p = await startAndReveal(gw, c, opts);
    const code = codeFor(gw, c, p.ng, p.nh);
    const ar = await gw.control({ op: "approve", id: p.id, code, user });
    assert.strictEqual(ar.ok, true, JSON.stringify(ar));
    const held = await p.held.done;
    assert.strictEqual(held.status, 200, held.text);
    if (confirm) {
        const cr = await request(gw, { method: "POST", path: "/pair/confirm", cert: c, body: JSON.stringify({ device_id: held.json.device_id }) });
        assert.strictEqual(cr.status, 200, cr.text);
    }
    return { ...p, code, deviceId: held.json.device_id, ar, held };
}

const sinkAgent = (c) => new https.Agent({
    keepAlive: true, maxSockets: 1, key: c.key, cert: c.cert, rejectUnauthorized: false, minVersion: "TLSv1.3", maxVersion: "TLSv1.3"
});

test("an unknown client certificate gets 403 not_paired, the connection closes, upstream sees nothing", async () => {
    await withGateway({}, async (gw) => {
        const r = await request(gw, { path: "/app", cert: cert("stranger"), headers: { accept: "application/json" } });
        assert.strictEqual(r.status, 403);
        assert.strictEqual(r.json.error, "not_paired");
        await until(() => r.socket.destroyed);
        assert.strictEqual(gw.upstream.hits.length, 0);
    });
});

test("no client certificate: pairing is refused, and so is everything else", async () => {
    await withGateway({}, async (gw) => {
        const start = await request(gw, { method: "POST", path: "/pair/start", body: JSON.stringify({ v: 2, name: "x", model: "y", commit: "0".repeat(64) }) });
        assert.ok([400, 403].includes(start.status), `start gave ${start.status}`);
        const app = await request(gw, { path: "/app" });
        assert.strictEqual(app.status, 403);
        assert.strictEqual(gw.upstream.hits.length, 0);
    });
});

test("a pending_confirm certificate reaches only confirm and leave", async () => {
    const c = cert("pc");
    const row = deviceRow(c, { status: "pending_confirm" });
    await withGateway({ devices: [row] }, async (gw) => {
        for (const p of ["/app", "/_benchbar/hello", "/_benchbar/signin?next=/app"]) {
            const r = await request(gw, { path: p, cert: c });
            assert.strictEqual(r.status, 403, p);
        }
        const start = await request(gw, { method: "POST", path: "/pair/start", cert: c, body: "{}" });
        assert.strictEqual(start.status, 403);
        assert.strictEqual(gw.upstream.hits.length, 0);

        const wrong = await request(gw, { method: "POST", path: "/pair/confirm", cert: c, body: JSON.stringify({ device_id: "d_ffffffff" }) });
        assert.strictEqual(wrong.status, 403);
        const ok = await request(gw, { method: "POST", path: "/pair/confirm", cert: c, body: JSON.stringify({ device_id: row.id }) });
        assert.strictEqual(ok.status, 200);
        assert.strictEqual(JSON.parse(fs.readFileSync(gw.devicesFile, "utf8")).devices[0].status, "active");
        assert.strictEqual((await request(gw, { path: "/app", cert: c })).status, 200);
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

test("sign-in: 302 to safeNext with the sid cookie; the user comes from devices.json; the sid is recorded nowhere", async () => {
    const c = cert("paired5");
    const row = deviceRow(c, { user: "mapped@example.com" });
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
        const ctl = JSON.stringify([await gw.control({ op: "status" }), await gw.control({ op: "devices" }), await gw.control({ op: "pending" })]);
        assert.ok(!ctl.includes(H.SID));
    });
});

test("sign-in is refused for unpaired, pending_confirm and unmapped devices; the helper never runs", async () => {
    const pc = cert("pc2");
    const nu = cert("nouser");
    await withGateway({ devices: [deviceRow(pc, { status: "pending_confirm" }), deviceRow(nu, { user: undefined })] }, async (gw) => {
        for (const c of [cert("stranger2"), pc, nu]) {
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
    await withGateway({ devices: [deviceRow(c), deviceRow(bad, { user: "failuser" })] }, async (gw) => {
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

test("pairing happy path: start, reveal (held), approve with the code and user, pending_confirm, then confirm makes it active", async () => {
    const c = cert("guest1");
    await withGateway({}, async (gw) => {
        const { r, ng } = await pairStart(gw, c);
        assert.strictEqual(r.status, 200);
        assert.match(r.json.request_id, /^r_[0-9a-f]{16}$/);
        assert.match(r.json.nh, /^[0-9a-f]{32}$/);
        assert.strictEqual(r.json.v, 2);
        assert.deepStrictEqual(await pending(gw), [], "listed before the reveal");

        const held = pairReveal(gw, c, r.json.request_id, ng);
        const q = await until(async () => { const p = await pending(gw); return p.length ? p : null; });
        assert.strictEqual(q[0].id, r.json.request_id);
        assert.strictEqual(q[0].name, "Priya's Mac");
        assert.strictEqual(q[0].ip, "10.1.1.1");
        assert.ok(!JSON.stringify(q).includes(ng.toString("hex")) && !JSON.stringify(q).includes(r.json.nh));

        const code = codeFor(gw, c, ng, r.json.nh);
        const ar = await gw.control({ op: "approve", id: r.json.request_id, code, user: "priya@example.com" });
        assert.strictEqual(ar.ok, true);
        const res = await held.done;
        assert.strictEqual(res.status, 200);
        assert.strictEqual(res.json.status, "approved");
        assert.strictEqual(res.json.user_label, "priya@example.com");
        assert.match(res.json.device_id, /^d_[0-9a-f]{8}$/);
        assert.ok(!res.text.includes(code));

        const rows = JSON.parse(fs.readFileSync(gw.devicesFile, "utf8")).devices;
        assert.strictEqual(rows.length, 1);
        assert.strictEqual(rows[0].status, "pending_confirm");
        assert.strictEqual(rows[0].fp, c.fp);
        assert.strictEqual(rows[0].user, "priya@example.com");
        assert.strictEqual((await request(gw, { path: "/app", cert: c })).status, 403);

        const cr = await request(gw, { method: "POST", path: "/pair/confirm", cert: c, body: JSON.stringify({ device_id: res.json.device_id }) });
        assert.strictEqual(cr.status, 200);
        assert.strictEqual(JSON.parse(fs.readFileSync(gw.devicesFile, "utf8")).devices[0].status, "active");
        assert.strictEqual((await request(gw, { path: "/app", cert: c })).status, 200);
    });
});

test("a reveal whose Ng does not match the commit is 400 and never reaches the queue", async () => {
    const c = cert("guest2");
    await withGateway({}, async (gw) => {
        const { r } = await pairStart(gw, c);
        const reveal = await pairReveal(gw, c, r.json.request_id, crypto.randomBytes(16)).done;
        assert.strictEqual(reveal.status, 400);
        assert.deepStrictEqual(await pending(gw), []);
        const again = await pairReveal(gw, c, r.json.request_id, crypto.randomBytes(16)).done;
        assert.strictEqual(again.status, 404, "the request is dropped");
    });
});

test("a reveal from another certificate cannot touch someone else's request", async () => {
    await withGateway({}, async (gw) => {
        const { r, ng } = await pairStart(gw, cert("guest3"));
        const other = await pairReveal(gw, cert("guest4"), r.json.request_id, ng).done;
        assert.strictEqual(other.status, 404);
        assert.deepStrictEqual(await pending(gw), []);
    });
});

test("three wrong codes deny; the held response is 403 denied", async () => {
    const c = cert("guest5");
    await withGateway({}, async (gw) => {
        const p = await startAndReveal(gw, c);
        const right = codeFor(gw, c, p.ng, p.nh);
        const wrong = right === "000000" ? "111111" : "000000";
        const tries = [];
        for (let i = 0; i < 3; i++) tries.push(await gw.control({ op: "approve", id: p.id, code: wrong, user: "a@example.com" }));
        assert.deepStrictEqual(tries.map((t) => t.ok), [false, false, false]);
        assert.deepStrictEqual(tries.map((t) => t.tries_left), [2, 1, 0]);
        assert.strictEqual(tries[2].error, "denied");
        const res = await p.held.done;
        assert.strictEqual(res.status, 403);
        assert.strictEqual(res.json.status, "denied");
        assert.deepStrictEqual(await pending(gw), []);
        assert.deepStrictEqual((await gw.control({ op: "devices" })).devices, []);
    });
});

test("pairing body limits and schema: 1025 bytes is 413 and closes, an extra key is 400, v:1 is 426", async () => {
    const c = cert("guest6");
    await withGateway({}, async (gw) => {
        const big = await request(gw, { method: "POST", path: "/pair/start", cert: c, body: JSON.stringify({ pad: "x".repeat(1025 - 10) }).padEnd(1025, " ") });
        assert.strictEqual(big.status, 413);
        await until(() => big.socket.destroyed);

        const extra = await pairStart(gw, c, { body: JSON.stringify({ v: 2, name: "n", model: "m", commit: "0".repeat(64), extra: 1 }), ip: "10.2.2.2" });
        assert.strictEqual(extra.r.status, 400);
        const v1 = await pairStart(gw, c, { body: JSON.stringify({ v: 1, name: "n", model: "m", commit: "0".repeat(64) }), ip: "10.2.2.3" });
        assert.strictEqual(v1.r.status, 426);
        assert.deepStrictEqual(v1.r.json, { error: "protocol", need: 2 });
        for (const bad of [{ v: 2, name: "", model: "m", commit: "0".repeat(64) }, { v: 2, name: "a".repeat(41), model: "m", commit: "0".repeat(64) },
            { v: 2, name: "bi\u{202E}di", model: "m", commit: "0".repeat(64) }, { v: 2, name: "n", model: "m", commit: "XYZ" }, [1, 2]]) {
            const r = await pairStart(gw, c, { body: JSON.stringify(bad), ip: "10.2.2.4" });
            assert.strictEqual(r.r.status, 400, JSON.stringify(bad));
        }
    });
});

test("a body that is slower than 5 s is dropped (408 or close)", { timeout: 15000 }, async () => {
    const c = cert("guest7");
    await withGateway({}, async (gw) => {
        const started = Date.now();
        const r = await rawTls(gw, "POST /pair/start HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n{", { cert: c, waitMs: 8000 });
        assert.ok(Date.now() - started < 7500);
        assert.ok(r.status === 408 || r.status === 0, `gave ${r.status}`);
    });
});

test("the 2nd start from one IP is 429, and the 4th pending overall is 429", async () => {
    await withGateway({}, async (gw) => {
        const a = cert("g8a");
        assert.strictEqual((await pairStart(gw, a, { ip: "10.3.0.1" })).r.status, 200);
        const second = await pairStart(gw, a, { ip: "10.3.0.1" });
        assert.strictEqual(second.r.status, 429);
        assert.strictEqual(second.r.json.status, "rate_limited");
        assert.ok(Number.isInteger(second.r.json.retry_after));
        assert.strictEqual((await pairStart(gw, cert("g8b"), { ip: "10.3.0.2" })).r.status, 200);
        assert.strictEqual((await pairStart(gw, cert("g8c"), { ip: "10.3.0.3" })).r.status, 200);
        assert.strictEqual((await pairStart(gw, cert("g8d"), { ip: "10.3.0.4" })).r.status, 429);
    });
});

test("after a deny and after an expiry the same IP is refused for 60 s (injected clock); TTL expiry is 408", async () => {
    const c = cert("g9");
    await withGateway({}, async (gw) => {
        const p = await startAndReveal(gw, c, { ip: "10.4.0.1" });
        await gw.control({ op: "deny", id: p.id });
        assert.strictEqual((await p.held.done).status, 403);
        gw.jump(59_000);
        assert.strictEqual((await pairStart(gw, c, { ip: "10.4.0.1" })).r.status, 429);
        gw.jump(62_000);
        const p2 = await startAndReveal(gw, c, { ip: "10.4.0.1" });

        gw.jump(62_000 + 301_000);
        const res = await p2.held.done;
        assert.strictEqual(res.status, 408);
        assert.strictEqual(res.json.status, "expired");
        assert.deepStrictEqual(await pending(gw), []);
        assert.strictEqual((await pairStart(gw, c, { ip: "10.4.0.1" })).r.status, 429);
        gw.jump(62_000 + 301_000 + 61_000);
        assert.strictEqual((await pairStart(gw, c, { ip: "10.4.0.1" })).r.status, 200);
    });
});

test("a guest cancel, or a dropped held connection, empties the host queue within 1 s", async () => {
    await withGateway({}, async (gw) => {
        const a = cert("g10a");
        const p = await startAndReveal(gw, a, { ip: "10.5.0.1" });
        const cancel = await request(gw, { method: "POST", path: "/pair/cancel", cert: a, ip: "10.5.0.1", body: JSON.stringify({ request_id: p.id }) });
        assert.strictEqual(cancel.status, 200);
        await until(async () => (await pending(gw)).length === 0, 1000);
        await p.held.done.catch(() => {});

        const b = cert("g10b");
        const q = await startAndReveal(gw, b, { ip: "10.5.0.2" });
        q.held.req.destroy();
        q.held.done.catch(() => {});
        await until(async () => (await pending(gw)).length === 0, 1000);
    });
});

test("an unconfirmed device is removed at 120 s", async () => {
    const c = cert("g11");
    await withGateway({}, async (gw) => {
        await fullPair(gw, c, { confirm: false });
        assert.strictEqual((await gw.control({ op: "devices" })).devices.length, 1);
        gw.jump(121_000);
        await until(async () => (await gw.control({ op: "devices" })).devices.length === 0, 2000);
        const r = await request(gw, { method: "POST", path: "/pair/confirm", cert: c, body: JSON.stringify({ device_id: "d_00000000" }) });
        assert.strictEqual(r.status, 403);
    });
});

test("re-pairing a known SPKI replaces the old row, and the pending request carries `replaces`", async () => {
    const c = cert("g12");
    const old = deviceRow(c, { name: "Old Mac", user: "old@example.com" });
    await withGateway({ devices: [old] }, async (gw) => {
        const p = await startAndReveal(gw, c, { name: "New Mac", ip: "10.6.0.1" });
        const [entry] = await pending(gw);
        assert.strictEqual(entry.replaces.name, "Old Mac");
        assert.strictEqual(entry.replaces.last_seen, old.last_seen);
        const ar = await gw.control({ op: "approve", id: p.id, code: codeFor(gw, c, p.ng, p.nh), user: "new@example.com" });
        assert.strictEqual(ar.ok, true);
        await p.held.done;
        const { devices } = await gw.control({ op: "devices" });
        assert.strictEqual(devices.length, 1);
        assert.strictEqual(devices[0].name, "New Mac");
        assert.notStrictEqual(devices[0].id, old.id);
        assert.strictEqual(devices[0].status, "pending_confirm");
    });
});

test("approve with a user already mapped to another device is refused and the request stays queued", async () => {
    const other = cert("g13o");
    await withGateway({ devices: [deviceRow(other, { user: "taken@example.com" })] }, async (gw) => {
        const c = cert("g13");
        const p = await startAndReveal(gw, c, { ip: "10.7.0.1" });
        const r = await gw.control({ op: "approve", id: p.id, code: codeFor(gw, c, p.ng, p.nh), user: "TAKEN@example.com" });
        assert.deepStrictEqual([r.ok, r.error], [false, "user_taken"]);
        assert.strictEqual((await pending(gw)).length, 1);
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

test("revoke destroys keep-alive sockets within 1 s; the reply carries the user and no sid", async () => {
    const c = cert("g15");
    const row = deviceRow(c, { user: "r@example.com" });
    await withGateway({ devices: [row] }, async (gw) => {
        const agent = sinkAgent(c);
        const first = await request(gw, { path: "/app", cert: c, agent });
        assert.strictEqual(first.status, 200);
        assert.strictEqual(first.socket.destroyed, false, "kept alive");
        const reply = await gw.control({ op: "revoke", device: row.id });
        assert.deepStrictEqual(reply, { ok: true, user: "r@example.com" });
        await until(() => first.socket.destroyed, 1000);
        const hitsBefore = gw.upstream.hits.length;
        const next = await request(gw, { path: "/app", cert: c, agent });
        assert.strictEqual(next.status, 403);
        assert.strictEqual(gw.upstream.hits.length, hitsBefore);
        agent.destroy();
        assert.deepStrictEqual(await gw.control({ op: "revoke", device: row.id }), { ok: false, error: "not_found" });
    });
});

test("a device revoked without closing its socket is still refused on the very next request (per-request lookup)", async () => {
    const c = cert("g16");
    const row = deviceRow(c);
    await withGateway({ devices: [row] }, async (gw) => {
        const agent = sinkAgent(c);
        assert.strictEqual((await request(gw, { path: "/app", cert: c, agent })).status, 200);
        fs.writeFileSync(gw.devicesFile, JSON.stringify({ v: 2, devices: [] }));
        const r = await request(gw, { path: "/app", cert: c, agent });
        assert.strictEqual(r.status, 403);
        agent.destroy();
    });
});

test("leave removes the device and its next request is not_paired", async () => {
    const c = cert("g17");
    const row = deviceRow(c);
    await withGateway({ devices: [row] }, async (gw) => {
        const r = await request(gw, { method: "POST", path: "/_benchbar/leave", cert: c, body: "" });
        assert.strictEqual(r.status, 200);
        assert.deepStrictEqual((await gw.control({ op: "devices" })).devices, []);
        const next = await request(gw, { path: "/app", cert: c, headers: { accept: "application/json" } });
        assert.strictEqual(next.status, 403);
        assert.strictEqual(next.json.error, "not_paired");
    });
});

test("hello answers an active device only, and carries the documented fields", async () => {
    const c = cert("g18");
    const row = deviceRow(c, { user: "h@example.com" });
    await withGateway({ devices: [row] }, async (gw) => {
        const r = await request(gw, { path: "/_benchbar/hello", cert: c });
        assert.strictEqual(r.status, 200);
        assert.deepStrictEqual(r.json, {
            ok: true, protocol: 2, device: row.id, user_label: "h@example.com", deadline_epoch: gw.cfg.deadline_epoch,
            label: "Test Host", site_label: "macdev", copy_made: "2026-11-02T09:00:00.000Z"
        });
        assert.strictEqual((await request(gw, { path: "/_benchbar/hello", cert: cert("stranger3") })).status, 403);
        assert.strictEqual((await request(gw, { method: "POST", path: "/_benchbar/hello", cert: c, body: "" })).status, 405);
    });
});

test("the control socket is 0600, answers status, assigns users and rejects unknown ops", async () => {
    const c = cert("g19");
    const row = deviceRow(c, { user: "s@example.com" });
    await withGateway({ devices: [row] }, async (gw) => {
        assert.strictEqual(fs.statSync(gw.cfg.control_sock).mode & 0o777, 0o600);
        const agent = sinkAgent(c);
        await request(gw, { path: "/app", cert: c, agent });
        const st = await gw.control({ op: "status" });
        assert.strictEqual(st.ok, true);
        assert.strictEqual(st.deadline_epoch, gw.cfg.deadline_epoch);
        assert.deepStrictEqual(st.online, [row.id]);
        assert.strictEqual(st.pending, 0);
        assert.ok(st.conns >= 1);
        assert.strictEqual(st.web_up, true);
        agent.destroy();

        const other = deviceRow(cert("g19b"), { user: "t@example.com" });
        fs.writeFileSync(gw.devicesFile, JSON.stringify({ v: 2, devices: [row, other] }));
        assert.strictEqual((await gw.control({ op: "assign", device: other.id, user: "s@example.com" })).error, "user_taken");
        assert.strictEqual((await gw.control({ op: "assign", device: other.id, user: "u@example.com" })).ok, true);
        assert.strictEqual((await gw.control({ op: "frobnicate" })).error, "unknown_op");
        assert.strictEqual((await gw.control({ nothing: 1 })).ok, false);
    });
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

test("a config with no deadline, a past deadline, a deadline beyond the cap, or no file exits 78", { timeout: 20000 }, async () => {
    const nowS = Math.floor(Date.now() / 1000);
    const cases = [
        { omit: ["deadline_epoch"] },
        { config: { deadline_epoch: nowS - 5 } },
        { config: { deadline_epoch: nowS - 10 + 43200 + 1 } },
        { config: { deadline_epoch: "soon" } },
        { config: { v: 3 } },
        { config: { unexpected: true } },
        { config: { listen: { host: "0.0.0.0", port: 99999 } } },
        { omit: ["signin_helper"] },
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
    await withGateway({ devices: [deviceRow(c, { user: "log@example.com" })] }, async (gw) => {
        const r = await request(gw, { path: "/app/sales-order/SO-1?x=secret", cert: c, headers: { cookie: "sid=cookievalue123" } });
        assert.strictEqual(r.status, 200);
        const file = await until(() => fs.existsSync(gw.logDir) && fs.readdirSync(gw.logDir).find((f) => f.startsWith("activity-")));
        const full = path.join(gw.logDir, file);
        await until(() => fs.readFileSync(full, "utf8").includes("/app/sales-order"));
        const text = fs.readFileSync(full, "utf8");
        assert.strictEqual(fs.statSync(full).mode & 0o777, 0o600);
        for (const banned of ["secret", "SO-1", "cookievalue123", "x="]) assert.ok(!text.includes(banned), banned);
        const line = JSON.parse(text.trim().split("\n")[0]);
        assert.deepStrictEqual([line.user, line.method, line.path, line.status], ["log@example.com", "GET", "/app/sales-order", 200]);
    });
});

test("hygiene: after a full flow the state dir and log dir hold no sid, typed code or nonce", async () => {
    const c = cert("g25");
    await withGateway({}, async (gw) => {
        const replies = [];
        const p = await startAndReveal(gw, c, { ip: "10.9.0.1" });
        replies.push(await gw.control({ op: "pending" }));
        const code = codeFor(gw, c, p.ng, p.nh);
        replies.push(await gw.control({ op: "approve", id: p.id, code: code === "123456" ? "123457" : "123456", user: "flow@example.com" }));
        replies.push(await gw.control({ op: "approve", id: p.id, code, user: "flow@example.com" }));
        const held = await p.held.done;
        await request(gw, { method: "POST", path: "/pair/confirm", cert: c, body: JSON.stringify({ device_id: held.json.device_id }) });
        const si = await request(gw, { path: "/_benchbar/signin?next=/app/x", cert: c });
        assert.strictEqual(si.status, 302);
        await request(gw, { path: "/app/sales-order/SO-9", cert: c });
        replies.push(await gw.control({ op: "devices" }), await gw.control({ op: "status" }));
        await gw.control({ op: "extend", seconds: 10 });

        const secrets = [H.SID, code, p.ng.toString("hex"), p.nh];
        const walk = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(path.join(dir, e.name)) : [path.join(dir, e.name)]));
        const files = [...walk(gw.stateDir), ...(fs.existsSync(gw.logDir) ? walk(gw.logDir) : [])];
        assert.ok(files.length > 0);
        for (const f of files) {
            const text = fs.readFileSync(f, "utf8");
            for (const s of secrets) assert.ok(!text.includes(s), `${path.basename(f)} holds a secret`);
        }
        const wire = JSON.stringify(replies) + gw.output();
        for (const s of [H.SID, p.ng.toString("hex"), p.nh]) assert.ok(!wire.includes(s));
        assert.ok(!JSON.stringify(replies.slice(1, 3)).includes(code));
    });
});
