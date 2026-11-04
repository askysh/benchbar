"use strict";
// Starts the real share gateway through tests/share/helpers.js (gateway_harness.js) for
// ShareInteropTests, prints {port, code, host_fp, seats} on one line, and stops the gateway
// when stdin closes. argv[2] is the repository root. Each line written to stdin is a control
// message (e.g. {"op":"status"}); its reply is printed as one JSON line.
const path = require("node:path");
const h = require(path.join(process.argv[2], "tests/share/helpers.js"));

(async () => {
    const gw = await h.startGateway();
    const code = await h.roomCode(gw);
    process.stdout.write(JSON.stringify({ port: gw.port, code, host_fp: gw.host.fp, seats: gw.seats.map((s) => s.seat_id) }) + "\n");
    let pending = "";
    let queue = Promise.resolve();
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
        pending += chunk;
        let nl;
        while ((nl = pending.indexOf("\n")) >= 0) {
            const line = pending.slice(0, nl);
            pending = pending.slice(nl + 1);
            queue = queue.then(async () => {
                let reply;
                try { reply = await gw.control(JSON.parse(line)); } catch (e) { reply = { ok: false, error: String(e) }; }
                process.stdout.write(JSON.stringify(reply) + "\n");
            });
        }
    });
    process.stdin.on("end", async () => {
        await queue;
        await gw.stop();
        process.exit(0);
    });
})().catch((e) => {
    process.stderr.write(String((e && e.stack) || e) + "\n");
    process.exit(1);
});
