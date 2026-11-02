"use strict";
const crypto = require("crypto");

const SAS_LABEL = "benchbar-share-sas-v2";
const sha256 = (...parts) => crypto.createHash("sha256").update(Buffer.concat(parts)).digest();

// Raw bytes, or hex (a "sha256:" prefix is allowed so a fingerprint string goes straight in).
function bytes(value, length, what) {
    const buf = Buffer.isBuffer(value) ? value : Buffer.from(String(value).replace(/^sha256:/, ""), "hex");
    if (buf.length !== length) throw new Error(`${what} must be ${length} bytes`);
    return buf;
}

function spkiFingerprint(spkiDer) {
    return "sha256:" + sha256(spkiDer).toString("hex");
}

function commit(fg, ng) {
    return sha256(bytes(fg, 32, "Fg"), bytes(ng, 16, "Ng")).toString("hex");
}

function checkCommit(commitHex, fg, ng) {
    if (typeof commitHex !== "string" || !/^[0-9a-f]{64}$/.test(commitHex)) return false;
    const expected = sha256(bytes(fg, 32, "Fg"), bytes(ng, 16, "Ng"));
    return crypto.timingSafeEqual(expected, Buffer.from(commitHex, "hex"));
}

function sas(fh, fg, ng, nh) {
    const digest = sha256(Buffer.from(SAS_LABEL), bytes(fh, 32, "Fh"), bytes(fg, 32, "Fg"), bytes(ng, 16, "Ng"), bytes(nh, 16, "Nh"));
    return String(digest.readUInt32BE(0) % 1000000).padStart(6, "0");
}

module.exports = { spkiFingerprint, commit, checkCommit, sas };
