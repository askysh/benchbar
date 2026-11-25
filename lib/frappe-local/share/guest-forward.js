"use strict";
// The guest's forwarder: a listener on 127.0.0.1 that relays each browser connection to the room's host
// over its own pinned TLS connection, with this computer's key for that host. The browser opens the room
// on http://<name>.localhost:<port>, never on the network. It is the Mac app's ShareForwarder.swift, plus
// what the app does around it: the check of the room every 10 s, the pages that say why a room does not
// open, and the end after 15 minutes without a browser connection.
//
//   node guest-forward.js DIR KEY_STORE SECURITY ROOM_ID
//
// Nothing secret is an argument: the key is read from the key store. `benchbar share join` starts it
// detached and talks to it on DIR/ROOM_ID.sock (one JSON line each way): status, ping, stop.
const fs = require("fs");
const net = require("net");
const path = require("path");
const guest = require("./guest.js");

const MAX_HEAD = 32 * 1024;
const HEAD_WAIT_MS = 30_000;
const CLOSE_WAIT_MS = 10_000;
const RELAY_IDLE_MS = 120_000;       // no byte either way for this long: both ends are closed
const MAX_CONNECTIONS = 32;          // each local connection is a TLS connection to the host and takes a slot there
const IDLE_LIMIT_MS = 15 * 60_000;
const PING_MS = 10_000;
const PING_MAX_MS = 5 * 60_000;
const LINGER_MS = 5 * 60_000;
const PORT_TRIES = 20;
const HOUSEKEEPING_MS = 15_000;
const HOP_BY_HOP = new Set(["connection", "keep-alive", "proxy-connection"]);
// A room in one of these states is not asked again: the page says why, then the forwarder ends.
const FINAL = new Set(["removed", "new_room", "ended", "identity_changed"]);

const PAGES = {
    ended: [403, "Room ended", (host) => `${host} ended the room.`],
    removed: [403, "Removed from the room", (host) => `${host} removed you from this room. Ask ${host} for a new invite to join again.`],
    new_room: [403, "A new room", (host) => `${host} started a new room. Join it with its code: benchbar share join`],
    waiting: [403, "No seat yet", (host) => `${host} has not given you a seat yet. Ask ${host} for one, then load this page again.`],
    host_offline: [502, "Not sharing right now", (host) => `${host} isn't sharing right now.`],
    identity_changed: [403, "This room looks different", (host) => `${host}'s computer looks different from the one you joined. BenchBar did not connect. `
        + `If ${host} reset BenchBar, forget the room (benchbar share forget) and join again with a new code.`],
    not_available: [403, "Not available", () => "This page isn't available through BenchBar."]
};

const escapeHtml = (text) => text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

// The pages the forwarder serves itself when it cannot or must not relay: static, no script, no outside
// address; plain text for a client that does not take HTML.
function page(kind, host, acceptsHtml) {
    const [status, title, text] = PAGES[kind];
    const message = text(host);
    const body = Buffer.from(acceptsHtml
        ? `<!doctype html><html><head><meta charset="utf-8"><title>${escapeHtml(title)}</title></head><body><h1>${escapeHtml(title)}</h1><p>${escapeHtml(message)}</p></body></html>`
        : message + "\n", "utf8");
    const head = `HTTP/1.1 ${status} ${title}\r\nContent-Type: text/${acceptsHtml ? "html" : "plain"}; charset=utf-8\r\nContent-Length: ${body.length}\r\n`
        + "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n";
    return Buffer.concat([Buffer.from(head, "latin1"), body]);
}

// The check on a browser's request before one byte goes to the host. `expectedHost` is <name>:<port>.
// Exactly one Host equal to it; Origin absent or the same origin; no cross-site or same-site
// Sec-Fetch-Site; no Upgrade. The head goes on with "Connection: close", so one local connection carries
// one request and every request passes this check: a kept connection used again for a cross-site request
// would skip it.
function gate(buffer, expectedHost) {
    const refuse = (html = false) => ({ verdict: "refuse", html });
    const end = buffer.indexOf("\r\n\r\n");
    if (end < 0) return buffer.length > MAX_HEAD ? refuse() : { verdict: "more" };
    if (end > MAX_HEAD) return refuse();
    let head;
    try {
        head = new TextDecoder("utf-8", { fatal: true }).decode(buffer.subarray(0, end));
    } catch {
        return refuse();
    }
    const [requestLine, ...lines] = head.split("\r\n");
    const headers = [];
    for (const line of lines) {
        const colon = line.indexOf(":");
        if (colon < 0 || line.startsWith(" ") || line.startsWith("\t")) return refuse();
        headers.push([line.slice(0, colon).toLowerCase(), line.slice(colon + 1).trim()]);
    }
    const values = (name) => headers.filter(([n]) => n === name).map(([, v]) => v);
    const html = values("accept").some((v) => v.includes("text/html"));
    const hosts = values("host");
    const origins = values("origin");
    if (hosts.length !== 1 || hosts[0] !== expectedHost) return refuse(html);
    if (origins.length > 1 || (origins.length === 1 && origins[0] !== `http://${expectedHost}`)) return refuse(html);
    if (values("sec-fetch-site").some((v) => ["cross-site", "same-site"].includes(v.toLowerCase()))) return refuse(html);
    if (values("upgrade").length > 0) return refuse(html);
    const kept = lines.filter((line) => !HOP_BY_HOP.has(line.slice(0, line.indexOf(":")).toLowerCase()));
    const rewritten = [requestLine, ...kept, "Connection: close", "", ""].join("\r\n");
    return { verdict: "relay", html, head: Buffer.concat([Buffer.from(rewritten, "utf8"), buffer.subarray(end + 4)]) };
}

// `connect` returns a promise of a connection to the host that already passed the key check (guest.dial
// with the pin), or rejects with a Refusal (identity_changed, unreachable).
class Forwarder {
    constructor({ localHost, port, hostLabel, connect, now = Date.now, maxConnections = MAX_CONNECTIONS, idleMs = RELAY_IDLE_MS }) {
        Object.assign(this, { localHost, port, hostLabel, connect, now, idleMs });
        this.override = null;
        this.active = 0;
        this.lastActivity = now();
        this.server = net.createServer({ allowHalfOpen: true }, (local) => this.#accept(local));
        // beyond the cap a new connection is closed at once: a local process cannot use up the host's seats
        this.server.maxConnections = maxConnections;
    }

    get expectedHost() {
        return `${this.localHost}:${this.port}`;
    }

    // What the browser is handed: the gateway signs it in as this computer's seat.
    get url() {
        return `http://${this.expectedHost}/_benchbar/signin?next=/app`;
    }

    // The page shown in place of relaying (null: relay), set by the check of the room.
    show(kind) {
        this.override = kind;
    }

    idleFor() {
        return this.active > 0 ? 0 : this.now() - this.lastActivity;
    }

    // 127.0.0.1 only. A taken port moves on to the next of the range.
    async start() {
        for (let i = 0; i < PORT_TRIES; i++) {
            const bound = await new Promise((resolve) => {
                this.server.once("error", () => resolve(false));
                this.server.listen(this.port, "127.0.0.1", () => resolve(true));
            });
            if (bound) return this.port;
            this.server.removeAllListeners("error");
            this.port = guest.nextPort(this.port);
        }
        throw new guest.Refusal("no_port");
    }

    stop() {
        this.server.close();
        this.server.closeAllConnections?.();
    }

    #accept(local) {
        this.active++;
        this.lastActivity = this.now();
        let buffer = Buffer.alloc(0);
        let upstream = null;
        let over = false;
        const finish = () => {
            if (over) return;
            over = true;
            this.active--;
            this.lastActivity = this.now();
            local.destroy();
            if (upstream) upstream.destroy();
        };
        // what was written is flushed, then the browser has a moment to close its side
        const endLocal = (bytes) => {
            if (!local.writableEnded) local.end(bytes);
            local.setTimeout(CLOSE_WAIT_MS, finish);
        };
        local.on("error", finish);
        local.on("close", finish);
        local.setTimeout(HEAD_WAIT_MS, finish);
        const onData = (chunk) => {
            buffer = Buffer.concat([buffer, chunk]);
            const verdict = gate(buffer, this.expectedHost);
            if (verdict.verdict === "more") return;
            local.off("data", onData);
            local.pause();
            local.setTimeout(0);
            if (verdict.verdict === "refuse") return endLocal(page("not_available", this.hostLabel, verdict.html));
            if (this.override) return endLocal(page(this.override, this.hostLabel, verdict.html));
            this.connect().then((socket) => {
                if (over) return socket.destroy();
                upstream = socket;
                // "Connection: close" went upstream, so the host closing is the end of the exchange;
                // the browser closing only its sending side ends nothing.
                upstream.on("close", () => endLocal());
                upstream.write(verdict.head);
                local.pipe(upstream, { end: false });
                upstream.pipe(local, { end: false });
                // a stalled host or browser holds two sockets and a seat's slot: end both when nothing moves
                local.setTimeout(this.idleMs, finish);
                upstream.setTimeout(this.idleMs, finish);
            }, (refusal) => endLocal(page(refusal.code === "identity_changed" ? "identity_changed" : "host_offline", this.hostLabel, verdict.html)));
        };
        local.on("data", onData);
    }
}

// ---------------------------------------------------------------- the forwarder of one saved room, as a process

// A socket path holds about 100 characters, and the state folder of a checkout can be longer than that:
// a process that calls here() works in the guest folder and names its sockets relative to it.
let anchored = null;
function here(dir) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    process.chdir(dir);
    anchored = dir;
}
const sockPath = (dir, id) => (dir === anchored ? `${id}.sock` : path.join(dir, `${id}.sock`));

// One request to a running forwarder; null when none answers.
function ask(dir, id, op, timeoutMs = 15_000) {
    return new Promise((resolve) => {
        const client = net.connect(sockPath(dir, id));
        let buf = "";
        const done = (value) => { clearTimeout(timer); client.destroy(); resolve(value); };
        const timer = setTimeout(() => done(null), timeoutMs);
        client.on("error", () => done(null));
        client.on("connect", () => client.write(JSON.stringify({ op }) + "\n"));
        client.on("data", (chunk) => {
            buf += chunk;
            if (!buf.includes("\n")) return;
            try { done(JSON.parse(buf.slice(0, buf.indexOf("\n")))); } catch { done(null); }
        });
        client.on("close", () => done(null));
    });
}

async function run([dir, kind, security, id], { tickMs = HOUSEKEEPING_MS } = {}) {
    process.umask(0o077);
    here(dir);
    const room = guest.roomsStore(dir).load().find((r) => r.id === id);
    if (!room) throw new guest.Refusal("no_such_room");
    const pin = Buffer.from(room.host_fp.slice(7), "hex");
    const key = guest.keyStore({ kind, dir, security }).load(pin.toString("hex"));
    if (!key) throw new guest.Refusal("key_store");
    const identity = guest.identityOf(key);
    const connect = () => guest.dial({ host: room.address, port: room.port, pin, identity });
    const forwarder = new Forwarder({
        localHost: guest.localHost(room.room, guest.roomsStore(dir).suffix(), pin), port: room.local_port || guest.firstPort(pin), hostLabel: room.host, connect
    });
    const sock = sockPath(dir, id);

    const view = { state: "unknown", seat: null, site: room.site, deadline_epoch: null };
    let failures = 0;
    let pingTimer = null;
    let checking = null;
    const end = (code) => {
        forwarder.stop();
        fs.rmSync(sock, { force: true });
        process.exit(code);
    };

    // 403 not_paired is "removed", or a new room after the host started again: only the salt of the code,
    // which anyone may read, tells them apart.
    const sameRoom = async () => {
        try {
            const socket = await connect();
            try { return (await guest.roomHello(socket)).salt === room.salt; } finally { socket.destroy(); }
        } catch {
            return true;
        }
    };
    const check = async () => {
        let socket = null;
        try {
            socket = await connect();
            const hello = await guest.call(socket, "GET", "/_benchbar/hello");
            failures = 0;
            Object.assign(view, {
                state: hello.user_label ? "ready" : "waiting", seat: typeof hello.user_label === "string" ? guest.clean(hello.user_label) : null,
                site: guest.clean(hello.site_label) || view.site, deadline_epoch: Number.isInteger(hello.deadline_epoch) ? hello.deadline_epoch : null
            });
        } catch (refusal) {
            failures++;
            if (refusal.code === "removed") view.state = (await sameRoom()) ? "removed" : "new_room";
            else if (refusal.code === "ended" || refusal.code === "identity_changed") view.state = refusal.code;
            else view.state = "offline";
        } finally {
            if (socket) socket.destroy();
        }
        forwarder.show(view.state === "waiting" || FINAL.has(view.state) ? view.state : null);
    };
    // 10 s between checks, doubled after each one that got no answer, never later than 5 minutes.
    const schedule = () => {
        clearTimeout(pingTimer);
        if (FINAL.has(view.state)) {
            pingTimer = setTimeout(() => end(0), LINGER_MS);
            return;
        }
        pingTimer = setTimeout(checkNow, Math.min(PING_MS * 2 ** Math.min(failures, 10), PING_MAX_MS));
    };
    const checkNow = () => {
        checking ??= check().finally(() => { checking = null; schedule(); });
        return checking;
    };

    // The control socket is listened on first and is the one lock of this room's forwarder: whoever binds
    // it is the forwarder. A socket that is there and answers belongs to a running one (already_running);
    // one that does not answer is left from a process that died, and is replaced under a lock so that two
    // processes starting together do not both take it. Nothing is answered before the port is bound.
    let ready = null;
    const status = () => ({ ok: true, pid: process.pid, port: forwarder.port, url: forwarder.url, ...view });
    const control = net.createServer((client) => {
        let buf = "";
        client.on("error", () => client.destroy());
        client.setTimeout(20_000, () => client.destroy());
        client.on("data", async (chunk) => {
            buf += chunk;
            if (!buf.includes("\n") || buf.length > 1024) return buf.length > 1024 ? client.destroy() : undefined;
            let op = null;
            try { op = JSON.parse(buf.slice(0, buf.indexOf("\n"))).op; } catch { /* answered as unknown */ }
            buf = "";
            await ready;
            if (op === "ping" && !FINAL.has(view.state)) await checkNow();
            client.end(JSON.stringify(["status", "ping", "stop"].includes(op) ? status() : { ok: false }) + "\n", () => { if (op === "stop") end(0); });
        });
    });
    const listen = () => new Promise((resolve) => {
        control.once("error", (e) => resolve(e));
        control.listen(sock, () => { control.removeAllListeners("error"); resolve(null); });
    });
    let bound = await listen();
    if (bound && bound.code === "EADDRINUSE") {
        bound = await guest.locked(`${sock}.clean`, async () => {
            if (await ask(dir, id, "status", 2_000)) throw new guest.Refusal("already_running");
            fs.rmSync(sock, { force: true });
            return listen();
        }, { staleMs: 15_000, timeoutMs: 10_000 });
    }
    if (bound) throw bound;
    ready = forwarder.start();
    ready.catch(() => {});
    try {
        fs.chmodSync(sock, 0o600);
        await ready;
    } catch (e) {
        fs.rmSync(sock, { force: true });
        throw e;
    }

    for (const signal of ["SIGTERM", "SIGINT"]) process.on(signal, () => end(0));
    // nothing reads this process's output: an error nobody caught closes the address and the socket
    process.on("uncaughtException", () => end(1));
    process.on("SIGHUP", () => {});
    // idle for 15 minutes, or the socket is gone (the guest folder was deleted): nothing could stop it any more
    setInterval(() => { if (forwarder.idleFor() >= IDLE_LIMIT_MS || !fs.existsSync(sock)) end(0); }, tickMs);
    await checkNow();
}

if (require.main === module) {
    run(process.argv.slice(2)).catch((e) => {
        process.stderr.write(`guest-forward: ${e instanceof guest.Refusal ? e.code : e.code || e.name}\n`);
        process.exit(1);
    });
}

module.exports = { Forwarder, gate, page, ask, here, sockPath, run, IDLE_LIMIT_MS };
