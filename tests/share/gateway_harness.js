"use strict";
// Test entry point: reads the test environment and injects it into the real
// gateway. lib/frappe-local/share/gateway.js itself reads none of this.
const fs = require("node:fs");
const path = require("node:path");
const { main } = require(path.join(__dirname, "../../lib/frappe-local/share/gateway.js"));

const clockFile = process.env.FL_SHARE_TEST_CLOCK_FILE;
main(process.argv.slice(2), {
    clock: clockFile ? () => Date.now() + (Number(fs.readFileSync(clockFile, "utf8")) || 0) : Date.now,
    tickMs: Number(process.env.FL_SHARE_TEST_TICK_MS) || 30_000,
    peerIpOf: (req) => req.headers["x-test-peer-ip"] || req.socket.bbIp
});
