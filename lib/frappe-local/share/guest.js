"use strict";
// The guest side of a room (protocol v3) for the CLI: benchbar share join. It is the exchange of the Mac
// app's RoomJoin.swift and of tests/share/helpers.js GuestSession, done with the gateway's own cpace.js:
// the invite, a TLS dial that checks the host's key before one byte is written, hello, start and finish
// on one connection, the calls of a joined guest, this computer's key for a host, and the saved rooms.
// The room code and the keys never leave this process but to the host (the tags) and the key store.
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const tls = require("tls");
const { spawnSync } = require("child_process");
const cpace = require("./cpace.js");

const PROTOCOL = 3;
const NAME_MAX = 40;
const MODEL_MAX = 32;
const LABEL_MAX = 40;
const START_DELAY_MS = 250;          // J8: start goes out no earlier than this after the hello reply
const TIMEOUT_MS = 8_000;
const REPLY_MAX = 256 * 1024;
const HOST_HEADER = "room.localhost";
const NO_SID = Buffer.alloc(0);
const PORT_FIRST = 41000;
const PORT_COUNT = 1000;
const KEYCHAIN_SERVICE = "benchbar-share-guest";
const KEYCHAIN_NOT_FOUND = 44;
const UNSAFE = /[\u{0}-\u{1f}\u{7f}-\u{9f}\u{2028}\u{2029}\u{200b}-\u{200f}\u{202a}-\u{202e}\u{2060}-\u{2064}\u{2066}-\u{2069}\u{feff}]/gu;
const INVITE_LINK = /benchbar:\/\/share\/join\?[^\s<>"|`]+/i;
const HEX32 = /^[0-9a-f]{32}$/;
const HEX64 = /^[0-9a-f]{64}$/;
const HEX128 = /^[0-9a-f]{128}$/;

// Why something did not happen. `code` is a word of the list the CLI has a sentence for; it never
// carries the room code or anything derived from it.
class Refusal extends Error {
    constructor(code, extra = {}) {
        super(code);
        Object.assign(this, { code }, extra);
    }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// What the host chose (a room's label, its own name): shown like a Bonjour TXT record, never with control,
// bidirectional or zero width characters.
function clean(text) {
    const kept = String(text ?? "").replace(UNSAFE, " ").split(/\s+/u).filter(Boolean).join(" ");
    return Array.from(kept).slice(0, LABEL_MAX).join("");
}

// The host counts JavaScript string length (UTF-16 units); a pair is never cut in two.
function clip(text, max) {
    let out = "";
    for (const ch of String(text)) {
        if (out.length + ch.length > max) break;
        out += ch;
    }
    return out;
}

// Exactly six ASCII digits once spaces are gone (J13).
function normalizeCode(typed) {
    const digits = String(typed ?? "").replaceAll(" ", "");
    return /^[0-9]{6}$/.test(digits) ? digits : null;
}

function parseAddress(text) {
    const m = /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3}):([0-9]{1,5})$/.exec(String(text ?? ""));
    if (!m || m.slice(1, 5).some((o) => Number(o) > 255) || Number(m[5]) < 1 || Number(m[5]) > 65535) return null;
    return { host: m.slice(1, 5).map(Number).join("."), port: Number(m[5]) };
}

// A room is on the network this computer is on, and a link can come from anywhere. So an address is
// dialled only when it is one of a local network: private, link-local or carrier NAT (a phone hotspot,
// a mesh VPN).
function isLocalNetwork(host) {
    // four plain octets only, as ShareInvite.isLocalNetwork: no short, hexadecimal or named form
    if (!/^[0-9]{1,3}(\.[0-9]{1,3}){3}$/.test(String(host))) return false;
    const [a, b, c, d] = String(host).split(".").map(Number);
    if (c > 255 || d > 255) return false;
    return a === 10 || (a === 192 && b === 168) || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 100 && b >= 64 && b <= 127);
}

// benchbar://share/join?v=1&r=&h=&s=&c=&a=&x= (invite v1), the first one in `text`: a chat may wrap it in
// <...>, quotes or <...|label>, or end the sentence after it. The query is split by hand: a + stays a +,
// as in the Mac app's parser, and a second h or c is refused (another parser could read the other one).
function parseInvite(text) {
    const found = INVITE_LINK.exec(String(text ?? ""));
    if (!found) throw new Refusal("invite_not_found");
    const link = found[0].replace(/[.,;:!?)']+$/, "");
    if (link.includes("#")) throw new Refusal("invite_malformed");
    const values = new Map();
    for (const item of link.slice(link.indexOf("?") + 1).split("&")) {
        const cut = item.indexOf("=");
        let name, value;
        try {
            name = decodeURIComponent(cut < 0 ? item : item.slice(0, cut));
            value = cut < 0 ? "" : decodeURIComponent(item.slice(cut + 1));
        } catch {
            throw new Refusal("invite_malformed");
        }
        if (!"vrhscax".includes(name) || name.length !== 1) continue;
        if (values.has(name)) throw new Refusal("invite_malformed");
        values.set(name, value);
    }
    if (!values.has("v")) throw new Refusal("invite_malformed");
    if (values.get("v") !== "1") throw new Refusal("invite_newer");
    const room = clean(values.get("r"));
    const host = String(values.get("h") ?? "").toLowerCase();
    const salt = String(values.get("s") ?? "").toLowerCase();
    const code = normalizeCode(values.get("c"));
    const expires = /^[0-9]{1,15}$/.test(values.get("x") ?? "") ? Number(values.get("x")) : 0;
    if (!room || !HEX64.test(host) || !HEX32.test(salt) || !code || values.get("c").length !== 6 || expires <= 0) throw new Refusal("invite_malformed");
    const invite = { room, hostPin: Buffer.from(host, "hex"), salt, address: parseAddress(values.get("a")), expires };
    // not enumerable: a log, a JSON document or an inspect of the invite never shows the code
    Object.defineProperty(invite, "code", { value: code, enumerable: false });
    return invite;
}

// The key (SPKI SHA-256, raw) of the certificate a connection showed.
function spkiOf(socket) {
    return cpace.spkiRaw(new crypto.X509Certificate(socket.getPeerCertificate().raw).publicKey.export({ type: "spki", format: "der" }));
}

// A TLS 1.3 connection to a room. The host's certificate is self-signed and its key is the one identity
// it has, so the chain and the name are not checked; the key is: with `pin`, a host that shows another
// key is refused here, before anything is written. Without `pin` the key is only read (socket.bbSpki):
// the first look at a room, which shows no certificate and sends nothing derived from the code.
//
// Under TLS 1.3 the client's certificate goes out with the client's Finished, before secureConnect fires on
// this side: the host has seen this computer's key by the time the pin is compared, though no application
// byte has been written. So a key may only be shown to a host that is pinned, and an identity without a
// pin is refused: the first look at a room shows no certificate.
function dial({ host, port, pin = null, identity = null, timeoutMs = TIMEOUT_MS }) {
    return new Promise((resolve, reject) => {
        if (identity && !pin) return reject(new Refusal("failed"));
        let settled = false;
        const socket = tls.connect({
            host, port, rejectUnauthorized: false, minVersion: "TLSv1.3", maxVersion: "TLSv1.3", ALPNProtocols: ["http/1.1"],
            key: identity ? identity.key : undefined, cert: identity ? identity.cert : undefined
        });
        const fail = (code) => {
            socket.destroy();
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            reject(new Refusal(code));
        };
        const timer = setTimeout(() => fail("unreachable"), timeoutMs);
        socket.on("error", () => fail("unreachable"));
        socket.once("secureConnect", () => {
            let spki;
            try {
                spki = spkiOf(socket);
            } catch {
                return fail("unreachable");
            }
            if (pin && !(pin.length === spki.length && crypto.timingSafeEqual(pin, spki))) return fail("identity_changed");
            settled = true;
            clearTimeout(timer);
            socket.bbSpki = spki;
            resolve(socket);
        });
    });
}

// One request and its reply on a connection from dial(): the gateway's JSON answers carry a Content-Length.
function exchange(socket, method, pathname, body = null, timeoutMs = TIMEOUT_MS) {
    return new Promise((resolve, reject) => {
        let buf = Buffer.alloc(0);
        const done = (err, value) => {
            clearTimeout(timer);
            socket.off("data", onData);
            socket.off("close", onClose);
            if (err) reject(err);
            else resolve(value);
        };
        const onClose = () => done(new Refusal("unreachable"));
        const onData = (chunk) => {
            buf = Buffer.concat([buf, chunk]);
            if (buf.length > REPLY_MAX) return done(new Refusal("failed"));
            const end = buf.indexOf("\r\n\r\n");
            if (end < 0) return;
            const head = buf.subarray(0, end).toString("latin1").split("\r\n");
            const status = Number((/^HTTP\/1\.1 ([0-9]{3})/.exec(head[0]) || [])[1]);
            const headers = {};
            for (const line of head.slice(1)) {
                const colon = line.indexOf(":");
                if (colon > 0) headers[line.slice(0, colon).toLowerCase()] = line.slice(colon + 1).trim();
            }
            const length = Number(headers["content-length"]);
            if (!status || !Number.isInteger(length) || length < 0) return done(new Refusal("failed"));
            if (buf.length < end + 4 + length) return;
            let json = null;
            try {
                json = JSON.parse(buf.subarray(end + 4, end + 4 + length).toString("utf8"));
            } catch { /* not JSON: the status alone decides */ }
            done(null, { status, headers, json: json !== null && typeof json === "object" ? json : null });
        };
        const timer = setTimeout(() => done(new Refusal("unreachable")), timeoutMs);
        socket.on("data", onData);
        socket.once("close", onClose);
        if (socket.destroyed) return onClose();
        const payload = body === null ? null : Buffer.from(JSON.stringify(body), "utf8");
        const head = `${method} ${pathname} HTTP/1.1\r\nHost: ${HOST_HEADER}\r\nAccept: application/json\r\n`
            + (payload ? `Content-Type: application/json\r\nContent-Length: ${payload.length}\r\n` : "") + "\r\n";
        socket.write(payload ? Buffer.concat([Buffer.from(head, "latin1"), payload]) : head);
    });
}

const reasonOf = (reply) => (reply.json && (reply.json.status ?? reply.json.error)) || null;

function retryAfter(reply) {
    const seconds = Number((reply.json && reply.json.retry_after) ?? reply.headers["retry-after"]);
    return Number.isInteger(seconds) && seconds > 0 ? seconds : 60;
}

// Mapped on the body's word, since the gateway reuses HTTP codes (403, 409).
function joinRefusal(reply) {
    if (reply.status === 426) return new Refusal("needs_update");
    if (reply.status === 429) return new Refusal("rate_limited", { retryAfter: retryAfter(reply) });
    if (reply.status === 423) return new Refusal("locked");
    const reason = reasonOf(reply);
    if (["wrong_code", "blocked", "full", "already_joined"].includes(reason)) return new Refusal(reason);
    return new Refusal(reason === "unknown_request" || reason === "expired" ? "expired" : "failed");
}

function validHello(h) {
    return Boolean(h) && Number.isInteger(h.v) && typeof h.room === "string" && typeof h.host === "string" && typeof h.site === "string" && typeof h.salt === "string"
        && typeof h.locked === "boolean" && typeof h.full === "boolean" && Number.isInteger(h.people) && Number.isInteger(h.seats);
}

// GET /room/hello, before any join: the room's words, its state, and the salt of its code.
async function roomHello(socket) {
    const reply = await exchange(socket, "GET", "/room/hello");
    if (reply.status === 429) throw new Refusal("rate_limited", { retryAfter: retryAfter(reply) });
    if (reply.status !== 200 || !validHello(reply.json)) throw new Refusal("failed");
    return reply.json;
}

// The join, on one connection from dial(): Ta commits to that connection's exporter and to the key its
// handshake showed (J11, J16), and the host's key is taken as proven only once Tb verified.
// `fg` is the raw SPKI hash of the certificate this connection presented. With `invite`, the key is
// compared before the hello and the salt right after it, so a wrong room or a stale invite stops before
// anything derived from the code is sent, and the host's wrong code budget is untouched.
async function join(socket, { code: typed, name, model, fg, invite = null, wait = sleep, randomScalar = () => crypto.randomBytes(32) }) {
    const code = normalizeCode(typed);
    if (!code) throw new Refusal("invalid_code");
    const fh = socket.bbSpki;
    if (invite && !fh.equals(invite.hostPin)) throw new Refusal("not_the_invited_room");
    const hello = await roomHello(socket);
    const answered = Date.now();
    if (hello.v !== PROTOCOL) throw new Refusal("needs_update");
    if (invite && hello.salt.toLowerCase() !== invite.salt) throw new Refusal("invite_out_of_date");
    if (hello.locked) throw new Refusal("locked");
    if (hello.full) throw new Refusal("full");
    if (!HEX32.test(hello.salt)) throw new Refusal("failed");

    const guestName = clip(name, NAME_MAX);
    const guestModel = clip(model, MODEL_MAX);
    let ya, Ya;
    try {
        const generator = cpace.calculateGenerator(Buffer.from(code, "ascii"), Buffer.from(hello.salt, "hex"), NO_SID);
        ya = randomScalar();
        Ya = cpace.scalarMult(ya, generator);
    } catch {
        throw new Refusal("failed");
    }
    await wait(Math.max(0, START_DELAY_MS - (Date.now() - answered)));
    const startReply = await exchange(socket, "POST", "/room/join/start", { v: PROTOCOL, name: guestName, model: guestModel, Ya: Ya.toString("hex") });
    if (startReply.status !== 200) throw joinRefusal(startReply);
    const started = startReply.json;
    if (!started || typeof started.request_id !== "string" || !HEX64.test(started.Yb)) throw new Refusal("failed");

    let tag;
    try {
        const Yb = Buffer.from(started.Yb, "hex");
        const ada = cpace.adGuest(guestName, guestModel);
        const adb = cpace.adHost(hello.room, started.request_id);
        const macKey = cpace.macKey(NO_SID, cpace.isk(NO_SID, cpace.scalarMult(ya, Yb), Ya, ada, Yb, adb));
        const exporter = socket.exportKeyingMaterial(32, cpace.EXPORTER_LABEL, Buffer.alloc(0));
        tag = (role) => cpace.tag(macKey, role, Ya, ada, Yb, adb, fh, fg, exporter);
        tag("guest");
    } catch {
        throw new Refusal("failed");
    }
    const finishReply = await exchange(socket, "POST", "/room/join/finish", { v: PROTOCOL, request_id: started.request_id, Ta: tag("guest").toString("hex") });
    if (finishReply.status !== 200) throw joinRefusal(finishReply);
    const finished = finishReply.json;
    if (!finished || finished.status !== "joined" || !/^d_[0-9a-f]{8}$/.test(finished.device_id)) throw new Refusal("failed");
    // Tb did not verify: the room is not who it claims, or the code was wrong on its side. Nothing is saved.
    if (typeof finished.Tb !== "string" || !HEX128.test(finished.Tb) || !cpace.verifyTag(tag("host"), Buffer.from(finished.Tb, "hex"))) {
        throw new Refusal("code_did_not_check_out");
    }
    return { deviceId: finished.device_id, hostPin: fh, hello };
}

// A call of a joined guest (/_benchbar/hello, seats, seat, room, leave) on a pinned connection that
// presents this computer's key for the host.
async function call(socket, method, pathname, body = null) {
    const reply = await exchange(socket, method, pathname, body);
    if (reply.status === 200 && reply.json) return reply.json;
    const reason = reasonOf(reply);
    if (reason === "not_paired") throw new Refusal("removed");
    if (["ended", "seat_taken", "host_assigns"].includes(reason)) throw new Refusal(reason);
    throw new Refusal(reply.status === 429 ? "rate_limited" : "refused", { retryAfter: retryAfter(reply) });
}

// ---------------------------------------------------------------- this computer's key for a host

function der(tag, ...parts) {
    const body = Buffer.concat(parts);
    const size = [];
    for (let n = body.length; n > 0; n = Math.floor(n / 256)) size.unshift(n % 256);
    const length = body.length < 128 ? [body.length] : [0x80 + size.length, ...size];
    return Buffer.concat([Buffer.from([tag, ...length]), body]);
}

const derTime = (date) => {
    const stamp = date.toISOString().replace(/[-:T]|\.[0-9]{3}/g, "");
    return date.getUTCFullYear() < 2050 ? der(0x17, Buffer.from(stamp.slice(2))) : der(0x18, Buffer.from(stamp));
};

// A self-signed certificate for a P-256 key, made anew for each process: a host knows a guest by the
// key (the SPKI hash), so only the key is kept, and the certificate around it is not a secret.
function identityOf(privateKey, now = new Date()) {
    const spki = crypto.createPublicKey(privateKey).export({ type: "spki", format: "der" });
    const ecdsaSha256 = der(0x30, der(0x06, Buffer.from("2a8648ce3d040302", "hex")));
    const name = der(0x30, der(0x31, der(0x30, der(0x06, Buffer.from("550403", "hex")), der(0x0c, Buffer.from("BenchBar guest")))));
    const serial = crypto.randomBytes(8);
    serial[0] = (serial[0] & 0x7f) | 0x01;
    const validity = der(0x30, derTime(new Date(now.getTime() - 3_600_000)), derTime(new Date(now.getTime() + 3650 * 86_400_000)));
    const tbs = der(0x30, der(0xa0, der(0x02, Buffer.from([2]))), der(0x02, serial), ecdsaSha256, name, validity, name, spki);
    const signature = crypto.sign("sha256", tbs, privateKey);
    const certificate = der(0x30, tbs, ecdsaSha256, der(0x03, Buffer.from([0]), signature));
    return {
        key: privateKey.export({ type: "pkcs8", format: "pem" }),
        cert: `-----BEGIN CERTIFICATE-----\n${certificate.toString("base64").replace(/(.{64})/g, "$1\n").trimEnd()}\n-----END CERTIFICATE-----\n`,
        fg: cpace.spkiRaw(spki)
    };
}

const newKey = () => crypto.generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey;

function ensureDir(dir) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    fs.chmodSync(dir, 0o700);
}

// An exclusive lock: a file made with "wx", which is atomic on every local file system (a mkdir is not
// one everywhere). It holds a token. A lock not touched for `staleMs` belongs to a process that died. It is
// broken by one waiter at a time (the `.reclaim` file, also made with "wx"), which renames it to a name of
// its own and checks that what it moved is the lock it judged stale: a lock a holder took a moment later is
// put back, never deleted. A lock is released only while it still holds its taker's token, so a holder whose
// lock was broken never deletes the next holder's.
function takeLock(file, token, staleMs) {
    try {
        fs.writeFileSync(file, token, { flag: "wx", mode: 0o600 });
        return true;
    } catch (e) {
        if (e.code !== "EEXIST") throw e;
    }
    breakStale(file, token, staleMs);
    return false;
}

function breakStale(file, token, staleMs) {
    const guard = `${file}.reclaim`;
    try {
        fs.writeFileSync(guard, token, { flag: "wx", mode: 0o600 });
    } catch (e) {
        if (e.code !== "EEXIST") throw e;
        try {
            if (Date.now() - fs.statSync(guard).mtimeMs > staleMs) fs.rmSync(guard, { force: true });
        } catch { /* gone already */ }
        return;
    }
    const mine = `${file}.stale.${token}`;
    try {
        let seen;
        try {
            if (Date.now() - fs.statSync(file).mtimeMs <= staleMs) return;
            seen = fs.readFileSync(file, "utf8");
        } catch { return; }
        try {
            fs.renameSync(file, mine);
        } catch (e) {
            if (e.code === "ENOENT") return;
            throw e;
        }
        let moved = null;
        try {
            moved = fs.readFileSync(mine, "utf8");
        } catch { /* nothing to compare */ }
        // the holder let go and somebody took the lock between the look and the rename: give it back
        if (moved !== seen) {
            try {
                fs.linkSync(mine, file);
            } catch { /* taken again: the new holder keeps it */ }
        }
    } finally {
        fs.rmSync(mine, { force: true });
        dropLock(guard, token);
    }
}

function dropLock(file, token) {
    try {
        if (fs.readFileSync(file, "utf8") === token) fs.rmSync(file, { force: true });
    } catch { /* broken as stale and gone */ }
}

function lockedSync(file, fn, { staleMs = 10_000, timeoutMs = 5_000 } = {}) {
    const token = crypto.randomBytes(8).toString("hex");
    for (const until = Date.now() + timeoutMs; !takeLock(file, token, staleMs);) {
        if (Date.now() >= until) throw new Refusal("busy");
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
    }
    try {
        return fn();
    } finally {
        dropLock(file, token);
    }
}

// For work that waits (the start of a forwarder can wait for a seat): the lock is touched every third of
// `staleMs` while fn runs, so it is never broken under a live holder. A process that dies stops touching it.
async function locked(file, fn, { staleMs = 30_000, timeoutMs = 20_000 } = {}) {
    const token = crypto.randomBytes(8).toString("hex");
    for (const until = Date.now() + timeoutMs; !takeLock(file, token, staleMs);) {
        if (Date.now() >= until) throw new Refusal("busy");
        await sleep(25);
    }
    const beat = setInterval(() => {
        try {
            if (fs.readFileSync(file, "utf8") === token) fs.utimesSync(file, new Date(), new Date());
        } catch { /* broken or released */ }
    }, Math.max(50, Math.floor(staleMs / 3)));
    beat.unref();
    try {
        return await fn();
    } finally {
        clearInterval(beat);
        dropLock(file, token);
    }
}

function writePrivate(file, text) {
    const tmp = `${file}.tmp-${process.pid}`;
    fs.writeFileSync(tmp, text, { mode: 0o600 });
    fs.renameSync(tmp, file);
}

// Where the keys rest: a 0600 file for each host in a 0700 folder (Linux, WSL), or a Keychain item for
// each host (macOS, through /usr/bin/security; the write goes to "security -i" on stdin, so the key is
// never an argument). A key is named by the whole hash of the host's key, never by the 16 digits a
// person reads: a host that grinds a key with the same first digits must not be shown another host's.
// A failure while looking (a locked Keychain, an unreadable file) is thrown and never answered with a
// new key: a new key is a new guest to the host, and its removal of the old one would no longer hold.
function keyStore({ kind = "file", dir, security = "/usr/bin/security" }) {
    const keychain = (args, input) => spawnSync(security, args, { input, encoding: "utf8", timeout: 10_000, stdio: ["pipe", "pipe", "ignore"] });
    // the host goes into a path and into a line of `security -i`: only the 64 hex digits of a key hash
    const named = (host) => {
        if (!HEX64.test(String(host))) throw new Refusal("key_store");
        return host;
    };
    const file = (host) => path.join(dir, "keys", `${named(host)}.pem`);
    const load = (host) => {
        named(host);
        if (kind !== "keychain") {
            let pem;
            try {
                // a key file another user could read is made private again before it is used
                if (fs.statSync(file(host)).mode & 0o077) fs.chmodSync(file(host), 0o600);
                pem = fs.readFileSync(file(host), "utf8");
            } catch (e) {
                if (e.code === "ENOENT") return null;
                throw new Refusal("key_store");
            }
            try {
                return crypto.createPrivateKey(pem);
            } catch {
                throw new Refusal("key_store");
            }
        }
        const found = keychain(["find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", host, "-w"]);
        if (found.status === KEYCHAIN_NOT_FOUND) return null;
        try {
            if (found.status !== 0) throw new Error("keychain");
            return crypto.createPrivateKey({ key: Buffer.from(found.stdout.trim(), "base64"), format: "der", type: "pkcs8" });
        } catch {
            throw new Refusal("key_store");
        }
    };
    const create = (host) => {
        named(host);
        const key = newKey();
        if (kind !== "keychain") {
            ensureDir(path.join(dir, "keys"));
            writePrivate(file(host), key.export({ type: "pkcs8", format: "pem" }));
            return key;
        }
        const secret = key.export({ type: "pkcs8", format: "der" }).toString("base64");
        keychain(["-i"], `add-generic-password -U -s "${KEYCHAIN_SERVICE}" -a "${host}" -l "BenchBar room key" `
            + `-j "This computer's key for one BenchBar room, written by benchbar share join" -T /usr/bin/security -w "${secret}"\n`);
        const back = load(host);
        if (!back || !back.equals(key)) throw new Refusal("key_store");
        return key;
    };
    const remove = (host) => {
        named(host);
        if (kind === "keychain") {
            const gone = keychain(["delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", host]);
            if (gone.status !== 0 && gone.status !== KEYCHAIN_NOT_FOUND) throw new Refusal("key_store");
            return;
        }
        try {
            fs.rmSync(file(host), { force: true });
        } catch {
            throw new Refusal("key_store");
        }
    };
    // The key for a host, made when there is none: look and create under one lock, so two joins at once
    // never make two keys (the later would replace the first, whose guest the host already knows).
    // `fresh` says this call made it.
    const obtain = (host) => {
        named(host);
        ensureDir(dir);
        return lockedSync(path.join(dir, "keys.lock"), () => {
            const key = load(host);
            return key ? { key, fresh: false } : { key: create(host), fresh: true };
        });
    };
    return { load, create, remove, obtain };
}

// ---------------------------------------------------------------- the rooms this computer joined

const roomId = (hostPin) => hostPin.toString("hex").slice(0, 16);

function validRoom(r) {
    return Boolean(r) && typeof r === "object" && /^[0-9a-f]{16}$/.test(r.id) && /^sha256:[0-9a-f]{64}$/.test(r.host_fp) && r.host_fp.slice(7, 23) === r.id
        && parseAddress(`${r.address}:${r.port}`) !== null && ["room", "host", "site", "device_id", "joined_at", "salt"].every((k) => typeof r[k] === "string");
}

// rooms.json in the guest folder (0600 in 0700). The code is never stored, the key rests in the key
// store, and a host's key hash is public. `suffix` is 128 random bits, drawn once for this install: the
// local name of a room is made from it, and the forwarder answers a request only for that name, so the
// name is what keeps another user of this computer out of the room's local address.
function roomsStore(dir) {
    const file = path.join(dir, "rooms.json");
    // A file that is there and cannot be read as a rooms file is refused, never taken for an empty list:
    // the next save would write over the rooms (and the suffix) it holds.
    const read = () => {
        let doc = null;
        try {
            doc = JSON.parse(fs.readFileSync(file, "utf8"));
            if (doc === null || typeof doc !== "object" || Array.isArray(doc)) throw new Refusal("rooms_file");
        } catch (e) {
            if (e.code !== "ENOENT") throw new Refusal("rooms_file");
            doc = null;
        }
        const kept = doc !== null && HEX32.test(String(doc.suffix));
        return { v: 1, suffix: kept ? doc.suffix : crypto.randomBytes(16).toString("hex"), kept, rooms: doc && Array.isArray(doc.rooms) ? doc.rooms.filter(validRoom) : [] };
    };
    // Read, change and write under one lock: two joins at once must both end up in the file.
    const change = (fn) => {
        ensureDir(dir);
        return lockedSync(path.join(dir, "rooms.lock"), () => {
            const doc = read();
            const result = fn(doc);
            delete doc.kept;
            writePrivate(file, JSON.stringify(doc, null, 2) + "\n");
            return result;
        });
    };
    return {
        load: () => read().rooms,
        // Kept from the first call on: the local name of a room depends on it.
        suffix: () => {
            const doc = read();
            return doc.kept ? doc.suffix : change((fresh) => fresh.suffix);
        },
        // A room from the same host replaces the old row. Two hosts whose keys start with the same 16
        // digits cannot both be saved: the second is refused, never mixed up with the first.
        save: (room) => change((doc) => {
            if (doc.rooms.some((r) => r.id === room.id && r.host_fp !== room.host_fp)) throw new Refusal("failed");
            doc.rooms = [...doc.rooms.filter((r) => r.host_fp !== room.host_fp), room];
        }),
        forget: (id) => change((doc) => {
            doc.rooms = doc.rooms.filter((r) => r.id !== id);
        })
    };
}

// ---------------------------------------------------------------- the local address of a room

// Lower case [a-z0-9-], 1 to 40 characters, no hyphen at either end.
function slug(label) {
    let out = "";
    for (const ch of String(label).normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase()) {
        if (/[a-z0-9]/.test(ch)) out += ch;
        else if (ch !== "'" && ch !== "\u2019" && out && !out.endsWith("-")) out += "-";
    }
    return out.slice(0, 40).replace(/-+$/, "") || "room";
}

// <slug>-<16 hex>.localhost: the name is the browser's cookie jar. The hex is SHA-256(install suffix,
// host key hash), so another host with the same room label never shares a jar with this one, and nobody
// who does not know the suffix can name the room's local address.
function localHost(label, suffix, hostPin) {
    return `${slug(label)}-${crypto.createHash("sha256").update(Buffer.concat([Buffer.from(suffix, "utf8"), hostPin])).digest("hex").slice(0, 16)}.localhost`;
}

// The first port to try for a host, in 41000 to 41999; the forwarder moves on while one is taken.
const firstPort = (hostPin) => PORT_FIRST + (hostPin.readUInt16BE(0) % PORT_COUNT);
const nextPort = (port) => (port + 1 >= PORT_FIRST + PORT_COUNT ? PORT_FIRST : port + 1);

module.exports = {
    PROTOCOL, Refusal, sleep, clean, clip, normalizeCode, parseAddress, isLocalNetwork, parseInvite, dial, exchange, roomHello, join, call,
    identityOf, newKey, keyStore, locked, lockedSync, roomId, roomsStore, slug, localHost, firstPort, nextPort
};
