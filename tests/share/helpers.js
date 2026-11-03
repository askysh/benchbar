"use strict";
const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const https = require("node:https");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const tls = require("node:tls");
const { spawn, spawnSync } = require("node:child_process");
const cpace = require("../../lib/frappe-local/share/cpace.js");
const { spkiFingerprint } = cpace;

const OPENSSL = "/usr/bin/openssl";
const GATEWAY_JS = path.join(__dirname, "../../lib/frappe-local/share/gateway.js");
const HARNESS_JS = path.join(__dirname, "gateway_harness.js");
const SID = "SIDSECRET0123456789abcdef0123456789ab";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Short names: a unix socket path is limited to 104 characters on macOS.
const tmpDir = () => fs.mkdtempSync(path.join(os.tmpdir(), "bg-"));

let paramsFile = null;
function makeCert(dir, name) {
    if (!paramsFile) {
        paramsFile = path.join(tmpDir(), "p.pem");
        const r = spawnSync(OPENSSL, ["ecparam", "-name", "prime256v1", "-out", paramsFile]);
        if (r.status !== 0) throw new Error("openssl ecparam failed");
    }
    const keyFile = path.join(dir, `${name}.key`);
    const certFile = path.join(dir, `${name}.crt`);
    const r = spawnSync(OPENSSL, ["req", "-x509", "-newkey", `ec:${paramsFile}`, "-nodes", "-keyout", keyFile, "-out", certFile,
        "-subj", `/CN=${name}`, "-days", "2"]);
    if (r.status !== 0) throw new Error("openssl req failed");
    const cert = fs.readFileSync(certFile, "utf8");
    const fp = spkiFingerprint(new crypto.X509Certificate(cert).publicKey.export({ type: "spki", format: "der" }));
    return { key: fs.readFileSync(keyFile, "utf8"), cert, keyFile, certFile, fp };
}

function freePort() {
    return new Promise((resolve, reject) => {
        const s = net.createServer();
        s.listen(0, "127.0.0.1", () => {
            const { port } = s.address();
            s.close(() => resolve(port));
        });
        s.on("error", reject);
    });
}

async function startUpstream({ port: wanted } = {}) {
    const hits = [];
    const server = http.createServer((req, res) => {
        const chunks = [];
        req.on("data", (c) => chunks.push(c));
        req.on("end", () => {
            hits.push({ method: req.method, url: req.url, headers: req.headers, rawHeaders: req.rawHeaders, body: Buffer.concat(chunks) });
            if (req.url === "/slow") return;
            // a live web process that drops one request: the connection is reset, the server keeps listening
            if (req.url.startsWith("/app/reset")) return req.socket.destroy();
            res.writeHead(200, { "Content-Type": "text/plain", "Set-Cookie": "up=1; Path=/" });
            res.end("upstream-ok");
        });
    });
    const port = wanted || (await freePort());
    await new Promise((r) => server.listen(port, "127.0.0.1", r));
    return { port, hits, close: () => { server.closeAllConnections(); return new Promise((r) => server.close(r)); } };
}

// Fake sign-in helper: records its argv, prints a known sid; user "failuser" fails.
// `wipe SITE USER` prints nothing; wiping "wipefail" fails.
function writeFakeHelper(dir) {
    const file = path.join(dir, "fake-helper.js");
    const log = path.join(dir, "helper-argv.jsonl");
    fs.writeFileSync(file, `"use strict";
const fs = require("fs");
const wipe = process.argv[2] === "wipe";
const user = wipe ? process.argv[4] : process.argv[3];
// Users named slow* take 300 ms, and are logged when they finish, so tests can see the order of completion.
if (/^slow/.test(user)) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 300);
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify(process.argv.slice(2)) + "\\n");
if (wipe) process.exit(user === "wipefail@example.com" ? 1 : 0);
if (user === "failuser") { process.stderr.write("boom-" + ${JSON.stringify(SID)}); process.exit(1); }
process.stdout.write(${JSON.stringify(SID)} + "\\n");
`);
    return { file, log, calls: () => (fs.existsSync(log) ? fs.readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []) };
}

const SEATS = [1, 2, 3, 4, 5, 6].map((n) => ({ seat_id: `seat${n}`, user: `seat${n}@example.com`, full_name: `Seat ${n}`, roles: ["Sales User"] }));

function writeDevices(file, devices, blocked = []) {
    fs.writeFileSync(file, JSON.stringify({ v: 3, devices, blocked }, null, 2), { mode: 0o600 });
}
let deviceCounter = 0;
function deviceRow(cert, extra = {}) {
    deviceCounter++;
    const n = String(deviceCounter).padStart(8, "0");
    const iso = new Date().toISOString();
    return { id: `d_${n}`, name: `Mac ${n}`, model: "MacBookPro18,1", fp: cert.fp, status: "active", user: "seat1@example.com", seat_id: "seat1",
        paired_ip: "192.168.1.9", added: iso, last_seen: iso, ...extra };
}

// Spawns the gateway through gateway_harness.js, which injects the test clock, tick and peer-IP header.
// `production: true` runs gateway.js itself under NODE_ENV=test, to prove it honours none of them.
async function startGateway(opts = {}) {
    const dir = tmpDir();
    const stateDir = path.join(dir, "st");
    const logDir = path.join(dir, "lg");
    fs.mkdirSync(stateDir, { mode: 0o700 });
    const host = makeCert(dir, "host");
    const upstream = opts.upstream || (await startUpstream());
    const helper = writeFakeHelper(dir);
    const port = await freePort();
    const nowS = Math.floor(Date.now() / 1000);
    const cfg = {
        v: 3, protocol: 3, listen: { host: "127.0.0.1", port },
        tls: { key: host.keyFile, cert: host.certFile },
        share_site: "share.localhost", web_port: upstream.port,
        deadline_epoch: nowS + 3600, started_epoch: nowS - 10, max_total_s: 43200,
        state_dir: stateDir, devices: path.join(stateDir, "devices.json"), control_sock: path.join(dir, "c.sock"), log_dir: logDir,
        python: process.execPath, signin_helper: helper.file,
        max_conns: { per_device: 64, total: 256, unpaired_total: 16, unpaired_per_ip: 4 },
        max_body_mb: 1, label: "Test Host", room_label: "Test Room", site_label: "macdev", seats: SEATS, copy_made: "2026-11-02T09:00:00.000Z",
        ...(opts.config || {})
    };
    for (const k of opts.omit || []) delete cfg[k];
    const cfgFile = path.join(dir, "gateway.json");
    fs.writeFileSync(cfgFile, JSON.stringify(cfg), { mode: 0o600 });
    const clockFile = path.join(dir, "clock");
    fs.writeFileSync(clockFile, "0");

    const child = spawn(process.execPath, [opts.production ? GATEWAY_JS : HARNESS_JS, cfgFile], {
        env: { ...process.env, NODE_ENV: "test", FL_SHARE_TEST_CLOCK_FILE: clockFile, FL_SHARE_TEST_TICK_MS: String(opts.tickMs || 100) },
        stdio: ["ignore", "pipe", "pipe"]
    });
    let output = "";
    child.stdout.on("data", (d) => (output += d));
    child.stderr.on("data", (d) => (output += d));
    const exited = new Promise((resolve) => child.on("exit", (code, signal) => resolve({ code, signal })));

    const gw = {
        dir, stateDir, logDir, cfg, cfgFile, host, upstream, helper, port, child, exited, clockFile,
        output: () => output,
        seats: cfg.seats,
        devicesFile: cfg.devices,
        jump: (ms) => fs.writeFileSync(clockFile, String(ms)),
        control: (msg) => controlCall(cfg.control_sock, msg),
        async stop() {
            if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
            await exited;
            if (!opts.upstream) await upstream.close();
        }
    };
    if (opts.expectExit) return gw;
    for (let i = 0; i < 100; i++) {
        if (child.exitCode !== null) throw new Error(`gateway exited early (${child.exitCode}): ${output}`);
        try {
            const r = await controlCall(cfg.control_sock, { op: "status" });
            // The gateway empties devices.json when it starts, so test rows go in once it is up.
            if (r.ok) {
                if (opts.devices) writeDevices(cfg.devices, opts.devices, opts.blocked);
                // the gateway starts with the web marked down; the share runner marks it up after its checks
                if (!opts.webDown) await controlCall(cfg.control_sock, { op: "web", state: "up" });
                return gw;
            }
        } catch { /* not up yet */ }
        await sleep(50);
    }
    throw new Error(`gateway did not come up: ${output}`);
}

function controlCall(sock, msg) {
    return new Promise((resolve, reject) => {
        const c = net.connect(sock);
        let buf = "";
        c.on("data", (d) => {
            buf += d;
            const nl = buf.indexOf("\n");
            if (nl >= 0) { c.destroy(); try { resolve(JSON.parse(buf.slice(0, nl))); } catch (e) { reject(e); } }
        });
        c.on("error", reject);
        c.on("close", () => { if (!buf.includes("\n")) reject(new Error("control closed without a reply")); });
        c.write(JSON.stringify(msg) + "\n");
    });
}

// One HTTPS request with an optional client certificate. `agent` lets a test keep a connection alive.
function request(gw, { method = "GET", path: p = "/", headers = {}, body, cert, agent, timeout = 8000, ip, onReq } = {}) {
    return new Promise((resolve, reject) => {
        const h = { host: "share.localhost:8443", ...headers };
        if (ip) h["x-test-peer-ip"] = ip;
        if (body !== undefined && h["content-length"] === undefined) h["content-length"] = Buffer.byteLength(body);
        const req = require("node:https").request({
            host: "127.0.0.1", port: gw.port, method, path: p, headers: h, agent: agent === undefined ? false : agent,
            rejectUnauthorized: false, minVersion: "TLSv1.3", maxVersion: "TLSv1.3", ALPNProtocols: ["http/1.1"],
            key: cert && cert.key, cert: cert && cert.cert, timeout
        }, (res) => {
            const socket = res.socket;
            const chunks = [];
            res.on("data", (c) => chunks.push(c));
            res.on("end", () => {
                const text = Buffer.concat(chunks).toString("utf8");
                let json = null;
                try { json = JSON.parse(text); } catch { /* not JSON */ }
                resolve({ status: res.statusCode, headers: res.headers, text, json, socket });
            });
            res.on("error", reject);
        });
        if (onReq) onReq(req);
        req.on("timeout", () => req.destroy(new Error("client timeout")));
        req.on("error", reject);
        if (body !== undefined) req.write(body);
        req.end();
    });
}

// Hand-written bytes over TLS: duplicate headers, absolute-form targets, upgrades.
function rawTls(gw, bytes, { cert, waitMs = 1500 } = {}) {
    return new Promise((resolve) => {
        let out = "";
        const s = tls.connect({ host: "127.0.0.1", port: gw.port, rejectUnauthorized: false, minVersion: "TLSv1.3", maxVersion: "TLSv1.3",
            ALPNProtocols: ["http/1.1"], key: cert && cert.key, cert: cert && cert.cert }, () => s.write(bytes));
        const done = () => { s.destroy(); resolve({ text: out, status: Number((/^HTTP\/1\.1 (\d{3})/.exec(out) || [])[1]) || 0 }); };
        s.on("data", (d) => (out += d));
        s.on("error", done);
        s.on("close", done);
        setTimeout(done, waitMs);
    });
}

const sinkAgent = (c) => new https.Agent({
    keepAlive: true, maxSockets: 1, key: c && c.key, cert: c && c.cert, rejectUnauthorized: false, minVersion: "TLSv1.3", maxVersion: "TLSv1.3"
});

const serverSpkiRaw = (socket) => cpace.spkiRaw(new crypto.X509Certificate(socket.getPeerCertificate().raw).publicKey.export({ type: "spki", format: "der" }));
const exporterOf = (socket) => socket.exportKeyingMaterial(32, cpace.EXPORTER_LABEL, Buffer.alloc(0));

// The guest side of a join over real TLS. Each stage is a method so a test can tamper between them.
class GuestSession {
    constructor(gw, cert, { ip = "10.20.0.1", name = "Priya's Mac", model = "Mac14,2", agent = sinkAgent(cert) } = {}) {
        Object.assign(this, { gw, cert, ip, name, model, agent });
    }

    async hello() {
        const r = await request(this.gw, { path: "/room/hello", cert: this.cert, agent: this.agent, ip: this.ip });
        this.helloReply = r;
        return r;
    }

    // Computes g from `code` and the published salt, sends Ya, and derives the keys from Yb.
    async start(code, { hostFpRaw } = {}) {
        if (!this.helloReply) await this.hello();
        const h = this.helloReply;
        this.g = cpace.calculateGenerator(Buffer.from(code, "ascii"), Buffer.from(h.json.salt, "hex"), Buffer.alloc(0));
        this.ya = crypto.randomBytes(32);
        this.Ya = cpace.scalarMult(this.ya, this.g);
        this.fh = hostFpRaw || serverSpkiRaw(h.socket);
        const r = await request(this.gw, {
            method: "POST", path: "/room/join/start", cert: this.cert, agent: this.agent, ip: this.ip,
            body: JSON.stringify({ v: 3, name: this.name, model: this.model, Ya: this.Ya.toString("hex") })
        });
        this.startReply = r;
        if (r.status === 200) {
            this.id = r.json.request_id;
            this.Yb = Buffer.from(r.json.Yb, "hex");
            this.ada = cpace.adGuest(this.name, this.model);
            this.adb = cpace.adHost(h.json.room, this.id);
            const isk = cpace.isk(Buffer.alloc(0), cpace.scalarMult(this.ya, this.Yb), this.Ya, this.ada, this.Yb, this.adb);
            this.mac = cpace.macKey(Buffer.alloc(0), isk);
        }
        return r;
    }

    tag(role, exporter, fg = this.cert.fp) {
        return cpace.tag(this.mac, role, this.Ya, this.ada, this.Yb, this.adb, this.fh, Buffer.from(fg.slice(7), "hex"), exporter);
    }

    // `socket` is the connection finish goes out on: its exporter is what Ta commits to.
    async finish({ socket, ta, requestId = this.id, agent = this.agent, cert = this.cert } = {}) {
        const sock = socket || this.helloReply.socket;
        const body = { v: 3, request_id: requestId, Ta: (ta || this.tag("guest", exporterOf(sock))).toString("hex") };
        const r = await request(this.gw, { method: "POST", path: "/room/join/finish", cert, agent, ip: this.ip, body: JSON.stringify(body) });
        this.finishReply = r;
        this.finishExporter = exporterOf(sock);
        return r;
    }

    tbValid() {
        return cpace.verifyTag(this.tag("host", this.finishExporter), Buffer.from(this.finishReply.json.Tb, "hex"));
    }

    async join(code) {
        const s = await this.start(code);
        if (s.status !== 200) return s;
        return this.finish();
    }

    close() {
        this.agent.destroy();
    }
}

const roomCode = async (gw) => (await gw.control({ op: "code" })).code;

module.exports = {
    OPENSSL, SID, sleep, tmpDir, makeCert, freePort, startUpstream, writeFakeHelper, writeDevices, deviceRow, startGateway,
    controlCall, request, rawTls, sinkAgent, GuestSession, roomCode, serverSpkiRaw, exporterOf, SEATS
};
