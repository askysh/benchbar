"use strict";

const MAX_TARGET_BYTES = 2048;
const FORBIDDEN_SEGMENT_CHARS = /[\u0000-\u001f\u007f-\u009f\u2028\u2029\/\\;]/;
const ESCAPE_LOOKALIKE = /%[0-9a-fA-F]{2}/;
const METHODS = new Set(["GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS"]);
const HOST_RE = /^[a-z0-9][a-z0-9-]{0,60}\.localhost(:[0-9]{1,5})?$/;

const SINGLE_SEGMENT_WEB = new Set(["login", "logout", "printview", "manifest.json", "sw.js", "favicon.ico",
    "website_script.js", "update-password", "me"]);
const BENCHBAR_ROUTES = {
    hello: { path: "/_benchbar/hello", methods: ["GET", "HEAD"] },
    signin: { path: "/_benchbar/signin", methods: ["GET", "HEAD"] },
    leave: { path: "/_benchbar/leave", methods: ["POST"] },
    room: { path: "/_benchbar/room", methods: ["GET", "HEAD"] },
    seats: { path: "/_benchbar/seats", methods: ["GET", "HEAD"] },
    seat: { path: "/_benchbar/seat", methods: ["POST"] },
    roomhello: { path: "/room/hello", methods: ["GET"] },
    joinstart: { path: "/room/join/start", methods: ["POST"] },
    joinfinish: { path: "/room/join/finish", methods: ["POST"] }
};

const HOP_BY_HOP = new Set(["connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "proxy-connection",
    "te", "trailer", "transfer-encoding", "upgrade"]);
const ALWAYS_STRIPPED = new Set(["forwarded", "x-real-ip", "x-frappe-site-name"]);
const COOKIES_KEPT = new Set(["sid", "preferred_language"]);

// ASCII only: toLowerCase() maps U+212A (Kelvin sign) to "k".
const asciiLower = (s) => s.replace(/[A-Z]/g, (c) => c.toLowerCase());

const reject = (reason) => ({ ok: false, reason });

function encodeSegment(segment) {
    let out = "";
    for (const byte of Buffer.from(segment, "utf8")) {
        const c = String.fromCharCode(byte);
        out += /[A-Za-z0-9\-._~]/.test(c) ? c : "%" + byte.toString(16).toUpperCase().padStart(2, "0");
    }
    return out;
}

// Werkzeug's DebuggedApplication answers on a `__debugger__` query key at ANY
// path, so the query cannot be passed through unlooked-at. Keys are decoded
// once, as Werkzeug does, and split on both & and ; separators.
function checkQuery(search) {
    if (search === "") return null;
    for (const pair of search.slice(1).split(/[&;]/)) {
        const rawKey = pair.split("=", 1)[0].replace(/\+/g, " ");
        let key;
        try {
            key = decodeURIComponent(rawKey);
        } catch {
            return "invalid_encoding";
        }
        if (asciiLower(key) === "__debugger__") return "debugger";
    }
    return null;
}

// Rejects rather than repairs. `forward` is re-encoded from the decoded
// segments so that one decode upstream (Werkzeug) yields exactly `path`;
// `search` is the validated query, passed through untouched.
function normalizePath(rawTarget) {
    if (typeof rawTarget !== "string") return reject("not_string");
    if (Buffer.byteLength(rawTarget) > MAX_TARGET_BYTES) return reject("too_long");
    if (!/^[\x21-\x7e]*$/.test(rawTarget)) return reject("bad_character");
    if (rawTarget[0] !== "/") return reject("not_origin_form");
    if (rawTarget.includes("\\")) return reject("backslash");
    if (rawTarget.includes("#")) return reject("fragment");

    const q = rawTarget.indexOf("?");
    const rawPath = q < 0 ? rawTarget : rawTarget.slice(0, q);
    const search = q < 0 ? "" : rawTarget.slice(q);
    if (/%00/i.test(search)) return reject("nul");
    const queryProblem = checkQuery(search);
    if (queryProblem) return reject(queryProblem);
    if (rawPath.includes("//")) return reject("empty_segment");

    const segments = [];
    for (const raw of rawPath.split("/").slice(1)) {
        let decoded;
        try {
            decoded = decodeURIComponent(raw);
        } catch {
            return reject("invalid_encoding");
        }
        if (decoded === "." || decoded === "..") return reject("dot_segment");
        if (FORBIDDEN_SEGMENT_CHARS.test(decoded)) return reject("forbidden_character");
        if (ESCAPE_LOOKALIKE.test(decoded)) return reject("double_encoding");
        segments.push(decoded);
    }
    return {
        ok: true,
        path: "/" + segments.join("/"),
        forward: "/" + segments.map(encodeSegment).join("/"),
        search
    };
}

// An app's own front end (add_to_apps_screen, e.g. /manufacturing-ops or /crm) is a Frappe www
// page plus /api calls, so Frappe's permission checks still apply. Only a plain slug that names
// nothing the gateway or Frappe's desk already owns can become one.
const APP_ROUTE_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;
const RESERVED_APP_ROUTES = new Set(["app", "apps", "api", "assets", "files", "private", "room", "pair", "console",
    ...SINGLE_SEGMENT_WEB]);
const NO_APP_ROUTES = new Set();

function appRouteSet(routes) {
    if (!Array.isArray(routes)) return new Set();
    return new Set(routes
        .filter((r) => typeof r === "string")
        .map((r) => r.replace(/^\//, ""))
        .filter((r) => APP_ROUTE_RE.test(r) && !RESERVED_APP_ROUTES.has(r)));
}

function webRoute(segments, appRoutes) {
    const [first, second] = segments;
    if (segments.length === 0) return true;
    if (first === "app") return true;
    if (first === "apps") return segments.length === 1;
    if (appRoutes.has(first)) return true;
    if (SINGLE_SEGMENT_WEB.has(first)) return segments.length === 1;
    if (first === "assets" || first === "files") return segments.length >= 2;
    if (first === "private") return second === "files" && segments.length >= 3;
    if (first === "api") return (second === "method" || second === "resource") && segments.length >= 3;
    return false;
}

// `path` is a normalizePath().path. The debugger is not on the allowlist;
// that is the point of allowlisting (and it is also switched off upstream).
// `appRoutes` comes from appRouteSet(); without it no app front end is allowed.
function isAllowed(method, path, { appRoutes = NO_APP_ROUTES } = {}) {
    const lower = asciiLower(String(path));
    const segments = lower.split("/").slice(1);
    if (segments[0] === "socket.io") return { ok: false, route: "gone" };
    if (!METHODS.has(method)) return { ok: false, reason: "method" };

    if (segments[segments.length - 1] === "") segments.pop();
    if (segments.includes("")) return { ok: false, reason: "forbidden" };
    const exact = "/" + segments.join("/");

    for (const [route, def] of Object.entries(BENCHBAR_ROUTES)) {
        if (exact === def.path) return def.methods.includes(method) ? { ok: true, route } : { ok: false, reason: "method" };
    }
    if (webRoute(segments, appRoutes)) return { ok: true, route: "web" };
    return { ok: false, reason: "forbidden" };
}

function safeNext(next) {
    const n = normalizePath(next);
    if (!n.ok) return null;
    if (n.path !== "/app" && !n.path.startsWith("/app/")) return null;
    return n.forward + n.search;
}

function hostAllowed(hostHeader) {
    const value = Array.isArray(hostHeader) && hostHeader.length === 1 ? hostHeader[0] : hostHeader;
    return typeof value === "string" && HOST_RE.test(value);
}

// Node keeps only the first of duplicate Host headers in req.headers, so the
// count has to come from req.rawHeaders.
function singleHost(rawHeaders) {
    let found = null;
    let count = 0;
    for (let i = 0; i + 1 < rawHeaders.length; i += 2) {
        if (rawHeaders[i].toLowerCase() === "host") {
            count++;
            found = rawHeaders[i + 1];
        }
    }
    return count === 1 ? found : null;
}

function originAllowed(originHeader) {
    if (originHeader === undefined || originHeader === null) return true;
    const m = typeof originHeader === "string" && /^http:\/\/(.+)$/.exec(originHeader);
    return Boolean(m) && hostAllowed(m[1]);
}

function fetchSiteAllowed(secFetchSite) {
    return secFetchSite === undefined || secFetchSite === null || secFetchSite === "same-origin" || secFetchSite === "none";
}

function keptCookies(cookieHeader) {
    const header = Array.isArray(cookieHeader) ? cookieHeader.join("; ") : String(cookieHeader);
    const seen = new Set();
    const kept = [];
    for (const pair of header.split(";")) {
        const trimmed = pair.trim();
        const name = trimmed.split("=", 1)[0];
        if (COOKIES_KEPT.has(name) && !seen.has(name)) {
            seen.add(name);
            kept.push(trimmed);
        }
    }
    return kept.join("; ");
}

function sanitizeRequestHeaders(headers) {
    const named = new Set();
    for (const [k, v] of Object.entries(headers)) {
        if (asciiLower(k) === "connection") {
            for (const token of String(v).split(",")) named.add(asciiLower(token.trim()));
        }
    }
    const out = {};
    for (const [key, value] of Object.entries(headers)) {
        const k = asciiLower(key);
        if (k.startsWith("x-forwarded-") || k.startsWith("proxy-") || ALWAYS_STRIPPED.has(k) || HOP_BY_HOP.has(k) || named.has(k)) continue;
        if (k === "cookie") {
            const cookie = keptCookies(value);
            if (cookie) out.cookie = cookie;
            continue;
        }
        out[k] = value;
    }
    return out;
}

function redactPath(path) {
    const bare = String(path).split(/[?#]/, 1)[0];
    const all = bare.split("/").filter(Boolean);
    // A file name is a document name (A16): keep only the /files prefix.
    return "/" + all.slice(0, all[0] === "files" ? 1 : 2).join("/");
}

module.exports = {
    normalizePath, isAllowed, appRouteSet, safeNext, hostAllowed, singleHost, originAllowed, fetchSiteAllowed,
    sanitizeRequestHeaders, redactPath
};
