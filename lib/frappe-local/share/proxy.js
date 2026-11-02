"use strict";
const http = require("http");
const net = require("net");
const { sanitizeRequestHeaders } = require("./policy.js");

const HOP_BY_HOP_RESPONSE = new Set(["connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer",
    "transfer-encoding", "upgrade"]);
const PROBE_TIMEOUT_MS = 500;

function createProxy({ webPort, maxBodyBytes }) {
    // `target` is the normalised, re-encoded path plus the validated query (policy.normalizePath):
    // the client's own request target never reaches upstream. Host goes through as the browser sent it.
    // onFailure(kind): "upstream" (nothing sent yet) or "too_large" (nothing sent yet).
    function forward(req, res, target, { onFailure }) {
        const declared = req.headers["content-length"];
        if (declared !== undefined && Number(declared) > maxBodyBytes) return onFailure("too_large");

        let received = 0;
        let finished = false;
        const fail = (kind) => {
            if (finished) return;
            finished = true;
            upstream.destroy();
            if (res.headersSent) res.destroy();
            else onFailure(kind);
        };
        const upstream = http.request({
            host: "127.0.0.1", port: webPort, method: req.method, path: target, headers: sanitizeRequestHeaders(req.headers), agent: false
        }, (up) => {
            const headers = {};
            for (const [k, v] of Object.entries(up.headers)) if (!HOP_BY_HOP_RESPONSE.has(k)) headers[k] = v;
            res.writeHead(up.statusCode, headers);
            up.pipe(res);
            up.on("error", () => res.destroy());
            up.on("end", () => { finished = true; });
        });
        upstream.on("error", () => fail("upstream"));
        res.on("close", () => { if (!res.writableFinished) { finished = true; upstream.destroy(); } });

        req.on("data", (chunk) => {
            received += chunk.length;
            if (received > maxBodyBytes) {
                req.unpipe(upstream);
                fail("too_large");
            }
        });
        req.pipe(upstream);
    }

    function probe() {
        return new Promise((resolve) => {
            const c = net.connect({ host: "127.0.0.1", port: webPort });
            const done = (up) => { c.destroy(); resolve(up); };
            c.setTimeout(PROBE_TIMEOUT_MS, () => done(false));
            c.on("connect", () => done(true));
            c.on("error", () => done(false));
        });
    }

    return { forward, probe };
}

module.exports = { createProxy };
