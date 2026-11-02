"use strict";
const fs = require("fs");
const net = require("net");

const MAX_LINE_BYTES = 4096;
const IDLE_MS = 10_000;
const MAX_EXTEND_S = 86_400;
// Only these codes cross the socket; any other error is "internal" so no message text can carry a secret.
const RELAYED_ERRORS = new Set(["schema", "not_found", "user_taken", "duplicate", "lock"]);

const isId = (v, prefix) => typeof v === "string" && new RegExp(`^${prefix}_[0-9a-f]{8,16}$`).test(v);

function bad() {
    return { ok: false, error: "bad_request" };
}

// api methods may be async and return the reply object; a throw becomes {ok:false,error}.
function buildOps(api) {
    return {
        status: () => api.status(),
        pending: () => ({ ok: true, pending: api.pending() }),
        approve: (m) => (isId(m.id, "r") && typeof m.code === "string" && typeof m.user === "string" ? api.approve(m) : bad()),
        deny: (m) => (isId(m.id, "r") ? api.deny(m.id) : bad()),
        devices: () => ({ ok: true, devices: api.devices() }),
        assign: (m) => (isId(m.device, "d") && typeof m.user === "string" ? api.assign(m.device, m.user) : bad()),
        revoke: (m) => (isId(m.device, "d") ? api.revoke(m.device) : bad()),
        extend: (m) => (Number.isInteger(m.seconds) && m.seconds >= 1 && m.seconds <= MAX_EXTEND_S ? api.extend(m.seconds) : bad()),
        stop: () => api.stop()
    };
}

async function dispatch(ops, api, line) {
    let msg;
    try {
        msg = JSON.parse(line);
    } catch {
        return bad();
    }
    if (msg === null || typeof msg !== "object" || Array.isArray(msg) || typeof msg.op !== "string") return bad();
    if (!Object.hasOwn(ops, msg.op)) return { ok: false, error: "unknown_op" };
    // After a sleep the deadline may already have passed: no op may act (extend least of all); shutdown proceeds.
    if (api.expired()) return { ok: false, error: "ended" };
    try {
        return await ops[msg.op](msg);
    } catch (e) {
        return { ok: false, error: RELAYED_ERRORS.has(e && e.code) ? e.code : "internal" };
    }
}

function isLive(sockPath) {
    return new Promise((resolve) => {
        const c = net.connect(sockPath);
        c.on("connect", () => { c.destroy(); resolve(true); });
        c.on("error", () => resolve(false));
    });
}

// One JSON object per line in, one reply per line out. The socket is created
// under the caller's umask 077 and chmod-ed again, so it is never wider than 0600.
async function serve(sockPath, api) {
    if (fs.existsSync(sockPath)) {
        if (await isLive(sockPath)) throw new Error("another gateway already owns the control socket");
        fs.rmSync(sockPath, { force: true });
    }
    const ops = buildOps(api);
    const sockets = new Set();
    const server = net.createServer((socket) => {
        sockets.add(socket);
        socket.on("close", () => sockets.delete(socket));
        socket.on("error", () => socket.destroy());
        socket.setTimeout(IDLE_MS, () => socket.destroy());
        let buf = "";
        let chain = Promise.resolve();
        socket.on("data", (chunk) => {
            buf += chunk;
            if (buf.length > MAX_LINE_BYTES && !buf.includes("\n")) return socket.destroy();
            let nl;
            while ((nl = buf.indexOf("\n")) >= 0) {
                const line = buf.slice(0, nl);
                buf = buf.slice(nl + 1);
                chain = chain.then(async () => {
                    const reply = await dispatch(ops, api, line);
                    if (!socket.destroyed) socket.write(JSON.stringify(reply) + "\n");
                });
            }
        });
    });
    await new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(sockPath, resolve);
    });
    fs.chmodSync(sockPath, 0o600);
    return {
        close() {
            for (const s of sockets) s.destroy();
            server.close();
            fs.rmSync(sockPath, { force: true });
        }
    };
}

module.exports = { serve };
