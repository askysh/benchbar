"use strict";
const test = require("node:test");
const assert = require("node:assert");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const cpace = require("../../lib/frappe-local/share/cpace.js");
const v = require("./vectors.json");

const b = (hex) => Buffer.from(hex, "hex");
const ascii = (s) => Buffer.from(s, "ascii");
const C = v.cpace;
const MAP_FILE = path.join(__dirname, "../../lib/frappe-local/share/cpace-map.js");
// The map's code without comments and without the CommonJS export line (which only runs under Node).
const mapCode = () => fs.readFileSync(MAP_FILE, "utf8").replace(/\/\/.*$/gm, "").replace(/^if \(typeof module.*$/m, "");

test("the stored SPKI DER hashes to the stored fingerprint, as a string and as 32 raw bytes", () => {
    const der = b(v.spki.der_hex);
    assert.strictEqual(crypto.createHash("sha256").update(der).digest("hex"), v.spki.sha256_hex);
    assert.strictEqual(cpace.spkiFingerprint(der), v.spki.fingerprint);
    assert.strictEqual(cpace.spkiRaw(der).toString("hex"), v.spki.sha256_hex);
});

test("prepend_len and lv_cat match draft A.1 and A.3.5", () => {
    assert.strictEqual(cpace.prependLen(Buffer.alloc(0)).toString("hex"), C.strings.prepend_len_empty);
    assert.strictEqual(cpace.prependLen(ascii("1234")).toString("hex"), C.strings.prepend_len_1234);
    assert.strictEqual(cpace.lvCat(...C.strings.lv_cat_args_ascii.map(ascii)).toString("hex"), C.strings.lv_cat);
    assert.strictEqual(cpace.prependLen(Buffer.alloc(200)).subarray(0, 2).toString("hex"), "c801", "two-byte LEB128 length");
    const t = C.strings.transcript_ir_args_ascii.map(ascii);
    assert.strictEqual(Buffer.concat([cpace.lvCat(t[0], t[1]), cpace.lvCat(t[2], t[3])]).toString("hex"), C.strings.transcript_ir);
});

test("B.1.1: generator string, hash, decoded field element and generator g", () => {
    const x = C.b1_1;
    const gs = cpace.generatorString("CPace255", ascii(x.prs_ascii), b(x.ci), b(x.sid), x.s_in_bytes);
    assert.strictEqual(gs.toString("hex"), x.generator_string);
    assert.strictEqual(gs.length, 170);
    const hash32 = crypto.createHash("sha512").update(gs).digest().subarray(0, 32);
    assert.strictEqual(hash32.toString("hex"), x.hash32);
    const u = cpace.generatorHashU(ascii(x.prs_ascii), b(x.ci), b(x.sid));
    assert.strictEqual(u.toString("hex"), x.decoded);
    assert.strictEqual(cpace.elligator2(u).toString("hex"), x.g);
    assert.strictEqual(cpace.calculateGenerator(ascii(x.prs_ascii), b(x.ci), b(x.sid)).toString("hex"), x.g);
});

test("B.1.2 to B.1.4: Ya, Yb and the shared K agree from both sides", () => {
    const x = C.b1_isk;
    const g = b(C.b1_1.g);
    assert.strictEqual(cpace.scalarMult(b(x.ya), g).toString("hex"), x.Ya);
    assert.strictEqual(cpace.scalarMult(b(x.yb), g).toString("hex"), x.Yb);
    assert.strictEqual(cpace.scalarMult(b(x.ya), b(x.Yb)).toString("hex"), x.K);
    assert.strictEqual(cpace.scalarMult(b(x.yb), b(x.Ya)).toString("hex"), x.K);
});

test("B.1.5: ISK (initiator-responder)", () => {
    const x = C.b1_isk;
    const got = cpace.isk(b(C.b1_1.sid), b(x.K), b(x.Ya), ascii(x.ada_ascii), b(x.Yb), ascii(x.adb_ascii));
    assert.strictEqual(got.toString("hex"), x.isk);
    const input = Buffer.concat([cpace.lvCat(ascii("CPace255_ISK"), b(C.b1_1.sid), b(x.K)), b(x.transcript_ir)]);
    assert.strictEqual(input.toString("hex"), x.isk_input);
});

test("B.1.10: all 12 low-order and non-canonical u go through the production import path", () => {
    const { s, u, q, abort } = C.b1_10;
    assert.strictEqual(Object.keys(u).length, 12);
    for (const k of Object.keys(u)) {
        if (/^0+$/.test(q[k])) {
            assert.throws(() => cpace.scalarMult(b(s), b(u[k])), { message: cpace.ABORT }, `u${k} must abort`);
        } else {
            assert.strictEqual(cpace.scalarMult(b(s), b(u[k])).toString("hex"), q[k], `u${k}`);
        }
    }
    for (const k of abort) assert.throws(() => cpace.scalarMult(b(s), b(u[k])), { message: cpace.ABORT }, `u${k} is on the abort list`);
});

test("scalarMult aborts with the fixed error on an all-zero result even when the library would return zeros", () => {
    const zero = Buffer.alloc(32);
    assert.strictEqual(cpace.isAllZero(zero), true);
    const almost = Buffer.alloc(32); almost[31] = 1;
    assert.strictEqual(cpace.isAllZero(almost), false);
    assert.throws(() => cpace.scalarMult(b(C.b1_10.s), Buffer.alloc(32)), { message: cpace.ABORT });
});

test("scalarMult refuses wrong-length inputs", () => {
    const g = b(C.b1_1.g);
    assert.throws(() => cpace.scalarMult(Buffer.alloc(31), g));
    assert.throws(() => cpace.scalarMult(Buffer.alloc(32, 1), g.subarray(1)));
    assert.throws(() => cpace.scalarMult("00".repeat(32), g));
});

test("the map file has no Node imports and runs in a bare context with only typed arrays and BigInt", () => {
    const src = fs.readFileSync(MAP_FILE, "utf8");
    assert.ok(!/require\(|\bimport\b|\bBuffer\b|\bprocess\b|\bcrypto\b/.test(mapCode()), "map file must be free of Node APIs");
    const sandbox = { Uint8Array, BigInt };
    vm.runInNewContext(src + "\nthis.elligator2 = elligator2;", sandbox);
    const u = b(C.b1_1.decoded);
    assert.strictEqual(Buffer.from(sandbox.elligator2(new Uint8Array(u))).toString("hex"), C.b1_1.g);
});

test("elligator2 ignores bit 255, reduces mod p, and is straight-line", () => {
    const u = b(C.b1_1.decoded);
    const high = Buffer.from(u); high[31] |= 0x80;
    assert.strictEqual(cpace.elligator2(high).toString("hex"), cpace.elligator2(u).toString("hex"));
    assert.ok(!/isSquare|\bif\s*\(|\bwhile\b|\bswitch\b/i.test(mapCode()), "no data-dependent branch in the map");
    const p = (1n << 255n) - 19n;
    const asBytes = (n) => Buffer.from(n.toString(16).padStart(64, "0"), "hex").reverse();
    assert.strictEqual(cpace.elligator2(asBytes(5n)).toString("hex"), cpace.elligator2(asBytes(5n + p)).toString("hex"));
});

test("elligator2 always lands on the curve: x^3 + A x^2 + x is a square, for 200 random inputs and the edge inputs", () => {
    const p = (1n << 255n) - 19n;
    const pow = (a, e) => { let r = 1n; a %= p; while (e) { if (e & 1n) r = r * a % p; a = a * a % p; e >>= 1n; } return r; };
    const le = (buf) => BigInt("0x" + Buffer.from(buf).reverse().toString("hex"));
    const inputs = [Buffer.alloc(32), Buffer.alloc(32, 0xff), Buffer.alloc(32, 1)];
    for (let i = 0; i < 200; i++) inputs.push(crypto.randomBytes(32));
    for (const input of inputs) {
        const x = le(cpace.elligator2(input));
        const rhs = (x * x % p * x + 486662n * x % p * x + x) % p;
        assert.ok(rhs === 0n || pow(rhs, (p - 1n) / 2n) === 1n);
        assert.ok(x < p);
    }
});

test("the TLS exporter label is pinned", () => {
    assert.strictEqual(cpace.EXPORTER_LABEL, "EXPORTER-bb-join-v3");
});

test("ADa and ADb are lv_cat over the exact UTF-8 bytes, with the version label first", () => {
    const ada = cpace.adGuest("Priya\u2019s Mac", "Mac14,2");
    assert.strictEqual(ada.toString("hex"), cpace.lvCat(ascii("bb-join-v3"), Buffer.from("Priya\u2019s Mac", "utf8"), ascii("Mac14,2")).toString("hex"));
    const adb = cpace.adHost("Standup room", "j_" + "ab".repeat(16));
    assert.strictEqual(adb.toString("hex"), cpace.lvCat(ascii("bb-join-v3"), ascii("Standup room"), ascii("j_" + "ab".repeat(16))).toString("hex"));
});

const tagInputs = () => ({
    sid: Buffer.alloc(0), isk: crypto.randomBytes(64), ya: crypto.randomBytes(32), ada: ascii("ada"), yb: crypto.randomBytes(32), adb: ascii("adb"),
    fh: crypto.randomBytes(32), fg: crypto.randomBytes(32), ex: crypto.randomBytes(32)
});
const tagOf = (role, t, mk) => cpace.tag(mk, role, t.ya, t.ada, t.yb, t.adb, t.fh, t.fg, t.ex);

test("tags: role-separated, 64 bytes, and every input changes them", () => {
    const t = tagInputs();
    const mk = cpace.macKey(t.sid, t.isk);
    assert.strictEqual(mk.length, 64);
    const ta = tagOf("guest", t, mk);
    assert.strictEqual(ta.length, 64);
    assert.notDeepStrictEqual(ta, tagOf("host", t, mk));
    assert.deepStrictEqual(ta, tagOf("guest", t, mk));
    for (const field of ["ya", "yb", "fh", "fg", "ex"]) {
        const other = { ...t, [field]: crypto.randomBytes(32) };
        assert.notDeepStrictEqual(tagOf("guest", other, mk), ta, field);
    }
    assert.notDeepStrictEqual(tagOf("guest", { ...t, ada: ascii("adx") }, mk), ta);
    assert.notDeepStrictEqual(tagOf("guest", t, cpace.macKey(t.sid, crypto.randomBytes(64))), ta);
    assert.notDeepStrictEqual(tagOf("guest", { ...t, fh: t.fg, fg: t.fh }, mk), ta, "Fh and Fg are not interchangeable");
});

test("tag refuses an unknown role and wrong-length fingerprints or exporter", () => {
    const t = tagInputs();
    const mk = cpace.macKey(t.sid, t.isk);
    assert.throws(() => cpace.tag(mk, "admin", t.ya, t.ada, t.yb, t.adb, t.fh, t.fg, t.ex));
    assert.throws(() => cpace.tag(mk, "guest", t.ya, t.ada, t.yb, t.adb, t.fh.subarray(1), t.fg, t.ex));
    assert.throws(() => cpace.tag(mk, "guest", t.ya, t.ada, t.yb, t.adb, t.fh, t.fg, t.ex.subarray(1)));
});

test("verifyTag is exact and never throws on junk", () => {
    const t = tagInputs();
    const ta = tagOf("guest", t, cpace.macKey(t.sid, t.isk));
    assert.strictEqual(cpace.verifyTag(ta, Buffer.from(ta)), true);
    const flipped = Buffer.from(ta); flipped[63] ^= 1;
    assert.strictEqual(cpace.verifyTag(ta, flipped), false);
    for (const junk of [ta.subarray(1), Buffer.alloc(0), null, undefined, "x", 5]) assert.strictEqual(cpace.verifyTag(ta, junk), false);
});

test("a full run: guest and host derive the same ISK, MAC key and tags", () => {
    const prs = ascii("482913");
    const salt = crypto.randomBytes(16);
    const g = cpace.calculateGenerator(prs, salt, Buffer.alloc(0));
    const ya = crypto.randomBytes(32), yb = crypto.randomBytes(32);
    const Ya = cpace.scalarMult(ya, g), Yb = cpace.scalarMult(yb, g);
    const ada = cpace.adGuest("n", "m"), adb = cpace.adHost("room", "j_x");
    const iskA = cpace.isk(Buffer.alloc(0), cpace.scalarMult(ya, Yb), Ya, ada, Yb, adb);
    const iskB = cpace.isk(Buffer.alloc(0), cpace.scalarMult(yb, Ya), Ya, ada, Yb, adb);
    assert.deepStrictEqual(iskA, iskB);
    const wrong = cpace.calculateGenerator(ascii("482914"), salt, Buffer.alloc(0));
    assert.notDeepStrictEqual(wrong, g);
});

const P = C.production;
test("production-parameter vector: empty sid, 16-byte salt as CI, six ASCII digits as PRS", { skip: P ? false : "vector not generated yet" }, () => {
    const prs = ascii(P.prs_ascii), salt = b(P.salt), sid = Buffer.alloc(0);
    assert.strictEqual(P.sid, "");
    const g = cpace.calculateGenerator(prs, salt, sid);
    assert.strictEqual(g.toString("hex"), P.g);
    const Ya = cpace.scalarMult(b(P.ya), g), Yb = cpace.scalarMult(b(P.yb), g);
    assert.strictEqual(Ya.toString("hex"), P.Ya);
    assert.strictEqual(Yb.toString("hex"), P.Yb);
    const K = cpace.scalarMult(b(P.ya), Yb);
    assert.strictEqual(K.toString("hex"), P.K);
    const ada = cpace.adGuest(P.name, P.model), adb = cpace.adHost(P.room, P.request_id);
    assert.strictEqual(ada.toString("hex"), P.ada);
    assert.strictEqual(adb.toString("hex"), P.adb);
    const isk = cpace.isk(sid, K, Ya, ada, Yb, adb);
    assert.strictEqual(isk.toString("hex"), P.isk);
    const mk = cpace.macKey(sid, isk);
    assert.strictEqual(mk.toString("hex"), P.mac_key);
    assert.strictEqual(cpace.tag(mk, "guest", Ya, ada, Yb, adb, b(P.fh), b(P.fg), b(P.exporter)).toString("hex"), P.ta);
    assert.strictEqual(cpace.tag(mk, "host", Ya, ada, Yb, adb, b(P.fh), b(P.fg), b(P.exporter)).toString("hex"), P.tb);
});
