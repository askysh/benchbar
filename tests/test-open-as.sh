#!/usr/bin/env bash
# open (with and without --as) and users: the guards, the link, the session
# id kept out of logs and JSON, and argv that survives quotes and '+'.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=tests/lib/install-stream.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/install-stream.sh"

BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" v16dev
printf 'port 11000\n' >"$BENCH/config/redis_queue.conf"; printf 'port 13000\n' >"$BENCH/config/redis_cache.conf"
printf '127.0.0.1 v16dev\n' >>"$FL_HOSTS_FILE"
printf '{\n "db_name": "_v16dev",\n "developer_mode": 1\n}\n' >"$BENCH/sites/v16dev/site_config.json"
cat >"$MOCK_STATE/users.json" <<'JSON'
[
 {"name": "Administrator", "full_name": "Administrator", "user_type": "System User", "enabled": 1, "roles": ["System Manager"], "last_login": null},
 {"name": "priya@example.com", "full_name": "Priya Nair", "user_type": "System User", "enabled": 1, "roles": ["NE", "Stock User"], "last_login": "2026-10-29 10:00:00"},
 {"name": "a+b@x.com", "full_name": "O'Brien X", "user_type": "System User", "enabled": 1, "roles": [], "last_login": null},
 {"name": "web@example.com", "full_name": "Web Customer", "user_type": "Website User", "enabled": 1, "roles": ["Customer"], "last_login": null},
 {"name": "gone@example.com", "full_name": "Gone", "user_type": "System User", "enabled": 0, "roles": [], "last_login": null}
]
JSON
bench_up() { add_listener 8000 4242 python; add_listener 13000 4243 redis-server; }

# ---- Open as is off until a person turns it on for the site
run_fm open --as priya@example.com --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "Open as is off for v16dev"; assert_contains "$OUT" "benchbar site open-as on v16dev"
run_fm users --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "Open as is off for v16dev"; assert_contains "$OUT" "benchbar site open-as on v16dev"
assert_calls_not_contain '^bench-python'
assert_calls_not_contain '^open '
run_fm site open-as status --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "False True False" "$(printf '%s' "$OUT" | jget - 'd["open_as_enabled"], d["developer_mode"], d["open_as"]' | tr -d "(),'")" "(developer_mode alone does not make it work)"
run_fm site list --json --bench-dir "$BENCH"
assert_eq "False True False" "$(printf '%s' "$OUT" | jget - 'd["sites"][0]["open_as_enabled"], d["sites"][0]["developer_mode"], d["sites"][0]["open_as"]' | tr -d "(),'")"

# nothing that cannot ask turns it on: BENCHBAR_NONINTERACTIVE=1, --for-agent and the MCP server
BENCHBAR_NONINTERACTIVE=1 run_fm site open-as on v16dev --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "person"; assert_contains "$OUT" "terminal"
run_fm site open-as on v16dev --yes --for-agent --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
run_fm site open-as on v16dev --yes --dry-run --for-agent --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
run_fm site open-as status --bench-dir "$BENCH"
assert_contains "$OUT" "Open as is off"
if grep -rq OPEN_AS_SITES "$FL_STATE_DIR" 2>/dev/null; then fail "a refused on left a record"; fi
# --yes without a terminal (an agent's plain shell) is refused too; the app passes BENCHBAR_SUDO=gui after its alert
run_fm site open-as on v16dev --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "needs a person at a terminal"
# a name that is no site
run_fm site open-as on nosuch --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "No site 'nosuch'"
run_fm site open-as sideways --bench-dir "$BENCH"; assert_eq "1" "$CODE"; assert_contains "$OUT" "Usage: benchbar site open-as on|off|status"

# on: what a sign in does is said, the choice is benchbar state only
snap_sites="$(snapshot "$BENCH/sites")"
BENCHBAR_SUDO=gui run_fm site open-as on --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "on_login"; assert_contains "$OUT" "last_login"; assert_contains "$OUT" "simultaneous_sessions"
assert_contains "$OUT" "on_session_creation"; assert_contains "$OUT" "Activity Log"; assert_contains "$OUT" "System Managers"; assert_contains "$OUT" "does not end the sessions already made"
assert_eq "$snap_sites" "$(snapshot "$BENCH/sites")" "(on writes nothing under sites/)"
BENCHBAR_SUDO=gui run_fm site open-as on v16dev --yes --bench-dir "$BENCH"
assert_contains "$OUT" "unchanged: Open as is already on for v16dev"
run_fm site open-as status --json --bench-dir "$BENCH"
assert_eq "True True True" "$(printf '%s' "$OUT" | jget - 'd["open_as_enabled"], d["developer_mode"], d["open_as"]' | tr -d "(),'")"
run_fm site list --json --bench-dir "$BENCH"
assert_eq "True True True" "$(printf '%s' "$OUT" | jget - 'd["sites"][0]["open_as_enabled"], d["sites"][0]["developer_mode"], d["sites"][0]["open_as"]' | tr -d "(),'")"
run_fm status --json --bench-dir "$BENCH"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["sites"][0]["open_as"]')" "(status carries it too)"
# on and off as a stream: one done line with the changed record
stream site open-as off v16dev --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "open_as v16dev False" "$(sx 'e[-1]["changed"][0]["kind"] + " " + e[-1]["site"] + " " + str(e[-1]["open_as_enabled"])')"
run_fm site open-as off v16dev --bench-dir "$BENCH"
assert_contains "$OUT" "unchanged: Open as is already off"
# off is allowed without a terminal
BENCHBAR_NONINTERACTIVE=1 run_fm site open-as off v16dev --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
# not in developer mode yet: on says so and still records the choice
printf '{\n "db_name": "_v16dev"\n}\n' >"$BENCH/sites/v16dev/site_config.json"
BENCHBAR_SUDO=gui run_fm site open-as on v16dev --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "not in developer mode"
OUT="$("$FM" site open-as status --json --bench-dir "$BENCH" 2>/dev/null)"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["warnings"][0]')" "not in developer mode"
assert_eq "True False False" "$(printf '%s' "$OUT" | jget - 'd["open_as_enabled"], d["developer_mode"], d["open_as"]' | tr -d "(),'")"
printf '{\n "db_name": "_v16dev",\n "developer_mode": 1\n}\n' >"$BENCH/sites/v16dev/site_config.json"

# ---- the bench must run: no session, no python, no browser while it is stopped
run_fm open --as priya@example.com --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "The bench is not running."; assert_contains "$OUT" "benchup"
run_fm users --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "The bench is not running."
assert_calls_not_contain '^bench-python'
assert_calls_not_contain '^open '
bench_up

# plain open needs no opt-in
run_fm site open-as off v16dev --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
run_fm open --no-browser --bench-dir "$BENCH"
assert_eq "0" "$CODE" "(plain open stays available) $OUT"
BENCHBAR_SUDO=gui run_fm site open-as on v16dev --yes --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"

# ---- users
run_fm users --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "v16dev False" "$(printf '%s' "$OUT" | jget - 'd["site"], d["truncated"]' | tr -d "(),'")"
assert_eq "Administrator a+b@x.com priya@example.com web@example.com" "$(printf '%s' "$OUT" | jget - '" ".join(u["name"] for u in d["users"])')" "(enabled only, System Users first)"
assert_eq "1 2" "$(printf '%s' "$OUT" | jget - 'd["schema_version"] > 0 and 1, d["users"][2]["role_count"]' | tr -d "(),'")"
run_fm users --json --search PRI --bench-dir "$BENCH"
assert_eq "priya@example.com" "$(printf '%s' "$OUT" | jget - '" ".join(u["name"] for u in d["users"])')"
run_fm users --json --limit 1 --bench-dir "$BENCH"
assert_eq "True 1" "$(printf '%s' "$OUT" | jget - 'd["truncated"], len(d["users"])' | tr -d "(),'")"
run_fm users --search "o'brien x" --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "a+b@x.com"
assert_calls_contain "^bench-python benchbar-users \[v16dev\] \[o'brien x\] \[50\] \[table\]$" "(the search is one argument, quote and space kept)"
run_fm users --search nobody --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" 'No enabled user on v16dev matches "nobody".'
run_fm users --limit 0 --bench-dir "$BENCH"; assert_eq "1" "$CODE"; assert_contains "$OUT" "--limit needs a number from 1 to 500."
run_fm users --limit abc --bench-dir "$BENCH"; assert_eq "1" "$CODE"; assert_contains "$OUT" "--limit needs a number from 1 to 500."
run_fm users --site nosuch --bench-dir "$BENCH"; assert_eq "1" "$CODE"; assert_contains "$OUT" "No site 'nosuch'"

# ---- open --as: the link, opened once, with the session id only on the opener's line
reset_calls
run_fm open --as priya@example.com --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "priya@example.com|Priya Nair|System User|/app|True|False" \
  "$(printf '%s' "$OUT" | jget - '"|".join(str(x) for x in (d["user"], d["full_name"], d["user_type"], d["path"], d["opened"], "url" in d))')"
assert_not_contains "$OUT" "mocksid" "(no session id in --json without --print-url)"
assert_calls_contain '^open http://v16dev:8000/login\?redirect-to=%2Fapp&sid=mocksid0123456789&t=[0-9]+$'
assert_eq "1" "$(grep -c '^open ' "$MOCK_LOG")"
assert_calls_contain '^bench-python benchbar-open-as \[v16dev\] \[priya@example.com\]$'
# the session id reaches no file benchbar keeps
if grep -r -q mocksid "$FL_STATE_DIR" 2>/dev/null; then fail "a session id was written under $FL_STATE_DIR"; fi
if grep -r -q mocksid "$BENCH/sites" 2>/dev/null; then fail "a session id was written under sites/"; fi

# --print-url: the link on stdout, nothing opened
reset_calls
run_fm open --as priya@example.com --print-url --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["opened"]')"
case "$(printf '%s' "$OUT" | jget - 'd["url"]')" in
  "http://v16dev:8000/login?redirect-to=%2Fapp&sid=mocksid0123456789&t="[0-9]*) ;;
  *) fail "unexpected url: $OUT" ;;
esac
assert_calls_not_contain '^open '
OUT_URL="$("$FM" open --as priya@example.com --print-url --bench-dir "$BENCH" 2>/dev/null)"
assert_eq "1" "$(printf '%s\n' "$OUT_URL" | wc -l | tr -d ' ')" "(--print-url alone prints one line)"
case "$OUT_URL" in http://v16dev:8000/login\?redirect-to=%2Fapp\&sid=mocksid0123456789\&t=[0-9]*) ;; *) fail "unexpected url line: $OUT_URL" ;; esac

# '+' and a quote in the user id stay one argument and come back unchanged
reset_calls
run_fm open --as 'a+b@x.com' --no-browser --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "a+b@x.com O'Brien X" "$(printf '%s' "$OUT" | jget - 'd["user"] + " " + d["full_name"]')"
assert_calls_contain '^bench-python benchbar-open-as \[v16dev\] \[a\+b@x.com\]$'
assert_calls_not_contain '^open '

# --path: an old sid is dropped, the rest kept and encoded once; a Website User lands on /
reset_calls
run_fm open --as priya@example.com --path '/app/nst?status=Open&sid=old#x' --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^open http://v16dev:8000/login\?redirect-to=%2Fapp%2Fnst%3Fstatus%3DOpen%23x&sid=mocksid0123456789&t=[0-9]+$'
reset_calls
run_fm open --as web@example.com --bench-dir "$BENCH"
assert_calls_contain '^open http://v16dev:8000/login\?redirect-to=%2F&sid='
run_fm open --as priya@example.com --path app/x --bench-dir "$BENCH"; assert_eq "1" "$CODE"; assert_contains "$OUT" "--path must start with a single /."
run_fm open --as priya@example.com --path //evil.example --bench-dir "$BENCH"; assert_eq "1" "$CODE"; assert_contains "$OUT" "--path must start with a single /."
run_fm open --as priya@example.com --path '/\evil.example' --bench-dir "$BENCH"; assert_eq "1" "$CODE"; assert_contains "$OUT" "--path cannot hold a backslash."

# ---- refusals from the helper come through as they are
run_fm open --as nobody@example.com --bench-dir "$BENCH"; assert_eq "1" "$CODE"; assert_contains "$OUT" "No user 'nobody@example.com' on v16dev."
run_fm open --as gone@example.com --bench-dir "$BENCH"; assert_eq "1" "$CODE"; assert_contains "$OUT" "gone@example.com is disabled on v16dev."
MOCK_OPEN_AS_REFUSE="Frappe refused the login: Access not allowed from this IP Address" run_fm open --as priya@example.com --json --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "Frappe refused the login: Access not allowed from this IP Address"
run_fm open --as Guest --bench-dir "$BENCH"; assert_eq "1" "$CODE"; assert_contains "$OUT" "Guest has no session to open."
run_fm open --as --bench-dir "$BENCH"; assert_eq "1" "$CODE"; assert_contains "$OUT" "--as needs a user."
run_fm open --nonsense --bench-dir "$BENCH"; assert_eq "1" "$CODE"; assert_contains "$OUT" "Unknown argument for open: --nonsense"
# a flag that takes a value, given last: a message, not a silent exit
run_fm open --bench-dir "$BENCH" --as priya@example.com --path; assert_eq "1" "$CODE"; assert_contains "$OUT" "--path needs a page."
run_fm users --bench-dir "$BENCH" --search; assert_eq "1" "$CODE"; assert_contains "$OUT" "--search needs some text."
run_fm users --bench-dir "$BENCH" --limit; assert_eq "1" "$CODE"; assert_contains "$OUT" "--limit needs a number from 1 to 500."
# no here-string carries the session id: bash 3.2 writes those to /var/tmp
if grep -n '<<<' "$ROOT/lib/frappe-local/open-as.sh" | grep -q -E 'fields|__out'; then fail "a here-string carries helper output in open-as.sh"; fi

# ---- developer_mode off: refused before any Python runs, Administrator included
printf '{\n "db_name": "_v16dev"\n}\n' >"$BENCH/sites/v16dev/site_config.json"
reset_calls
run_fm open --as Administrator --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "v16dev is not in developer mode"; assert_contains "$OUT" "set-config developer_mode 1"
assert_calls_not_contain '^bench-python'
# without --as it is plain Open Site: no gate, no session, no Python
run_fm open --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^open http://v16dev:8000$'
assert_calls_not_contain '^bench-python'
printf '{\n "db_name": "_v16dev",\n "developer_mode": 1\n}\n' >"$BENCH/sites/v16dev/site_config.json"

# ---- a second site. bench serve answers as the default_site of
# common_site_config.json for every name, so --as on another site is refused
# with the way out; plain open is not a sign-in and stays allowed
mkdir -p "$BENCH/sites/two.localhost" "$BENCH/sites/three"
printf '{\n "developer_mode": 1\n}\n' >"$BENCH/sites/two.localhost/site_config.json"
printf '{\n "developer_mode": 1\n}\n' >"$BENCH/sites/three/site_config.json"
BENCHBAR_SUDO=gui run_fm site open-as on two.localhost --yes --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
BENCHBAR_SUDO=gui run_fm site open-as on three --yes --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
reset_calls
run_fm open --site two.localhost --as priya@example.com --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Port 8000 serves only v16dev, the bench's default site, so a sign-in on two.localhost would land logged out."
assert_contains "$OUT" "benchbar site default two.localhost, then benchrestart"
assert_calls_not_contain '^bench-python'
run_fm open --site two.localhost --no-browser --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
run_fm open --site three --as priya@example.com --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "three has no hosts line"; assert_contains "$OUT" "benchbar site hosts"
# made the default, a *.localhost site needs no hosts line and its own name and port flow through
cp "$BENCH/sites/common_site_config.json" "$TMP_DIR/common.orig"
sed_inplace 's/"default_site": "v16dev"/"default_site": "two.localhost"/' "$BENCH/sites/common_site_config.json"
reset_calls
run_fm open --site two.localhost --as priya@example.com --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^open http://two.localhost:8000/login\?redirect-to=%2Fapp&sid='
assert_calls_contain '^bench-python benchbar-open-as \[two.localhost\] \[priya@example.com\]$'
cp "$TMP_DIR/common.orig" "$BENCH/sites/common_site_config.json"

# ---- a path with a bare sid and empty parameters: both go
reset_calls
run_fm open --as priya@example.com --path '/app/x?a=1&&sid&b=2' --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^open http://v16dev:8000/login\?redirect-to=%2Fapp%2Fx%3Fa%3D1%26b%3D2&sid='

# ---- a path with bytes above 127 is encoded byte by byte (bash 3.2 sign extends them)
reset_calls
run_fm open --as priya@example.com --path '/app/café' --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^open http://v16dev:8000/login\?redirect-to=%2Fapp%2Fcaf%C3%A9&sid='

# ---- a second run works the same (a launch has no "unchanged")
reset_calls
run_fm open --as priya@example.com --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "v16dev: opened as priya@example.com (Priya Nair, System User) at /app"
run_fm open --as priya@example.com --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"; assert_eq "2" "$(grep -c '^open ' "$MOCK_LOG")"

# ---- no browser opener: refused with the way out
MOCK_OPEN_EXIT=127 run_fm open --as priya@example.com --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "benchbar open --print-url"

# ---- Linux opens with xdg-open, WSL with wslview (the Windows browser). A
# Linux bench's sites are *.localhost names, which resolve without a hosts line
use_linux
sed_inplace 's/"default_site": "v16dev"/"default_site": "two.localhost"/' "$BENCH/sites/common_site_config.json"
reset_calls
run_fm open --site two.localhost --as priya@example.com --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^wslview http://two.localhost:8000/login\?redirect-to=%2Fapp&sid=mocksid0123456789&t=[0-9]+$'
# WSL: the Windows browser reads Windows' hosts file, so only localhost names are offered
printf 'three\n' >>"$MOCK_STATE/hosts_resolve"
sed_inplace 's/"default_site": "two.localhost"/"default_site": "three"/' "$BENCH/sites/common_site_config.json"
run_fm open --site three --as priya@example.com --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "three is not a *.localhost name, so the Windows browser may not reach it from WSL."
run_fm open --site three --as priya@example.com --print-url --bench-dir "$BENCH"
assert_eq "0" "$CODE" "(the person opens the link: --print-url is not refused) $OUT"
run_fm open --site three --no-browser --bench-dir "$BENCH"
assert_eq "0" "$CODE" "(plain open is not a sign-in) $OUT"
sed_inplace 's/"default_site": "three"/"default_site": "two.localhost"/' "$BENCH/sites/common_site_config.json"
printf 'Linux version 6.8.0-45-generic (buildd@lcy02) #45-Ubuntu SMP\n' >"$FL_PROC_VERSION"
reset_calls
run_fm open --site two.localhost --as priya@example.com --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^xdg-open http://two.localhost:8000/login\?redirect-to=%2Fapp&sid='
# a browser opener that talks on stdout (Chrome: "Opening in existing browser session.") leaves --json clean
OUT_JSON="$(MOCK_OPEN_SAYS="Opening in existing browser session." "$FM" open --site two.localhost --as priya@example.com --json --bench-dir "$BENCH" 2>/dev/null)"
assert_eq "True" "$(printf '%s' "$OUT_JSON" | jget - 'd["opened"]')" "(stdout is the JSON document alone)"

echo "PASS test-open-as"
