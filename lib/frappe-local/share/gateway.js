"use strict";
const crypto = require("crypto");
const fs = require("fs");
const https = require("https");
const config = require("./config.js");
const control = require("./control.js");
const devices = require("./devices.js");
const policy = require("./policy.js");
const { ActivityLog } = require("./activitylog.js");
const { renderError } = require("./htmlpages.js");
const { Pairing } = require("./pairing.js");
const { createProxy } = require("./proxy.js");
const { PairLimiter, ConnLimiter, RateBucket } = require("./ratelimit.js");
const { spkiFingerprint } = require("./sas.js");
const { createSignin } = require("./signin.js");

const TICK_MS = 30_000;
const PAIR_BODY_MAX = 1024;
const PAIR_BODY_WINDOW_MS = 5_000;
const HELLO_LOG_INTERVAL_MS = 60_000;
const SIGNIN_PER_MINUTE = 6;
const PAIR_PATHS = ["/pair/start", "/pair/reveal", "/pair/cancel", "/pair/confirm"];
const UNPAIRED_PAIR_PATHS = ["/pair/start", "/pair/reveal", "/pair/cancel"];

const JSON_FOR_PAGE = {
    not_available: [403, { error: "forbidden" }],
    restarting: [503, { error: "upstream" }],
    ended: [403, { error: "ended" }],
    not_paired: [403, { error: "not_paired" }]
};

// Test hooks, honoured only under NODE_ENV=test (the product path uses the real
// clock, the socket's real address and a 30 s tick): FL_SHARE_TEST_CLOCK_FILE
// holds a millisecond offset added to the clock, FL_SHARE_TEST_TICK_MS shortens
// the housekeeping tick, and the x-test-peer-ip header stands in for the peer
// address (every test client is 127.0.0.1).
function testHooks(env) {
    if (env.NODE_ENV !== "test") return { clock: Date.now, tickMs: TICK_MS, peerIpHeader: false };
    const file = env.FL_SHARE_TEST_CLOCK_FILE;
    const clock = file ? () => Date.now() + (Number(fs.readFileSync(file, "utf8")) || 0) : Date.now;
    return { clock, tickMs: Number(env.FL_SHARE_TEST_TICK_MS) || TICK_MS, peerIpHeader: true };
}

function leafFingerprint(derOrPem) {
    const x = new crypto.X509Certificate(derOrPem);
    return spkiFingerprint(x.publicKey.export({ type: "spki", format: "der" }));
}

function peerFingerprint(socket) {
    const peer = socket.getPeerCertificate();
    if (!peer || !peer.raw) return null;
    try {
        return leafFingerprint(peer.raw);
    } catch {
        return null;
    }
}

const normalizeIp = (addr) => String(addr || "").replace(/^::ffff:/, "");
const wantsHtml = (req) => /text\/html/i.test(req.headers.accept || "");

function createGateway(cfg, cfgFile, env) {
    const hooks = testHooks(env);
    const now = hooks.clock;
    const store = devices.load(cfg.devices, { now });
    const log = new ActivityLog(cfg.log_dir, { now });
    const pairLimiter = new PairLimiter({ now });
    const unpaired = new ConnLimiter({ maxTotal: cfg.max_conns.unpaired_total, maxPerIp: cfg.max_conns.unpaired_per_ip });
    const signinRate = new RateBucket({ now, limit: SIGNIN_PER_MINUTE });
    const hostFp = leafFingerprint(fs.readFileSync(cfg.tls.cert));
    const pairing = new Pairing({ store, limiter: pairLimiter, hostFp, now });
    const proxy = createProxy({ webPort: cfg.web_port, maxBodyBytes: cfg.max_body_mb * 1024 * 1024 });
    const signin = createSignin({ python: cfg.python, helper: cfg.signin_helper, site: cfg.share_site });
    const policyCfg = { pairPaths: PAIR_PATHS };

    let deadline = cfg.deadline_epoch;
    let deadlineTimer = null;
    let tickTimer = null;
    let controlServer = null;
    let closing = false;
    const rawSockets = new Set();
    const tlsSockets = new Set();
    const socketsByFp = new Map();
    const slots = new Map();         // "ip:port" -> {ip, held}: the ConnLimiter slot of a connection not yet known as paired
    const deviceConns = new Map();   // fp -> open sockets of a known device
    const lastHelloLog = new Map();
    let knownConns = 0;

    const server = https.createServer({
        key: fs.readFileSync(cfg.tls.key), cert: fs.readFileSync(cfg.tls.cert),
        minVersion: "TLSv1.3", maxVersion: "TLSv1.3", requestCert: true, rejectUnauthorized: false, ALPNProtocols: ["http/1.1"],
        handshakeTimeout: 5_000, secureOptions: crypto.constants.SSL_OP_NO_TICKET,
        maxHeaderSize: 16 * 1024, headersTimeout: 10_000, requestTimeout: 120_000, connectionsCheckingInterval: 1_000
    }, onRequest);

    // No session resumption: every connection presents its certificate afresh.
    server.on("newSession", (id, data, cb) => cb());
    server.on("resumeSession", (id, cb) => cb(null, null));

    function shutdown(code) {
        if (closing) return;
        closing = true;
        clearTimeout(deadlineTimer);
        clearInterval(tickTimer);
        server.close();
        for (const s of rawSockets) s.destroy();
        for (const s of tlsSockets) s.destroy();
        if (controlServer) controlServer.close();
        process.exit(code);
    }

    const pastDeadline = () => now() >= deadline * 1000;

    function checkDeadline() {
        if (closing) return true;
        if (!pastDeadline()) return false;
        shutdown(0);
        return true;
    }

    function armDeadline() {
        clearTimeout(deadlineTimer);
        const wait = Math.min(Math.max(deadline * 1000 - now(), 0), 2 ** 31 - 1);
        deadlineTimer = setTimeout(() => { if (!checkDeadline()) armDeadline(); }, wait);
    }

    function destroySocketsOf(fp, except) {
        for (const s of [...(socketsByFp.get(fp) || [])]) if (s !== except) s.destroy();
    }

    function lookup(fp) {
        if (!fp) return null;
        try {
            const d = store.findBySpki(fp);
            if (!d) return null;
            if (pairing.isUnconfirmedExpired(d)) {
                store.remove(d.id);
                destroySocketsOf(fp);
                return null;
            }
            return d;
        } catch {
            return null;
        }
    }

    function housekeeping() {
        if (checkDeadline()) return;
        pairing.sweep();
        try {
            for (const d of pairing.reapUnconfirmed()) destroySocketsOf(d.fp);
        } catch { /* devices.json busy or unreadable: the per-request lookup still fails closed */ }
    }

    function onConnection(raw) {
        if (closing) return raw.destroy();
        raw.on("error", () => raw.destroy());
        const ip = normalizeIp(raw.remoteAddress);
        if (!unpaired.acquire(ip).ok) return raw.destroy();
        const key = `${raw.remoteAddress}:${raw.remotePort}`;
        const slot = { ip, held: true };
        slots.set(key, slot);
        rawSockets.add(raw);
        raw.on("close", () => {
            rawSockets.delete(raw);
            slots.delete(key);
            if (slot.held) unpaired.release(ip);
        });
    }

    function onSecureConnection(sock) {
        sock.on("error", () => sock.destroy());
        const fp = peerFingerprint(sock);
        sock.bbFp = fp;
        sock.bbIp = normalizeIp(sock.remoteAddress);
        tlsSockets.add(sock);
        if (fp) {
            if (!socketsByFp.has(fp)) socketsByFp.set(fp, new Set());
            socketsByFp.get(fp).add(sock);
        }
        const known = lookup(fp);
        if (known) {
            const slot = slots.get(`${sock.remoteAddress}:${sock.remotePort}`);
            if (slot && slot.held) { slot.held = false; unpaired.release(slot.ip); }
            const mine = (deviceConns.get(fp) || 0) + 1;
            deviceConns.set(fp, mine);
            knownConns++;
            if (mine > cfg.max_conns.per_device || knownConns > cfg.max_conns.total) sock.destroy();
        }
        sock.on("close", () => {
            tlsSockets.delete(sock);
            const set = socketsByFp.get(fp);
            if (set) { set.delete(sock); if (set.size === 0) socketsByFp.delete(fp); }
            if (known) {
                knownConns--;
                const left = (deviceConns.get(fp) || 1) - 1;
                if (left <= 0) deviceConns.delete(fp);
                else deviceConns.set(fp, left);
            }
        });
    }

    server.on("connection", onConnection);
    server.on("secureConnection", onSecureConnection);
    server.on("tlsClientError", (err, sock) => sock.destroy());
    server.on("clientError", (err, sock) => {
        if (sock.writable) sock.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
        else sock.destroy();
    });
    server.on("upgrade", (req, sock) => {
        sock.on("error", () => sock.destroy());
        sock.end("HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
    });

    function sendJson(res, status, body, { close = false } = {}) {
        const text = JSON.stringify(body);
        const headers = {
            "Content-Type": "application/json; charset=utf-8", "Content-Length": Buffer.byteLength(text), "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff"
        };
        if (close) headers.Connection = "close";
        res.writeHead(status, headers);
        res.end(text);
    }

    function sendPage(req, res, kind, { close = false, onDone } = {}) {
        if (!wantsHtml(req)) {
            const [status, body] = JSON_FOR_PAGE[kind];
            sendJson(res, status, body, { close });
            if (onDone) res.on("finish", onDone);
            return;
        }
        const page = renderError(kind, { label: cfg.label });
        res.writeHead(page.status, close ? { ...page.headers, Connection: "close" } : page.headers);
        res.end(page.body, onDone);
    }

    function readJsonBody(req, res) {
        return new Promise((resolve) => {
            const declared = req.headers["content-length"];
            if (declared !== undefined && Number(declared) > PAIR_BODY_MAX) {
                sendJson(res, 413, { error: "too_large" }, { close: true });
                return resolve(null);
            }
            const chunks = [];
            let size = 0;
            let settled = false;
            const settle = (value) => { if (!settled) { settled = true; clearTimeout(timer); resolve(value); } };
            const timer = setTimeout(() => {
                if (settled) return;
                sendJson(res, 408, { error: "timeout" }, { close: true });
                settle(null);
            }, PAIR_BODY_WINDOW_MS);
            req.on("data", (c) => {
                size += c.length;
                if (settled) return;
                if (size > PAIR_BODY_MAX) {
                    sendJson(res, 413, { error: "too_large" }, { close: true });
                    settle(null);
                } else {
                    chunks.push(c);
                }
            });
            req.on("end", () => {
                if (settled) return;
                let parsed;
                try {
                    parsed = JSON.parse(Buffer.concat(chunks).toString("utf8"));
                } catch {
                    parsed = undefined;
                }
                if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
                    sendJson(res, 400, { error: "bad_request" }, { close: true });
                    return settle(null);
                }
                settle(parsed);
            });
            req.on("error", () => settle(null));
        });
    }

    function peerIp(req) {
        const claimed = hooks.peerIpHeader && req.headers["x-test-peer-ip"];
        return typeof claimed === "string" && claimed ? claimed : req.socket.bbIp;
    }

    function record(device, req, res, normalized) {
        res.on("finish", () => {
            try {
                log.record({ device: device.id, user: device.user, method: req.method, path: normalized.forward, status: res.statusCode });
            } catch { /* a full disk must not take sharing down */ }
        });
    }

    async function handlePair(req, res, exact, device) {
        const fp = req.socket.bbFp;
        if (!fp) return sendJson(res, 403, { error: "certificate_required" }, { close: true });
        const body = await readJsonBody(req, res);
        if (body === null) return;
        const ip = peerIp(req);
        if (exact === "/pair/start") {
            const out = pairing.start(ip, fp, body);
            return sendJson(res, out.status, out.body);
        }
        if (exact === "/pair/cancel") {
            const out = pairing.cancel(fp, body);
            return sendJson(res, out.status, out.body);
        }
        if (exact === "/pair/confirm") {
            if (!device || !Object.keys(body).every((k) => k === "device_id") || body.device_id !== device.id) {
                return sendJson(res, 403, { error: "not_paired" }, { close: true });
            }
            store.confirm(device.id);
            return sendJson(res, 200, { ok: true });
        }
        const respond = (status, out) => {
            if (!res.writableEnded && !res.destroyed) sendJson(res, status, out);
        };
        const out = pairing.reveal(ip, fp, body, respond);
        if (!out.held) return sendJson(res, out.status, out.body);
        res.on("close", () => { if (!res.writableFinished) pairing.drop(out.held); });
    }

    function handleHello(req, res, device) {
        sendJson(res, 200, {
            ok: true, protocol: 2, device: device.id, user_label: device.user || null, deadline_epoch: deadline,
            label: cfg.label, site_label: cfg.site_label, copy_made: cfg.copy_made
        });
        const last = lastHelloLog.get(device.id) || 0;
        if (now() - last >= HELLO_LOG_INTERVAL_MS) {
            lastHelloLog.set(device.id, now());
            try {
                log.record({ device: device.id, user: device.user, method: req.method, path: "/_benchbar/hello", status: 200 });
            } catch { /* see record() */ }
        }
    }

    async function handleSignin(req, res, device, normalized) {
        if (!device.user) return sendPage(req, res, "not_available");
        if (!signinRate.take(device.id)) {
            res.setHeader("Retry-After", "60");
            return sendJson(res, 429, { status: "rate_limited", retry_after: 60 });
        }
        let sid;
        try {
            sid = await signin.mint(device.user);
        } catch {
            return sendPage(req, res, "restarting");
        }
        const next = new URLSearchParams(normalized.search).get("next");
        const location = (next && policy.safeNext(next)) || "/app";
        const expires = new Date(deadline * 1000).toUTCString();
        res.writeHead(302, {
            Location: location, "Set-Cookie": `sid=${sid}; Path=/; HttpOnly; SameSite=Lax; Expires=${expires}`, "Cache-Control": "no-store",
            "Content-Length": "0"
        });
        res.end();
    }

    function handleLeave(req, res, device) {
        store.remove(device.id);
        sendJson(res, 200, { ok: true }, { close: true });
        destroySocketsOf(device.fp, req.socket);
    }

    function handleWeb(req, res, device, normalized) {
        record(device, req, res, normalized);
        proxy.forward(req, res, normalized.forward + normalized.search, {
            onFailure: (kind) => (kind === "too_large" ? sendJson(res, 413, { error: "too_large" }, { close: true }) : sendPage(req, res, "restarting"))
        });
    }

    function permitted(device, route, exact) {
        if (!device) return route === "pair" && UNPAIRED_PAIR_PATHS.includes(exact);
        if (device.status === "pending_confirm") return route === "leave" || (route === "pair" && exact === "/pair/confirm");
        return true;
    }

    async function onRequest(req, res) {
        try {
            await dispatch(req, res);
        } catch {
            if (!res.headersSent) sendJson(res, 500, { error: "internal" }, { close: true });
            else res.destroy();
        }
    }

    async function dispatch(req, res) {
        if (closing) return req.socket.destroy();
        if (pastDeadline()) {
            // Answer this one request, then end everything; the timer would have done the same a moment later.
            sendPage(req, res, "ended", { close: true, onDone: () => setTimeout(() => shutdown(0), 100) });
            setTimeout(() => shutdown(0), 500);
            return;
        }
        const device = lookup(req.socket.bbFp);
        const known = Boolean(device);
        const host = policy.singleHost(req.rawHeaders);
        if (host === null) return sendJson(res, 400, { error: "bad_request" }, { close: true });

        const normalized = policy.normalizePath(req.url);
        const verdict = normalized.ok ? policy.isAllowed(req.method, normalized.path, policyCfg) : { ok: false, reason: "forbidden" };
        const route = verdict.ok ? verdict.route : null;
        if (!permitted(device, route, normalized.path)) return sendPage(req, res, "not_paired", { close: true });

        if (!normalized.ok) return sendJson(res, 400, { error: "bad_request" }, { close: true });
        if (!verdict.ok) {
            if (verdict.route === "gone") return sendJson(res, 404, { error: "not_found" }, { close: true });
            if (verdict.reason === "method") return sendJson(res, 405, { error: "method_not_allowed" });
            return sendPage(req, res, "not_available");
        }

        if (route === "web" || route === "signin") {
            if (!policy.hostAllowed(host)) return sendJson(res, 400, { error: "bad_host" }, { close: true });
            if (!policy.originAllowed(req.headers.origin) || !policy.fetchSiteAllowed(req.headers["sec-fetch-site"])) {
                return sendPage(req, res, "not_available");
            }
        }

        if (known) {
            try { store.touch(device.id); } catch { /* the device vanished between lookup and touch */ }
        }
        if (route === "pair") return handlePair(req, res, normalized.path, device);
        if (route === "leave") return handleLeave(req, res, device);
        if (route === "hello") return handleHello(req, res, device);
        if (route === "signin") {
            record(device, req, res, normalized);
            return handleSignin(req, res, device, normalized);
        }
        return handleWeb(req, res, device, normalized);
    }

    const onlineIds = () => store.list().filter((d) => d.status === "active" && (socketsByFp.get(d.fp) || new Set()).size > 0).map((d) => d.id);

    const api = {
        status: async () => ({
            ok: true, deadline_epoch: deadline, online: onlineIds(), pending: pairing.pending().length, conns: tlsSockets.size,
            web_up: await proxy.probe()
        }),
        pending: () => pairing.pending(),
        approve: (m) => pairing.approve(m),
        deny: (id) => pairing.deny(id),
        devices: () => store.list().map((d) => ({ ...d, online: (socketsByFp.get(d.fp) || new Set()).size > 0 })),
        assign: (id, user) => {
            store.assign(id, user);
            return { ok: true };
        },
        revoke: (id) => {
            const device = store.list().find((d) => d.id === id);
            if (!device) return { ok: false, error: "not_found" };
            store.remove(id);
            destroySocketsOf(device.fp);
            return { ok: true, user: device.user || null };
        },
        extend: (seconds) => {
            const cap = cfg.started_epoch + cfg.max_total_s;
            const next = Math.max(deadline, Math.min(deadline + seconds, cap));
            if (next !== deadline) config.writeDeadline(cfgFile, next);
            const capped = deadline + seconds > cap;
            deadline = next;
            armDeadline();
            return { ok: true, deadline_epoch: next, capped };
        },
        stop: () => {
            setTimeout(() => shutdown(0), 50);
            return { ok: true };
        }
    };

    async function start() {
        await new Promise((resolve, reject) => {
            server.once("error", reject);
            server.listen(cfg.listen.port, cfg.listen.host, resolve);
        });
        controlServer = await control.serve(cfg.control_sock, api);
        armDeadline();
        tickTimer = setInterval(housekeeping, hooks.tickMs);
        try { log.prune(); } catch { /* retention is best effort */ }
    }

    return { start, shutdown, checkDeadline };
}

async function main(argv, env) {
    process.umask(0o077);
    let gateway;
    try {
        if (!argv[0]) throw Object.assign(new Error("invalid gateway config: no config path"), { exitCode: config.EX_CONFIG });
        const hooks = testHooks(env);
        const cfg = config.load(argv[0], hooks.clock());
        gateway = createGateway(cfg, argv[0], env);
    } catch (e) {
        process.stderr.write(`gateway: ${e.exitCode === config.EX_CONFIG ? e.message : "cannot start: " + (e.code || e.name)}\n`);
        process.exit(config.EX_CONFIG);
    }
    for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"]) process.on(sig, () => gateway.shutdown(0));
    process.on("uncaughtException", (e) => {
        process.stderr.write(`gateway: fatal ${e.code || e.name}\n`);
        gateway.shutdown(1);
    });
    try {
        await gateway.start();
    } catch (e) {
        process.stderr.write(`gateway: cannot listen: ${e.code || e.name}\n`);
        gateway.shutdown(1);
    }
}

if (require.main === module) main(process.argv.slice(2), process.env);

module.exports = { createGateway };
