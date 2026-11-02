"use strict";
const { execFile } = require("child_process");

const HELPER_TIMEOUT_MS = 20_000;
// Frappe sids are 40 hex characters; this accepts anything that is safe in a Set-Cookie value.
const SID_RE = /^[A-Za-z0-9_-]{8,200}$/;

// user and site are the only argv. The sid comes back on stdout and is handed
// to the caller; nothing here stores or logs it, and a failure reports no
// helper output (stderr could echo it).
function createSignin({ python, helper, site, run = execFile }) {
    function mint(user) {
        return new Promise((resolve, reject) => {
            run(python, [helper, site, user], { timeout: HELPER_TIMEOUT_MS, maxBuffer: 4096, encoding: "utf8" }, (err, stdout) => {
                const sid = typeof stdout === "string" ? stdout.trim() : "";
                if (err || !SID_RE.test(sid)) return reject(new Error("signin_failed"));
                resolve(sid);
            });
        });
    }
    return { mint };
}

module.exports = { createSignin };
