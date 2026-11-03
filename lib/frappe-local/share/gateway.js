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
const { EXPORTER_LABEL, spkiFingerprint } = require("./cpace.js");
const { Room } = require("./join.js");
const { createProxy } = require("./proxy.js");
const { JoinLimiter, ConnLimiter, RateBucket } = require("./ratelimit.js");
const { createSignin } = require("./signin.js");

const TICK_MS = 30_000;
const JOIN_BODY_MAX = 1024;
const JOIN_BODY_WINDOW_MS = 5_000;
const HELLO_LOG_INTERVAL_MS = 60_000;
const SIGNIN_PER_MINUTE = 6;
const ROOM_HELLO_PER_MINUTE = 10;
const SEAT_PER_MINUTE = 6;
// Reachable without being in the room; and by a device that has no seat yet (J5).
const PRE_AUTH_ROUTES = new Set(["roomhello", "joinstart", "joinfinish"]);
const SEATLESS_ROUTES = new Set(["room", "seats", "seat", "hello", "leave"]);

const JSON_FOR_PAGE = {
    not_available: [403, { error: "forbidden" }],
    restarting: [503, { error: "upstream" }],
    ended: [403, { error: "ended" }],
    not_paired: [403, { error: "not_paired" }]
};

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

// Everything in `options` is dependency injection for tests (tests/share/gateway_harness.js);
// main() passes none, so production always has the real clock, the socket's real
// address and the 30 s tick, and no environment variable or header changes that.
function createGateway(cfg, cfgFile, { clock = Date.now, tickMs = TICK_MS, peerIpOf = (req) => req.socket.bbIp } = {}) {
    const now = clock;
    const store = devices.load(cfg.devices, { now });
    const log = new ActivityLog(cfg.log_dir, { now });
    const joinLimiter = new JoinLimiter({ now });
    const unpaired = new ConnLimiter({ maxTotal: cfg.max_conns.unpaired_total, maxPerIp: cfg.max_conns.unpaired_per_ip });
    const signinRate = new RateBucket({ now, limit: SIGNIN_PER_MINUTE });
    const helloRate = new RateBucket({ now, limit: ROOM_HELLO_PER_MINUTE });
    const seatRate = new RateBucket({ now, limit: SEAT_PER_MINUTE });
    const hostFp = leafFingerprint(fs.readFileSync(cfg.tls.cert));
    const room = new Room({
        store, limiter: joinLimiter, hostFp, label: cfg.label, roomLabel: cfg.room_label, siteLabel: cfg.site_label, seats: cfg.seats, now
    });
    const proxy = createProxy({ webPort: cfg.web_port, maxBodyBytes: cfg.max_body_mb * 1024 * 1024 });
    const signin = createSignin({ python: cfg.python, helper: cfg.signin_helper, site: cfg.share_site });

    // The share runner says when the web process is safe to send to: after its checks, again after each restart.
    // Until then, and from the first connection upstream refuses, every proxied request gets the 503 page.
    let webUp = false;
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
        // rejectUnauthorized:false only waives the chain verdict (guests present self-signed certificates).
        // OpenSSL's tls_process_cert_verify still checks the CertificateVerify signature of any certificate
        // sent, so the client SPKI we hash into Fg is one the peer holds the key for. The tags rely on that.
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
        try { store.emptyAll(); } catch { /* the next start empties it again */ }
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
            if (devices.isSeatlessExpired(d, now())) {
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
        room.sweep();
        try {
            for (const d of store.reapSeatless()) destroySocketsOf(d.fp);
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
            if (declared !== undefined && Number(declared) > JOIN_BODY_MAX) {
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
            }, JOIN_BODY_WINDOW_MS);
            req.on("data", (c) => {
                size += c.length;
                if (settled) return;
                if (size > JOIN_BODY_MAX) {
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

    function record(device, req, res, normalized) {
        res.on("finish", () => {
            try {
                log.record({ device: device.id, user: device.user, method: req.method, path: normalized.forward, status: res.statusCode });
            } catch { /* a full disk must not take sharing down */ }
        });
    }

    function handleRoomHello(req, res) {
        const ip = peerIpOf(req);
        if (!helloRate.take(ip)) {
            const retry = helloRate.retryAfter(ip);
            res.setHeader("Retry-After", String(retry));
            return sendJson(res, 429, { status: "rate_limited", retry_after: retry });
        }
        sendJson(res, 200, room.hello());
    }

    async function handleJoin(req, res, route) {
        const fp = req.socket.bbFp;
        if (!fp) return sendJson(res, 403, { error: "certificate_required" }, { close: true });
        const body = await readJsonBody(req, res);
        if (body === null) return;
        const ip = peerIpOf(req);
        if (route === "joinstart") {
            const out = room.start(ip, fp, body);
            return sendJson(res, out.status, out.body);
        }
        // The exporter of this very connection binds the tags to this TLS session (J16).
        let exporter;
        try {
            exporter = req.socket.exportKeyingMaterial(32, EXPORTER_LABEL, Buffer.alloc(0));
        } catch {
            return sendJson(res, 400, { error: "bad_request" }, { close: true });
        }
        const out = room.finish(ip, fp, exporter, body);
        sendJson(res, out.status, out.body);
    }

    function handleHello(req, res, device) {
        sendJson(res, 200, {
            ok: true, protocol: 3, device: device.id, user_label: device.user || null, deadline_epoch: deadline,
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

    async function handleSignin(req, res, deviceSeen, normalized) {
        if (!signinRate.take(deviceSeen.id)) {
            res.setHeader("Retry-After", "60");
            return sendJson(res, 429, { status: "rate_limited", retry_after: 60 });
        }
        // Serialised with seat moves and leave. The device is read again inside the turn, and
        // again after the mint: a sid for a seat that is no longer this device's is wiped, never sent.
        const out = await room.exclusive(deviceSeen.id, async () => {
            const device = store.list().find((d) => d.id === deviceSeen.id);
            if (!device || !device.user) return { page: "not_available" };
            let sid;
            try {
                sid = await signin.mint(device.user);
            } catch {
                return { page: "restarting" };
            }
            const after = store.list().find((d) => d.id === device.id);
            if (after && after.user === device.user && after.seat_id === device.seat_id) return { sid };
            await signin.wipe(device.user).then(() => room.noteWipeDone(device.user), () => room.noteWipeFailure(device.user));
            return { page: "not_available" };
        });
        if (out.page) return sendPage(req, res, out.page);
        const next = new URLSearchParams(normalized.search).get("next");
        const location = (next && policy.safeNext(next)) || "/app";
        const expires = new Date(deadline * 1000).toUTCString();
        res.writeHead(302, {
            Location: location, "Set-Cookie": `sid=${out.sid}; Path=/; HttpOnly; SameSite=Lax; Expires=${expires}`, "Cache-Control": "no-store",
            "Content-Length": "0"
        });
        res.end();
    }

    // A browser that leaves keeps its cookie, so the seat's sessions are wiped before we answer.
    // A failed wipe is reported to the guest and stays in status.wipe_failed for the host.
    // The user is owed the wipe before the seat is freed, so nobody can take the seat (and sign in)
    // while the wipe that would end their session is still running.
    async function handleLeave(req, res, device) {
        const wiped = await room.exclusive(device.id, async () => {
            const current = store.list().find((d) => d.id === device.id);
            const user = current && current.user;
            if (user) room.noteWipeFailure(user);
            store.remove(device.id);
            if (!user) return true;
            try {
                await signin.wipe(user);
                room.noteWipeDone(user);
                return true;
            } catch {
                room.noteWipeFailure(user);
                return false;
            }
        });
        sendJson(res, 200, { ok: true, wiped }, { close: true });
        destroySocketsOf(device.fp, req.socket);
    }

    const isOnline = (d) => (socketsByFp.get(d.fp) || new Set()).size > 0;

    function handleRoom(req, res, device) {
        sendJson(res, 200, room.roster(device, deadline, isOnline));
    }

    function handleSeats(req, res) {
        sendJson(res, 200, room.seatList());
    }

    async function handleSeat(req, res, device) {
        const body = await readJsonBody(req, res);
        if (body === null) return;
        if (Object.keys(body).length !== 1 || typeof body.seat_id !== "string") return sendJson(res, 400, { error: "bad_request" });
        if (!seatRate.take(device.id)) {
            res.setHeader("Retry-After", "60");
            return sendJson(res, 429, { status: "rate_limited", retry_after: 60 });
        }
        const out = await room.moveToSeat(device, body.seat_id, signin.wipe);
        if (!out.ok) return sendJson(res, out.status, { status: out.error });
        if (!wantsHtml(req)) return sendJson(res, 200, { ok: true, seat_id: out.seat_id, full_name: out.full_name });
        res.writeHead(302, { Location: "/_benchbar/signin?next=/app", "Cache-Control": "no-store", "Content-Length": "0" });
        res.end();
    }

    function handleWeb(req, res, device, normalized) {
        record(device, req, res, normalized);
        if (!webUp) return sendPage(req, res, "restarting");
        proxy.forward(req, res, normalized.forward + normalized.search, {
            onFailure: (kind, code) => {
                if (kind === "too_large") return sendJson(res, 413, { error: "too_large" }, { close: true });
                // nothing listens: whatever binds the port next must not get guests before the runner has
                // checked it. A reset of one request (ECONNRESET) comes from a web process that still
                // listens, so it is that request's 503 only; the runner's watchdog sees a web that died.
                if (code === "ECONNREFUSED") webUp = false;
                sendPage(req, res, "restarting");
            }
        });
    }

    function permitted(device, route) {
        if (PRE_AUTH_ROUTES.has(route)) return true;
        if (!device) return false;
        return Boolean(device.seat_id) || SEATLESS_ROUTES.has(route);
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
        const verdict = normalized.ok ? policy.isAllowed(req.method, normalized.path) : { ok: false, reason: "forbidden" };
        const route = verdict.ok ? verdict.route : null;
        if (!permitted(device, route)) return sendPage(req, res, device ? "not_available" : "not_paired", { close: !device });

        if (!normalized.ok) return sendJson(res, 400, { error: "bad_request" }, { close: true });
        if (!verdict.ok) {
            if (verdict.route === "gone") return sendJson(res, 404, { error: "not_found" }, { close: true });
            if (verdict.reason === "method") return sendJson(res, 405, { error: "method_not_allowed" });
            return sendPage(req, res, "not_available");
        }

        const browserShaped = req.headers.origin !== undefined || req.headers["sec-fetch-site"] !== undefined;
        const mutating = route === "leave" || route === "seat";
        if (route === "web" || route === "signin" || (mutating && browserShaped)) {
            if (!policy.hostAllowed(host)) return sendJson(res, 400, { error: "bad_host" }, { close: true });
        }
        if (route === "web" || route === "signin" || mutating) {
            if (!policy.originAllowed(req.headers.origin) || !policy.fetchSiteAllowed(req.headers["sec-fetch-site"])) {
                return sendPage(req, res, "not_available");
            }
        }

        if (known) {
            try { store.touch(device.id); } catch { /* the device vanished between lookup and touch */ }
        }
        if (route === "roomhello") return handleRoomHello(req, res);
        if (route === "joinstart" || route === "joinfinish") return handleJoin(req, res, route);
        if (route === "room") return handleRoom(req, res, device);
        if (route === "seats") return handleSeats(req, res);
        if (route === "seat") return handleSeat(req, res, device);
        if (route === "leave") return handleLeave(req, res, device);
        if (route === "hello") return handleHello(req, res, device);
        if (route === "signin") {
            record(device, req, res, normalized);
            return handleSignin(req, res, device, normalized);
        }
        return handleWeb(req, res, device, normalized);
    }

    const onlineIds = () => store.list().filter(isOnline).map((d) => d.id);

    const api = {
        expired: checkDeadline,
        status: async () => ({
            ok: true, deadline_epoch: deadline, online: onlineIds(), conns: tlsSockets.size, web_up: webUp, ...room.status()
        }),
        web: (state) => {
            webUp = state === "up";
            return { ok: true, web_up: webUp };
        },
        code: () => room.code(),
        rotate: () => room.rotate(),
        lock: () => room.lock(),
        unlock: () => room.unlock(),
        people: () => {
            const names = new Map(cfg.seats.map((seat) => [seat.seat_id, seat.full_name]));
            return store.list().map((d) => ({ ...d, full_name: names.get(d.seat_id) ?? null, online: isOnline(d) }));
        },
        assign: async (id, seatId) => {
            const device = store.list().find((d) => d.id === id);
            if (!device) return { ok: false, error: "not_found" };
            const out = await room.moveToSeat(device, seatId, signin.wipe);
            return out.ok ? { ok: true } : { ok: false, error: out.error };
        },
        remove: (id) => {
            const device = store.list().find((d) => d.id === id);
            if (!device) return { ok: false, error: "not_found" };
            store.remove(id);
            room.onRemove(device.fp);
            destroySocketsOf(device.fp);
            // Owed a wipe until the wipe op ends it (the CLI sends it next): a CLI that dies in
            // between leaves it in status.wipe_failed, where the next room command finds it.
            if (device.user) room.noteWipeFailure(device.user);
            return { ok: true, user: device.user || null };
        },
        // Retries every owed wipe at once: the control socket drops a connection idle for 10 s.
        wipe: async () => {
            const owed = [...room.wipeFailures];
            const results = await Promise.allSettled(owed.map((user) => signin.wipe(user)));
            let wiped = 0;
            results.forEach((r, i) => {
                if (r.status === "fulfilled") {
                    room.noteWipeDone(owed[i]);
                    wiped++;
                }
            });
            return { ok: true, wiped, wipe_failed: [...room.wipeFailures] };
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
        store.emptyAll();
        await new Promise((resolve, reject) => {
            server.once("error", reject);
            server.listen(cfg.listen.port, cfg.listen.host, resolve);
        });
        controlServer = await control.serve(cfg.control_sock, api);
        armDeadline();
        tickTimer = setInterval(housekeeping, tickMs);
        try { log.prune(); } catch { /* retention is best effort */ }
    }

    return { start, shutdown, checkDeadline };
}

async function main(argv, options = {}) {
    process.umask(0o077);
    let gateway;
    try {
        if (!argv[0]) throw Object.assign(new Error("invalid gateway config: no config path"), { exitCode: config.EX_CONFIG });
        const cfg = config.load(argv[0], (options.clock || Date.now)());
        gateway = createGateway(cfg, argv[0], options);
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

if (require.main === module) main(process.argv.slice(2));

module.exports = { createGateway, main };
