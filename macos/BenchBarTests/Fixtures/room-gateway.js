"use strict";
// Starts the real share gateway through tests/share/helpers.js (gateway_harness.js) for
// ShareInteropTests, prints {port, code, host_fp, seats} on one line, and stops the gateway
// when stdin closes. argv[2] is the repository root.
const path = require("node:path");
const h = require(path.join(process.argv[2], "tests/share/helpers.js"));

(async () => {
    const gw = await h.startGateway();
    const code = await h.roomCode(gw);
    process.stdout.write(JSON.stringify({ port: gw.port, code, host_fp: gw.host.fp, seats: gw.seats.map((s) => s.seat_id) }) + "\n");
    process.stdin.resume();
    process.stdin.on("end", async () => {
        await gw.stop();
        process.exit(0);
    });
})().catch((e) => {
    process.stderr.write(String((e && e.stack) || e) + "\n");
    process.exit(1);
});
