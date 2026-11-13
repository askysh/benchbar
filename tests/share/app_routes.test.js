"use strict";
const test = require("node:test");
const assert = require("node:assert");
const path = require("path");
const { spawnSync } = require("child_process");

const LIB = path.join(__dirname, "../../lib/frappe-local/share");

// The hooks of the installed apps go in as JSON; the routes the gateway may let through come out.
function routes(appsScreen, websiteRules) {
    const code = "import json, sys; sys.path.insert(0, sys.argv[1]); import app_routes as a; d = json.load(sys.stdin);"
        + " print(json.dumps(a.app_routes(d['screen'], d['rules'])))";
    const r = spawnSync("python3", ["-I", "-c", code, LIB], { input: JSON.stringify({ screen: appsScreen, rules: websiteRules }), encoding: "utf8" });
    assert.strictEqual(r.status, 0, r.stderr);
    return JSON.parse(r.stdout);
}

test("an app front end counts from the apps screen or from a single page app route rule", () => {
    const got = routes(
        [{ route: "/crm" }, { route: "/app/hr" }, { route: "/manufacturing-ops" }, "not a dict", { route: 7 }],
        [
            { from_route: "/engineering-change/<path:app_path>", to_route: "engineering-change" },
            { from_route: "/crm/<path:app_path>", to_route: "crm" },
            { from_route: "/rfq/<path:name>", to_route: "rfq" },
            { from_route: "/orders", to_route: "Sales Order" },
            { from_route: "/profile", to_route: "me" },
            { from_route: "/x/<path:app_path>", to_route: "something-else" },
            { from_route: "/Bad Name/<path:app_path>", to_route: "Bad Name" },
            {}
        ]);
    assert.deepStrictEqual(got, ["/crm", "/app/hr", "/manufacturing-ops", "/engineering-change"]);
});

test("nothing in, nothing out", () => {
    assert.deepStrictEqual(routes(null, null), []);
});
