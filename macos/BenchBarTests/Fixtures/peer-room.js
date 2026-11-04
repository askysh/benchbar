"use strict";
// A TLS 1.3 room that asks for a client certificate like the gateway (requestCert, no chain
// verdict), answers every request with a room hello, and records the SPKI SHA-256 (hex) of
// each request's client certificate, or "none". Prints {port, fp} on one line; each stdin line
// prints the list seen so far as one JSON line; exits when stdin closes. argv[2] is the
// repository root.
const path = require("node:path");
const https = require("node:https");
const crypto = require("node:crypto");
const h = require(path.join(process.argv[2], "tests/share/helpers.js"));

const cert = h.makeCert(h.tmpDir(), "peer");
const seen = [];
const hello = JSON.stringify({ v: 3, room: "Peer Room", host: "Peer", site: "peer", salt: "00".repeat(16), locked: false, full: false, people: 0, seats: 2 });
const server = https.createServer({ key: cert.key, cert: cert.cert, minVersion: "TLSv1.3", ALPNProtocols: ["http/1.1"],
    requestCert: true, rejectUnauthorized: false }, (req, res) => {
    const peer = req.socket.getPeerCertificate();
    seen.push(peer && peer.raw
        ? crypto.createHash("sha256").update(new crypto.X509Certificate(peer.raw).publicKey.export({ type: "spki", format: "der" })).digest("hex")
        : "none");
    res.writeHead(200, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(hello) });
    res.end(hello);
});
server.on("tlsClientError", () => {});
server.listen(0, "127.0.0.1", () => process.stdout.write(JSON.stringify({ port: server.address().port, fp: cert.fp }) + "\n"));
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { for (const _ of chunk.split("\n").slice(1)) process.stdout.write(JSON.stringify(seen) + "\n"); });
process.stdin.on("end", () => process.exit(0));
