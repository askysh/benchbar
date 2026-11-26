#!/usr/bin/env bash
# site/public/moved-anchors.js (#169): the old address of a split page sends an
# anchor that moved to its new page, and nothing else. A hash that names a
# built-in property of an object (#constructor, #__proto__, #toString) is no
# anchor that moved: the page stays where it is. A malformed escape in the hash
# is no reason for the script to throw.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

if ! command -v node >/dev/null 2>&1; then
  printf 'test-moved-anchors: ok (SKIPPED: no node)\n'
  exit 0
fi

# run_anchor PATH HASH: what the script did, as "replace:URL" or "stay"
run_anchor() {
  node -e '
    const fs = require("fs");
    const code = fs.readFileSync(process.argv[1], "utf8");
    let result = "stay";
    const window = { MOVED_ANCHORS: {
      "/json-schema/": { "rules-for-readers": "/json-schema/", "benchbar-app-list---json": "/reference/json/apps/" }
    } };
    const location = { pathname: process.argv[2], hash: process.argv[3], replace: (u) => { result = "replace:" + u; } };
    const document = { getElementById: () => null };
    try { new Function("window", "location", "document", code)(window, location, document); }
    catch (e) { result = "threw:" + e.name; }
    process.stdout.write(result);
  ' "$ROOT/site/public/moved-anchors.js" "$1" "$2"
}

assert_eq "replace:/reference/json/apps/#benchbar-app-list---json" "$(run_anchor /json-schema/ '#benchbar-app-list---json')" "(an anchor that moved goes to its new page)"
assert_eq "replace:/reference/json/apps/#benchbar-app-list---json" "$(run_anchor /json-schema '#benchbar-app-list---json')" "(the path without its last slash too)"
assert_eq "stay" "$(run_anchor /json-schema/ '#no-such-heading')" "(an unknown anchor stays)"
assert_eq "stay" "$(run_anchor /other-page/ '#benchbar-app-list---json')" "(another page is not touched)"
for builtin in constructor __proto__ toString hasOwnProperty valueOf; do
  assert_eq "stay" "$(run_anchor /json-schema/ "#${builtin}")" "(#${builtin} is a built-in name, not a moved anchor)"
  assert_eq "stay" "$(run_anchor "/${builtin}/" '#benchbar-app-list---json')" "(a page path named ${builtin} is no moved page)"
done
assert_eq "stay" "$(run_anchor /json-schema/ '#%E0%A4%A')" "(a malformed escape does not throw)"

printf 'test-moved-anchors: ok\n'
