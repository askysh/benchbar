"use strict";
const test = require("node:test");
const assert = require("node:assert");
const policy = require("../../lib/frappe-local/share/policy.js");
const vectors = require("./vectors.json");

test("normalizePath matches the shared vectors", () => {
    for (const v of vectors.paths) {
        const r = policy.normalizePath(v.raw);
        assert.strictEqual(r.ok, v.ok, `ok for ${JSON.stringify(v.raw)}: ${JSON.stringify(r)}`);
        if (v.ok) {
            assert.strictEqual(r.path, v.path, `path for ${JSON.stringify(v.raw)}`);
            assert.strictEqual(r.forward, v.forward, `forward for ${JSON.stringify(v.raw)}`);
            assert.strictEqual(r.search, v.search, `search for ${JSON.stringify(v.raw)}`);
        } else {
            assert.ok(r.reason, `a rejection names its reason: ${JSON.stringify(v.raw)}`);
        }
    }
});

test("normalizePath rejects an oversized target and a non-string", () => {
    assert.strictEqual(policy.normalizePath("/" + "a".repeat(2048)).ok, false);
    assert.strictEqual(policy.normalizePath("/" + "a".repeat(2047)).ok, true);
    assert.strictEqual(policy.normalizePath(undefined).ok, false);
    assert.strictEqual(policy.normalizePath(Buffer.from("/app")).ok, false);
});

test("forward never contains a decoded slash, backslash or dot segment, and round-trips", () => {
    const raws = ["/app/a%20b", "/%61pp/x", "/app/%E2%82%AC/y", "/a/b%2Bc", "/app/a%25", "/files/we%3Fird%23name.png"];
    for (const raw of raws) {
        const r = policy.normalizePath(raw);
        assert.ok(r.ok, raw);
        assert.ok(!/[\\]/.test(r.forward) && !r.forward.includes("//"), r.forward);
        assert.ok(!r.forward.split("/").some((s) => s === ".." || s === "."), r.forward);
        assert.strictEqual(decodeURIComponent(r.forward), r.path, `upstream decodes forward back to path: ${raw}`);
        assert.strictEqual(r.forward.split("/").length, r.path.split("/").length, "no segment boundary is created or lost");
    }
});

test("isAllowed accepts the Frappe allowlist", () => {
    const ok = (m, p) => policy.isAllowed(m, p, {});
    for (const p of ["/", "/app", "/app/", "/app/sales-order/SO-0042", "/login", "/logout", "/assets/frappe/js/x.js", "/files/a.png",
        "/private/files/a.pdf", "/api/method/frappe.client.get", "/api/resource/User", "/printview", "/manifest.json", "/sw.js",
        "/favicon.ico", "/website_script.js", "/update-password", "/me"]) {
        const r = ok("GET", p);
        assert.strictEqual(r.ok, true, p);
        assert.strictEqual(r.route, "web", p);
    }
    assert.deepStrictEqual(ok("GET", "/_benchbar/hello"), { ok: true, route: "hello" });
    assert.deepStrictEqual(ok("GET", "/_benchbar/signin"), { ok: true, route: "signin" });
    assert.deepStrictEqual(ok("POST", "/_benchbar/leave"), { ok: true, route: "leave" });
    assert.strictEqual(ok("POST", "/pair/start").route, "pair");
    assert.strictEqual(ok("POST", "/pair/reveal").route, "pair");
    assert.strictEqual(ok("GET", "/pair/start").ok, false);
    for (const m of ["GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS"]) assert.strictEqual(ok(m, "/app").ok, true, m);
});

test("isAllowed refuses everything else, including the debugger and other upstreams", () => {
    const no = (m, p) => policy.isAllowed(m, p, {});
    for (const p of ["/console", "/CONSOLE", "/%63onsole", "/application", "/appx", "/api", "/api/", "/api/method", "/api/other",
        "/api/v2/x", "/private/other", "/private", "/files", "/assets", "/me/x", "/printview/x", "/_benchbar", "/_benchbar/other",
        "/_benchbar/hello/x", "/server-status", "/login/x", "/__debugger__", "/app;x", "/.git/config", "/robots.txt"]) {
        const n = policy.normalizePath(p);
        if (!n.ok) continue;
        assert.strictEqual(no("GET", n.path).ok, false, p);
    }
    for (const m of ["TRACE", "CONNECT", "PATCH", "PROPFIND", "get", ""]) assert.strictEqual(no(m, "/app").ok, false, m);
});

test("socket.io and anything under it is gone, in any case or encoding, with any method", () => {
    for (const raw of ["/socket.io", "/socket.io/", "/SOCKET.IO/", "/Socket.Io/x/y", "/socket%2eio/", "/socket%2Eio/?EIO=4", "/%73ocket.io/",
        "/socket.io/?EIO=4&transport=polling"]) {
        const n = policy.normalizePath(raw);
        assert.ok(n.ok, raw);
        for (const m of ["GET", "POST", "OPTIONS", "DELETE"]) {
            const r = policy.isAllowed(m, n.path, {});
            assert.deepStrictEqual(r, { ok: false, route: "gone" }, `${m} ${raw}`);
        }
    }
    assert.strictEqual(policy.isAllowed("GET", "/socket.iox", {}).route, undefined);
});

test("only ASCII is lower-cased (the Kelvin sign is not a k)", () => {
    assert.strictEqual(policy.isAllowed("GET", "/Kernel", {}).ok, false);
    assert.strictEqual(policy.isAllowed("GET", "/APP/x", {}).ok, true);
});

test("safeNext keeps only /app and /app/... and re-encodes", () => {
    assert.strictEqual(policy.safeNext("/app"), "/app");
    assert.strictEqual(policy.safeNext("/app/sales-order/SO-1"), "/app/sales-order/SO-1");
    assert.strictEqual(policy.safeNext("/app/sales%20order?x=1"), "/app/sales%20order?x=1");
    for (const bad of ["//evil.example", "/api/method/x", "http://x", "https://x/app", "\\evil", "/app/../api/method/x", "/app%2f%2fx", "/appx",
        "/", "", "app", undefined, null, 5, "/app\\x", "/app//x", "/%2e%2e/app", "/APP/x"]) {
        assert.strictEqual(policy.safeNext(bad), null, String(bad));
    }
});

test("hostAllowed", () => {
    for (const h of ["a.localhost", "a.localhost:8443", "my-site.localhost:1", "0.localhost:65535"]) assert.strictEqual(policy.hostAllowed(h), true, h);
    for (const h of ["127.0.0.1:8000", "localhost", "localhost:8000", "evil.com", "a.localhost.evil.com", "-a.localhost", "a_b.localhost",
        "A.localhost", "a.localhost:", "a.localhost:123456", "a.localhost:80, b.localhost", "a.localhost ", " a.localhost", "a.localhost/x",
        "a.localhost@evil.com", "", undefined, null, "x".repeat(70) + ".localhost"]) {
        assert.strictEqual(policy.hostAllowed(h), false, String(h));
    }
    assert.strictEqual(policy.hostAllowed(["a.localhost", "a.localhost"]), false, "a duplicate Host fails");
});

test("singleHost reads exactly one Host from the raw headers", () => {
    assert.strictEqual(policy.singleHost(["Host", "a.localhost", "Accept", "*/*"]), "a.localhost");
    assert.strictEqual(policy.singleHost(["host", "a.localhost", "HOST", "a.localhost"]), null);
    assert.strictEqual(policy.singleHost(["Accept", "*/*"]), null);
});

test("originAllowed and fetchSiteAllowed", () => {
    assert.strictEqual(policy.originAllowed(undefined, "POST"), true);
    assert.strictEqual(policy.originAllowed("http://a.localhost:8443", "POST"), true);
    for (const o of ["https://a.localhost", "http://evil.com", "null", "http://a.localhost.evil.com", "http://127.0.0.1:8000", "a.localhost", ""]) {
        assert.strictEqual(policy.originAllowed(o, "POST"), false, o);
    }
    for (const v of [undefined, "same-origin", "none"]) assert.strictEqual(policy.fetchSiteAllowed(v), true, String(v));
    for (const v of ["same-site", "cross-site", "weird", ""]) assert.strictEqual(policy.fetchSiteAllowed(v), false, v);
});

test("sanitizeRequestHeaders strips forwarding, proxy, hop-by-hop and upgrade headers", () => {
    const out = policy.sanitizeRequestHeaders({
        "host": "a.localhost", "X-Forwarded-For": "1.2.3.4", "x-forwarded-host": "evil", "x-forwarded-proto": "https", "forwarded": "for=1",
        "x-real-ip": "1.1.1.1", "x-frappe-site-name": "other.site", "proxy-authorization": "x", "proxy-connection": "keep-alive",
        "upgrade": "websocket", "connection": "keep-alive, X-Secret", "x-secret": "s", "keep-alive": "5", "te": "trailers", "trailer": "x",
        "transfer-encoding": "chunked", "authorization": "token a:b", "accept": "*/*", "user-agent": "ua",
        "cookie": "sid=abc; other=1; preferred_language=en; full_name=Evil; SID=nope"
    });
    for (const k of ["x-forwarded-for", "x-forwarded-host", "x-forwarded-proto", "forwarded", "x-real-ip", "x-frappe-site-name",
        "proxy-authorization", "proxy-connection", "upgrade", "connection", "x-secret", "keep-alive", "te", "trailer", "transfer-encoding"]) {
        assert.ok(!(k in out), k);
    }
    assert.ok(!Object.keys(out).some((k) => /^x-forwarded|^proxy-/i.test(k)));
    assert.strictEqual(out.cookie, "sid=abc; preferred_language=en");
    assert.strictEqual(out.authorization, "token a:b");
    assert.strictEqual(out.accept, "*/*");
});

test("sanitizeRequestHeaders drops an empty cookie and does not mutate its input", () => {
    const input = { cookie: "a=1; b=2", accept: "x" };
    const out = policy.sanitizeRequestHeaders(input);
    assert.ok(!("cookie" in out));
    assert.strictEqual(input.cookie, "a=1; b=2");
    assert.strictEqual(policy.sanitizeRequestHeaders({ cookie: ["sid=1", "x=2"] }).cookie, "sid=1");
});

test("a __debugger__ query key is rejected in any case or encoding, on any path", () => {
    for (const raw of ["/app?__debugger__=yes&cmd=resource&f=style.css", "/app?%5F%5Fdebugger%5F%5F=yes&cmd=pinauth", "/app?x=1&__DEBUGGER__=yes",
        "/api/method/x?%5f%5fDebugger%5f%5f", "/app?a=1;__debugger__=1", "/app?__debugger__", "/app?__%64ebugger__=1", "/app?__debugger__=", "/?__debugger__=yes"]) {
        const r = policy.normalizePath(raw);
        assert.strictEqual(r.ok, false, raw);
        assert.strictEqual(r.reason, "debugger", raw);
    }
    assert.strictEqual(policy.normalizePath("/app?%E0%A4%A=1").ok, false);
    assert.strictEqual(policy.normalizePath("/app?x=__debugger__").ok, true, "a value is not a key");
    assert.strictEqual(policy.normalizePath("/app?debugger=1&_debugger_=2").ok, true);
});

test("redactPath drops file names", () => {
    assert.strictEqual(policy.redactPath("/files/Secret Customer.pdf"), "/files");
    assert.strictEqual(policy.redactPath("/files"), "/files");
    assert.strictEqual(policy.redactPath("/private/files/Payroll.xlsx"), "/private/files");
});

test("redactPath keeps the first two segments only", () => {
    assert.strictEqual(policy.redactPath("/app/sales-order/SO-0042"), "/app/sales-order");
    assert.strictEqual(policy.redactPath("/app/sales-order"), "/app/sales-order");
    assert.strictEqual(policy.redactPath("/app"), "/app");
    assert.strictEqual(policy.redactPath("/"), "/");
    assert.strictEqual(policy.redactPath("/api/method/frappe.client.get?name=Secret"), "/api/method");
    assert.strictEqual(policy.redactPath(""), "/");
});
