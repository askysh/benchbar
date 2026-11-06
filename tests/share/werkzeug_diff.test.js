"use strict";
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const { spawnSync } = require("node:child_process");
const policy = require("../../lib/frappe-local/share/policy.js");
const H = require("./helpers.js");

const DEFAULT_BENCH_PYTHON = "/Users/sumanthudupi/frappe-bench/env/bin/python";
const python = process.env.FL_TEST_BENCH_PYTHON || (fs.existsSync(DEFAULT_BENCH_PYTHON) ? DEFAULT_BENCH_PYTHON : null);

// The two steps Werkzeug's development server runs on a request path:
// serving.py make_environ (unquote, then the latin-1 "encoding dance") and the
// request side's _wsgi_decoding_dance.
const DECODER = `
import json, sys
from urllib.parse import unquote, urlsplit
from werkzeug._internal import _wsgi_decoding_dance, _wsgi_encoding_dance
out = []
for target in json.load(sys.stdin):
    path_info = _wsgi_encoding_dance(unquote(urlsplit(target).path))
    out.append(_wsgi_decoding_dance(path_info))
json.dump(out, sys.stdout)
`;

function skipReason() {
    if (!python) return "no bench Python (set FL_TEST_BENCH_PYTHON)";
    return spawnSync(python, ["-I", "-c", "import werkzeug"]).status === 0 ? null : "the bench Python cannot import werkzeug";
}
const reason = skipReason();
if (reason) process.stderr.write(`werkzeug_diff: SKIPPED: ${reason}\n`);

const TARGETS = [
    "/app", "/app/", "/app/sales-order/SO-1", "/app/sales%20order/a%2Db", "/app/%E2%82%AC", "/app/caf%C3%A9", "/app/%F0%9F%98%80",
    "/app/a%2Bb", "/app/a+b", "/app/%7Euser", "/app/a%3Fb", "/app/a%23b", "/app/a%25b", "/app/%41%42", "/assets/frappe/js/x.js",
    "/files/a%20b.png", "/private/files/x.pdf", "/api/method/frappe.ping", "/api/resource/User/a%40b.com", "/login", "/me",
    "/app?x=1", "/app/a%20b?next=%2Fapp", "/api/method/a.b?x=%2e%2e", "/%63onsole", "/app/%2e%2e", "/app/%2E", "/app/a%2Fb",
    "/app/a%5Cb", "/app/a%3Bb", "/app/a%00b", "/app/%252e", "/app/%C0%AE", "/app/%ff", "//app", "/app//x", "/console",
    "/app?__debugger__=yes"
];

test("the path upstream receives, decoded as Werkzeug does, equals the path the policy approved", { skip: reason || false }, async () => {
    const c = H.makeCert(H.tmpDir(), "wz");
    const gw = await H.startGateway({ devices: [H.deviceRow(c)] });
    try {
        const sent = [];
        for (const target of TARGETS) {
            const before = gw.upstream.hits.length;
            await H.rawTls(gw, `GET ${target} HTTP/1.1\r\nHost: share.localhost:8443\r\nConnection: close\r\n\r\n`, { cert: c });
            const reached = gw.upstream.hits.length > before;
            const n = policy.normalizePath(target);
            if (!reached) continue;
            assert.ok(n.ok, `${target} reached upstream although the policy rejected it`);
            sent.push({ target, n, url: gw.upstream.hits[gw.upstream.hits.length - 1].url });
        }
        assert.ok(sent.length >= 15, `only ${sent.length} targets reached upstream`);
        const r = spawnSync(python, ["-I", "-c", DECODER], { input: JSON.stringify(sent.map((x) => x.url)), encoding: "utf8" });
        assert.strictEqual(r.status, 0, r.stderr);
        const decoded = JSON.parse(r.stdout);
        sent.forEach((x, i) => {
            assert.strictEqual(decoded[i], x.n.path, `${x.target} -> ${x.url}`);
            assert.strictEqual(x.url, x.n.forward + x.n.search, x.target);
        });
    } finally {
        await gw.stop();
    }
});
