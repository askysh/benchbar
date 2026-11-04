"use strict";
// A TLS 1.3 server that completes the handshake and never answers, for RoomConnection's
// request timeout. Prints {port, fp} on one line and exits when stdin closes. argv[2] is the
// repository root.
const path = require("node:path");
const tls = require("node:tls");
const h = require(path.join(process.argv[2], "tests/share/helpers.js"));

const cert = h.makeCert(h.tmpDir(), "silent");
const server = tls.createServer({ key: cert.key, cert: cert.cert, minVersion: "TLSv1.3", ALPNProtocols: ["http/1.1"],
    requestCert: true, rejectUnauthorized: false }, (socket) => socket.on("error", () => {}));
server.listen(0, "127.0.0.1", () => process.stdout.write(JSON.stringify({ port: server.address().port, fp: cert.fp }) + "\n"));
process.stdin.resume();
process.stdin.on("end", () => process.exit(0));
