"use strict";

const MAX_LABEL = 80;

const KINDS = {
    not_available: { status: 403, line: () => "This page isn't available through sharing" },
    restarting: { status: 503, line: (label) => `${label}'s bench is restarting, try again in a moment`, retryAfter: "5" },
    ended: { status: 403, line: () => "Sharing has ended" },
    not_paired: { status: 403, line: (label) => `${label} removed this Mac` }
};

const escapeHtml = (s) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

function cleanLabel(label) {
    const plain = String(label ?? "").replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, "").slice(0, MAX_LABEL).trim();
    return plain || "The host";
}

function renderError(kind, { label } = {}) {
    const def = KINDS[kind];
    if (!def) throw new Error(`unknown error page kind: ${kind}`);
    const line = def.line(escapeHtml(cleanLabel(label)));
    const body = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>BenchBar</title>
<style>body{font:16px/1.5 -apple-system,system-ui,sans-serif;margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#f6f6f7;color:#1d1d1f}main{max-width:28rem;padding:2rem;text-align:center}@media(prefers-color-scheme:dark){body{background:#1d1d1f;color:#f5f5f7}}</style>
</head><body><main><p>${line}</p></main></body></html>
`;
    const headers = {
        "Content-Type": "text/html; charset=utf-8",
        "Content-Length": String(Buffer.byteLength(body)),
        "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff"
    };
    if (def.retryAfter) headers["Retry-After"] = def.retryAfter;
    return { status: def.status, headers, body };
}

module.exports = { renderError };
