"use strict";
// Elligator2 map to Curve25519, as given by draft-irtf-cfrg-cpace-21 Appendix A.5
// (x = epsilon*v - (1 - epsilon)*A/2). This file must stay free of Node APIs: the
// macOS guest loads it unmodified into JavaScriptCore, which has Uint8Array and
// BigInt but no Buffer, require or process.
//
// Control flow is straight-line: the square/non-square choice is a field
// multiplication by epsilon (0, 1 or p-1), never a branch. BigInt arithmetic
// itself is not constant-time, so draft section 10.10 is NOT met (recorded as
// deviation J8); the host calls this once per code with no attacker input.

const FIELD_P = (1n << 255n) - 19n;
const CURVE_A = 486662n;
const NON_SQUARE_Z = 2n;                       // find_z_ell2 for Curve25519 (A.5)
const HALF_P_MINUS_1 = (FIELD_P - 1n) / 2n;    // Legendre exponent
const INVERSE_EXPONENT = FIELD_P - 2n;         // Fermat inversion

const mod = (a) => ((a % FIELD_P) + FIELD_P) % FIELD_P;

// Fixed 255 iterations over a public exponent; the multiply is always done and
// selected arithmetically.
function modPow(base, exponent) {
    const b = mod(base);
    let result = 1n;
    for (let i = 254n; i >= 0n; i--) {
        result = result * result % FIELD_P;
        const bit = (exponent >> i) & 1n;
        result = result * (bit * b + (1n - bit)) % FIELD_P;
    }
    return result;
}

const INVERSE_OF_TWO = modPow(2n, INVERSE_EXPONENT);

// RFC 7748 decodeUCoordinate: little-endian, bit 255 ignored.
function decodeUCoordinate(bytes) {
    let n = 0n;
    for (let i = 31; i >= 0; i--) n = (n << 8n) | BigInt(bytes[i] & (i === 31 ? 0x7f : 0xff));
    return n;
}

function encodeUCoordinate(n) {
    const out = new Uint8Array(32);
    let rest = n;
    for (let i = 0; i < 32; i++) {
        out[i] = Number(rest & 0xffn);
        rest >>= 8n;
    }
    return out;
}

// 32 bytes in (any value; reduced mod p), 32-byte u coordinate out.
function elligator2(bytes32) {
    const r = decodeUCoordinate(bytes32);
    const v = mod(-CURVE_A * modPow(1n + NON_SQUARE_Z * r * r, INVERSE_EXPONENT));
    const epsilon = modPow(v * v * v + CURVE_A * v * v + v, HALF_P_MINUS_1);
    const x = mod(epsilon * v - (1n - epsilon) * CURVE_A * INVERSE_OF_TWO);
    return encodeUCoordinate(x);
}

if (typeof module !== "undefined" && module.exports) module.exports = { elligator2 };
