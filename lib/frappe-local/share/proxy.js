"use strict";
const http = require("http");
const { sanitizeRequestHeaders } = require("./policy.js");

const HOP_BY_HOP_RESPONSE = new Set(["connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer",
    "transfer-encoding", "upgrade"]);

function createProxy({ webPort, maxBodyBytes }) {
    // `target` is the normalised, re-encoded path plus the validated query (policy.normalizePath):
    // the client's own request target never reaches upstream. Host goes through as the browser sent it.
    // onFailure(kind, code): "upstream" (nothing sent yet; code is the socket error's: ECONNREFUSED when nothing
    // listens, ECONNRESET when a request was dropped) or "too_large" (nothing sent yet).
    function forward(req, res, target, { onFailure }) {
        const declared = req.headers["content-length"];
        if (declared !== undefined && Number(declared) > maxBodyBytes) return onFailure("too_large");

        let received = 0;
        let finished = false;
        const fail = (kind, code) => {
            if (finished) return;
            finished = true;
            upstream.destroy();
            if (res.headersSent) res.destroy();
            else onFailure(kind, code);
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
        upstream.on("error", (e) => fail("upstream", e && e.code));
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

    return { forward };
}

module.exports = { createProxy };
