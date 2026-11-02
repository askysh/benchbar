"use strict";
const test = require("node:test");
const assert = require("node:assert");
const { renderError } = require("../../lib/frappe-local/share/htmlpages.js");

const COPY = {
    not_available: [403, "This page isn't available through sharing", {}],
    restarting: [503, "Priya's bench is restarting, try again in a moment", { label: "Priya" }],
    ended: [403, "Sharing has ended", {}],
    not_paired: [403, "Priya removed this Mac", { label: "Priya" }]
};

test("each kind has its status and exact copy line", () => {
    for (const [kind, [status, line, opts]] of Object.entries(COPY)) {
        const r = renderError(kind, opts);
        assert.strictEqual(r.status, status, kind);
        assert.ok(r.body.includes(line), `${kind}: ${line}`);
    }
});

test("a label with markup is escaped", () => {
    const r = renderError("restarting", { label: "<script>alert(1)</script>\"'&" });
    assert.ok(!r.body.includes("<script"));
    assert.ok(r.body.includes("&lt;script&gt;alert(1)&lt;/script&gt;&quot;&#39;&amp;"));
    const n = renderError("not_paired", { label: "<img src=x onerror=y>" });
    assert.ok(!n.body.includes("<img"));
});

test("a control character in the label is dropped and an overlong label is cut", () => {
    const r = renderError("restarting", { label: "A\r\nB" + "x".repeat(200) });
    assert.ok(!r.body.includes("A\r"));
    assert.ok(r.body.includes("AB"));
    assert.ok(!r.body.includes("x".repeat(100)));
});

test("static page: no script, no external resource, strict headers", () => {
    for (const [kind, [, , opts]] of Object.entries(COPY)) {
        const r = renderError(kind, opts);
        assert.ok(!/<script/i.test(r.body), kind);
        assert.ok(!/https?:\/\//i.test(r.body), kind);
        assert.ok(!/<(link|img|iframe|object|embed)\b/i.test(r.body), kind);
        assert.strictEqual(r.headers["Content-Security-Policy"], "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'");
        assert.strictEqual(r.headers["Cache-Control"], "no-store");
        assert.match(r.headers["Content-Type"], /^text\/html; charset=utf-8$/);
        assert.strictEqual(r.headers["Content-Length"], String(Buffer.byteLength(r.body)));
        assert.strictEqual(r.headers["X-Content-Type-Options"], "nosniff");
    }
});

test("a missing label has a neutral default; an unknown kind throws", () => {
    assert.ok(renderError("restarting", {}).body.includes("The host's bench is restarting, try again in a moment"));
    assert.ok(renderError("not_paired").body.includes("The host removed this Mac"));
    assert.throws(() => renderError("nope", {}));
});
