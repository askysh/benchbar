"use strict";
// CPace-X25519-SHA512, pinned to draft-irtf-cfrg-cpace-21, initiator-responder
// (guest = A, host = B), plus the channel-binding tags of protocol v3.
// The Elligator2 map is in cpace-map.js (no Node imports, reused in JavaScriptCore).
const crypto = require("crypto");
const { elligator2: mapToCurve } = require("./cpace-map.js");

const ABORT = "cpace_abort";
const EXPORTER_LABEL = "EXPORTER-bb-join-v3";
const VERSION_LABEL = "bb-join-v3";
const DSI = "CPace255";
const DSI_ISK = "CPace255_ISK";
const HASH_BLOCK_BYTES = 128;
const ROLES = new Set(["guest", "host"]);

const PKCS8_X25519_PREFIX = Buffer.from("302e020100300506032b656e04220420", "hex");
const SPKI_X25519_PREFIX = Buffer.from("302a300506032b656e032100", "hex");

const sha512 = (...parts) => crypto.createHash("sha512").update(Buffer.concat(parts)).digest();
const toBuffer = (v) => (typeof v === "string" ? Buffer.from(v, "utf8") : v);

function requireBytes(value, length, what) {
    if (!(value instanceof Uint8Array) || (length !== undefined && value.length !== length)) throw new TypeError(`${what} must be ${length} bytes`);
    return Buffer.from(value);
}

function spkiFingerprint(spkiDer) {
    return "sha256:" + crypto.createHash("sha256").update(spkiDer).digest("hex");
}

// MAC inputs use the raw 32 bytes, never the "sha256:" string (J11).
function spkiRaw(spkiDer) {
    return crypto.createHash("sha256").update(spkiDer).digest();
}

// Draft A.1.1: LEB128 length prefix.
function prependLen(data) {
    const bytes = [];
    let length = data.length;
    do {
        bytes.push(length < 128 ? length : (length & 0x7f) + 0x80);
        length >>>= 7;
    } while (length !== 0);
    return Buffer.concat([Buffer.from(bytes), data]);
}

function lvCat(...args) {
    return Buffer.concat(args.map((a) => prependLen(toBuffer(a))));
}

// Draft A.2: zero padding fills the first hash block after DSI and PRS.
function generatorString(dsi, prs, ci, sid, sInBytes = HASH_BLOCK_BYTES) {
    const [d, p] = [toBuffer(dsi), toBuffer(prs)];
    const zeros = Math.max(0, sInBytes - 1 - prependLen(p).length - prependLen(d).length);
    return lvCat(d, p, Buffer.alloc(zeros), ci, sid);
}

// SHA-512 truncated to 32 bytes with bit 255 cleared (B.1.1 "decoded field element").
// The reduction mod p happens in the map.
function generatorHashU(prs, ci, sid) {
    const u = sha512(generatorString(DSI, prs, ci, sid)).subarray(0, 32);
    u[31] &= 0x7f;
    return Buffer.from(u);
}

function elligator2(u32) {
    return Buffer.from(mapToCurve(new Uint8Array(requireBytes(u32, 32, "u"))));
}

function calculateGenerator(prs, ci, sid) {
    return elligator2(generatorHashU(prs, ci, sid));
}

// Constant-time: the OR never short-circuits.
function isAllZero(buf) {
    let acc = 0;
    for (const byte of buf) acc |= byte;
    return acc === 0;
}

// X25519 from raw bytes. Node/OpenSSL throws on an all-zero result; the explicit check
// below is authoritative either way (J7). Bit 255 of u is masked here (RFC 7748) rather
// than left to the library. The error never carries inputs.
function scalarMult(scalar, u) {
    const s = requireBytes(scalar, 32, "scalar");
    const point = requireBytes(u, 32, "u");
    point[31] &= 0x7f;
    let shared;
    try {
        const privateKey = crypto.createPrivateKey({ key: Buffer.concat([PKCS8_X25519_PREFIX, s]), format: "der", type: "pkcs8" });
        const publicKey = crypto.createPublicKey({ key: Buffer.concat([SPKI_X25519_PREFIX, point]), format: "der", type: "spki" });
        shared = crypto.diffieHellman({ privateKey, publicKey });
    } catch {
        throw new Error(ABORT);
    }
    if (isAllZero(shared)) throw new Error(ABORT);
    return shared;
}

// Draft 9.4 with transcript_ir (A.3.4).
function isk(sid, K, Ya, ADa, Yb, ADb) {
    return sha512(lvCat(DSI_ISK, sid, K), lvCat(Ya, ADa), lvCat(Yb, ADb));
}

function macKey(sid, iskBytes) {
    return sha512(Buffer.from("CPaceMac"), sid, iskBytes);
}

// lv_cat(role, Ya, ADa, Yb, ADb, Fh, Fg, exporter): Fh and Fg are the SPKI hashes each
// side saw in its own TLS handshake; exporter is that connection's 32-byte exporter (J16).
function tag(key, role, Ya, ADa, Yb, ADb, Fh, Fg, exporter) {
    if (!ROLES.has(role)) throw new TypeError("unknown role");
    const message = lvCat(role, Ya, ADa, Yb, ADb, requireBytes(Fh, 32, "Fh"), requireBytes(Fg, 32, "Fg"), requireBytes(exporter, 32, "exporter"));
    return crypto.createHmac("sha512", key).update(message).digest();
}

function verifyTag(expected, got) {
    if (!Buffer.isBuffer(got) || got.length !== expected.length) return false;
    return crypto.timingSafeEqual(expected, got);
}

const adGuest = (name, model) => lvCat(VERSION_LABEL, name, model);
const adHost = (roomLabel, requestId) => lvCat(VERSION_LABEL, roomLabel, requestId);

module.exports = {
    ABORT, EXPORTER_LABEL, spkiFingerprint, spkiRaw, prependLen, lvCat, generatorString, generatorHashU, elligator2, calculateGenerator,
    isAllZero, scalarMult, isk, macKey, tag, verifyTag, adGuest, adHost
};
