"use strict";
const test = require("node:test");
const assert = require("node:assert");
const crypto = require("node:crypto");
const sas = require("../../lib/frappe-local/share/sas.js");
const v = require("./vectors.json");

const b = (hex) => Buffer.from(hex, "hex");
const P = v.pairing;

test("the stored SPKI DER hashes to the stored fingerprint", () => {
    const der = b(v.spki.der_hex);
    assert.strictEqual(crypto.createHash("sha256").update(der).digest("hex"), v.spki.sha256_hex);
    assert.strictEqual(sas.spkiFingerprint(der), v.spki.fingerprint);
    assert.match(sas.spkiFingerprint(der), /^sha256:[0-9a-f]{64}$/);
});

test("commit matches the vector, from raw bytes or hex", () => {
    assert.strictEqual(sas.commit(b(P.fg), b(P.ng)), P.commit);
    assert.strictEqual(sas.commit(P.fg, P.ng), P.commit);
    assert.strictEqual(sas.commit("sha256:" + P.fg, P.ng), P.commit);
});

test("checkCommit accepts the right nonce and refuses another, a short or a wrong commit", () => {
    assert.strictEqual(sas.checkCommit(P.commit, b(P.fg), b(P.ng)), true);
    const other = Buffer.from(b(P.ng)); other[0] ^= 1;
    assert.strictEqual(sas.checkCommit(P.commit, b(P.fg), other), false);
    assert.strictEqual(sas.checkCommit(P.commit, b(P.fh), b(P.ng)), false);
    assert.strictEqual(sas.checkCommit(P.commit.slice(0, 62), b(P.fg), b(P.ng)), false);
    assert.strictEqual(sas.checkCommit("zz".repeat(32), b(P.fg), b(P.ng)), false);
    assert.strictEqual(sas.checkCommit(undefined, b(P.fg), b(P.ng)), false);
});

test("checkCommit returns false, never throws, on malformed input", () => {
    assert.strictEqual(sas.checkCommit(P.commit, b(P.fg), b(P.ng).subarray(1)), false);
    assert.strictEqual(sas.checkCommit(P.commit, b(P.fg), Buffer.alloc(17)), false);
    assert.strictEqual(sas.checkCommit(P.commit, b(P.fg).subarray(1), b(P.ng)), false);
    assert.strictEqual(sas.checkCommit(P.commit, b(P.fg), "zz"), false);
    assert.strictEqual(sas.checkCommit(P.commit, b(P.fg), undefined), false);
    assert.strictEqual(sas.checkCommit(P.commit, b(P.fg), 12345), false);
    assert.strictEqual(sas.checkCommit(P.commit, null, b(P.ng)), false);
});

test("sas matches the vector and is six digits", () => {
    const code = sas.sas(b(P.fh), b(P.fg), b(P.ng), b(P.nh));
    assert.strictEqual(code, P.sas);
    assert.match(code, /^[0-9]{6}$/);
    assert.strictEqual(sas.sas(P.fh, P.fg, P.ng, P.nh), P.sas);
});

test("changing any one input changes the code", () => {
    const flip = (hex) => { const x = b(hex); x[x.length - 1] ^= 1; return x; };
    const base = [b(P.fh), b(P.fg), b(P.ng), b(P.nh)];
    for (let i = 0; i < 4; i++) {
        const args = base.slice();
        args[i] = flip([P.fh, P.fg, P.ng, P.nh][i]);
        assert.notStrictEqual(sas.sas(...args), P.sas, `input ${i}`);
    }
});

test("the input order is Fh, Fg, Ng, Nh (swapping the two nonces changes the code)", () => {
    assert.notStrictEqual(sas.sas(b(P.fh), b(P.fg), b(P.nh), b(P.ng)), P.sas);
    assert.notStrictEqual(sas.sas(b(P.fg), b(P.fh), b(P.ng), b(P.nh)), P.sas);
});

test("the SAS is zero-padded", () => {
    let found = null;
    for (let i = 0; i < 20000 && !found; i++) {
        const nh = Buffer.alloc(16); nh.writeUInt32BE(i, 0);
        const c = sas.sas(b(P.fh), b(P.fg), b(P.ng), nh);
        if (c.startsWith("0")) found = c;
    }
    assert.ok(found && found.length === 6, "a code starting with 0 keeps six digits");
});

test("wrong-length inputs throw", () => {
    assert.throws(() => sas.commit(b(P.fg).subarray(1), b(P.ng)));
    assert.throws(() => sas.commit(b(P.fg), b(P.ng).subarray(1)));
    assert.throws(() => sas.sas(b(P.fh), b(P.fg), b(P.ng), Buffer.alloc(15)));
});
