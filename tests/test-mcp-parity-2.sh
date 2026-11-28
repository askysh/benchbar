#!/usr/bin/env bash
# benchbar mcp, the parity rows of #186 part 2: the CLI's own plan tokens for app install, app update, lock
# apply and profile remove (checked directly first), then the tools on the real CLI with the mocks: lock write,
# lock apply (plan, token, apply), pull (plan, token, apply, never the default site), profile create and remove,
# and what stays a person's (profile import, subscribe, update, export, --keep-secrets).
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=tests/lib/apps-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apps-fixtures.sh"

# an apply wants a plan that came back some seconds ago (tests/test-mcp-2.sh checks the wait itself)
export BENCHBAR_MCP_APPLY_DELAY=0
export BENCHBAR_MCP_EOF_GRACE=300
unset MARIADB_ROOT_PASSWORD ADMIN_PASSWORD

BENCH="$HOME/frappe-bench"
LOCK="$BENCH/benchbar.toml"
make_fake_bench "$BENCH" macdev
printf 'port 11000\n' >"$BENCH/config/redis_queue.conf"; printf 'port 13000\n' >"$BENCH/config/redis_cache.conf"
rmdir "$BENCH/apps/erpnext"
printf 'frappe 15.0.0\n' >"$BENCH/sites/macdev/installed_apps"
make_app_remote frappe
mv "$BENCH/apps/frappe" "$TMP_DIR/frappe-fake"
git clone -q --origin upstream --branch version-15 "file://$REMOTES/frappe.git" "$BENCH/apps/frappe"
printf 'frappe\n' >"$BENCH/sites/apps.txt"
make_app_remote acme_crm
make_app_remote acme_new
add_policy acme_crm main
add_policy acme_new main
run_fm app add acme_crm --site macdev --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
export MOCK_BENCH_VERSION=5.31.0
# the bench has a service, so the changing tools know it
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"

INIT='{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}'
mcp() { printf '%s\n' "$INIT" '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$@" | "$FM" mcp 2>/dev/null | tail -n +2; }
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$1" "$2" "$3"; }
tc() { mcp "$(call 1 "$1" "$2")"; }
# sc EXPR: an expression on the reply's structuredContent (the reply is on stdin)
sc() { jget - 'd["result"]["structuredContent"]'"$1"; }
err_of() { jget - 'd["result"]["isError"]'; }
# fm_json ARGS: the CLI's stdout alone (a --json document), its text goes to stderr; sets OUT and CODE
fm_json() { set +e; OUT="$("$FM" "$@" 2>/dev/null)"; CODE=$?; set -e; }
# the plan token of a CLI document
doc_token() { printf '%s' "$1" | jget - 'd["token"]'; }

# ---- the tools: what is offered, and what is not
R="$(mcp '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
printf '%s' "$R" | python3 -c '
import json, sys
t = {x["name"]: x for x in json.load(sys.stdin)["result"]["tools"]}
for n in ("benchbar_lock_write", "benchbar_lock_apply_plan", "benchbar_lock_apply", "benchbar_pull_plan", "benchbar_pull",
          "benchbar_profile_create", "benchbar_profile_remove_plan", "benchbar_profile_remove"):
    assert n in t, n
# a person decides these: no tool for them
for n in t:
    assert not any(w in n for w in ("profile_import", "profile_subscribe", "profile_update", "profile_export")), n
# no tool argument can reach what is a person'"'"'s
pull = set(t["benchbar_pull"]["inputSchema"]["properties"]) | set(t["benchbar_pull_plan"]["inputSchema"]["properties"])
assert not pull & {"keep_secrets", "replace", "new_backup", "before_migrate", "keep_scheduler", "confirm_site"}, pull
assert "lock" not in t["benchbar_lock_write"]["inputSchema"]["properties"], "no path for the lockfile"
assert "dir" not in t["benchbar_profile_create"]["inputSchema"]["properties"], "no folder for the profile"
# every changing tool of the bench takes a lease; every apply takes the plan token
for n in ("benchbar_lock_write", "benchbar_lock_apply", "benchbar_pull"):
    assert "lease" in t[n]["inputSchema"]["properties"], n
for n in ("benchbar_lock_apply", "benchbar_pull", "benchbar_profile_remove"):
    assert "token" in t[n]["inputSchema"]["required"], n
for n in ("benchbar_lock_apply_plan", "benchbar_pull_plan", "benchbar_profile_remove_plan"):
    assert t[n]["annotations"]["readOnlyHint"] is True, n
for n in ("benchbar_lock_write", "benchbar_lock_apply", "benchbar_pull", "benchbar_profile_create", "benchbar_profile_remove"):
    assert t[n]["annotations"]["readOnlyHint"] is False, n
assert t["benchbar_lock_apply"]["annotations"]["destructiveHint"] is True
assert t["benchbar_pull_plan"]["annotations"]["openWorldHint"] is True
' || fail "tools/list for the part 2 tools: $R"

# ---- lock write
R="$(tc benchbar_lock_write '{"bench":"'"$BENCH"'"}')"
assert_eq "False 0" "$(printf '%s' "$R" | jget - '" ".join(str(x) for x in (d["result"]["isError"], d["result"]["structuredContent"]["exit"]))')" "$R"
assert_file "$LOCK"
grep -q "^commit = \"$(app_head "$BENCH/apps/acme_crm")\"$" "$LOCK" || fail "acme_crm is pinned by the tool"
R="$(tc benchbar_lock_write '{"bench":"'"$BENCH"'","lock":"/tmp/x.toml"}')"
assert_contains "$R" "unknown argument(s)"
# a local change is refused, as the CLI refuses it
printf 'x\n' >>"$BENCH/apps/acme_crm/acme_crm/__init__.py"
R="$(tc benchbar_lock_write '{"bench":"'"$BENCH"'","no_commits":true}')"
assert_eq "True" "$(printf '%s' "$R" | err_of)" "$R"
git -C "$BENCH/apps/acme_crm" checkout -q -- .
cp "$LOCK" "$TMP_DIR/lock.good"
# a path outside the bench, from a person's earlier --lock or from BENCHBAR_LOCK, is never written by the tool
printf '# the person'"'"'s file\n' >"$TMP_DIR/outside.toml"
cp "$TMP_DIR/outside.toml" "$TMP_DIR/outside.keep"
run_fm lock write --yes --lock "$TMP_DIR/outside.toml" --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
cp "$TMP_DIR/outside.keep" "$TMP_DIR/outside.toml"
R="$(tc benchbar_lock_write '{"bench":"'"$BENCH"'","allow_dirty":true}')"
assert_eq "True" "$(printf '%s' "$R" | err_of)" "$R"
assert_contains "$R" "writes only inside the bench"
assert_eq "$(cat "$TMP_DIR/outside.keep")" "$(cat "$TMP_DIR/outside.toml")" "(the remembered outside file is untouched)"
run_fm lock write --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "(a person's own run still writes the remembered path) $OUT"
assert_contains "$(cat "$TMP_DIR/outside.toml")" "schema = 1"
printf '# the person'"'"'s file\n' >"$TMP_DIR/outside.toml"
run_fm lock write --yes --lock "$LOCK" --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
cp "$TMP_DIR/outside.keep" "$TMP_DIR/outside.toml"
R="$(BENCHBAR_LOCK="$TMP_DIR/outside.toml" tc benchbar_lock_write '{"bench":"'"$BENCH"'"}')"
assert_eq "True" "$(printf '%s' "$R" | err_of)" "$R"
assert_contains "$R" "BENCHBAR_LOCK"
assert_eq "$(cat "$TMP_DIR/outside.keep")" "$(cat "$TMP_DIR/outside.toml")" "(BENCHBAR_LOCK outside the bench is not written)"

# ---- lock apply: the CLI's own token (--dry-run --json, --apply TOKEN --yes)
fm_json lock apply --dry-run --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')" "(the apps match: nothing to apply)"
assert_eq "None" "$(printf '%s' "$OUT" | jget - 'd["token"]')"
# a newer commit on the remote, pinned: a fast forward is the plan
pinned="$(app_head "$BENCH/apps/acme_crm")"
push_commits acme_crm 2
newest="$(git -C "$REMOTES/acme_crm.git" rev-parse main)"
sed_inplace "s/^commit = \"${pinned}\"$/commit = \"${newest}\"/" "$LOCK"
lock_plan() { "$FM" lock apply --dry-run --json --bench-dir "$BENCH" 2>/dev/null; }
reset_calls
P1="$(lock_plan)"
TOK="$(doc_token "$P1")"
[[ "$TOK" =~ ^[0-9a-f]{64}$ ]] || fail "the lock apply plan has a token: $P1"
assert_eq "True commit" "$(printf '%s' "$P1" | jget - 'str(d["can_apply"]) + " " + d["steps"][0]["kind"]')" "$P1"
assert_eq "$TOK" "$(doc_token "$(lock_plan)")" "(the same plan, the same token)"
assert_calls_not_contain '^(git .*(merge|fetch|clone)|bench (setup|build))'
assert_eq "$pinned" "$(app_head "$BENCH/apps/acme_crm")" "(a plan changes nothing)"
# refusals before anything runs
run_fm lock apply --apply notatoken --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--apply needs the token of a plan"
run_fm lock apply --apply "$TOK" --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "pass its token with --apply TOKEN --yes"
run_fm lock apply --apply "$TOK" --yes --dry-run --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--apply runs the plan; --dry-run shows it"
run_fm lock apply --apply "$(printf '0%.0s' $(seq 64))" --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "lock apply plan changed since it was shown"
assert_eq "$pinned" "$(app_head "$BENCH/apps/acme_crm")" "(a stale token changes nothing)"
# the lockfile changes after the plan: its token is stale
cp "$LOCK" "$TMP_DIR/lock.newest"
sed_inplace "s/^branch = \"main\"$/branch = \"main\"/; s/^profile = \"v15-lts\"$/profile = \"v15-lts\"/" "$LOCK"
printf '# edited\n' >>"$LOCK"
run_fm lock apply --apply "$TOK" --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "plan changed since it was shown"
assert_eq "$pinned" "$(app_head "$BENCH/apps/acme_crm")" "(an edited lockfile makes the token stale)"
cp "$TMP_DIR/lock.newest" "$LOCK"

# ---- lock apply over MCP: the plan tool, a stale token refused, then the apply
R="$(tc benchbar_lock_apply_plan '{"bench":"'"$BENCH"'"}')"
assert_eq "False True" "$(printf '%s' "$R" | jget - '" ".join(str(x) for x in (d["result"]["isError"], d["result"]["structuredContent"]["can_apply"]))')" "$R"
assert_contains "$R" "Data from the bench ("
MTOK="$(printf '%s' "$R" | sc '["token"]')"
assert_eq "$TOK" "$MTOK" "(the tool's token is the CLI's)"
reset_calls
R="$(tc benchbar_lock_apply '{"bench":"'"$BENCH"'","token":"'"$(printf '0%.0s' $(seq 64))"'"}')"
assert_contains "$R" "needs a token that benchbar_lock_apply_plan returned"
assert_calls_not_contain 'merge --ff-only'
R="$(tc benchbar_lock_apply '{"bench":"'"$BENCH"'","token":"'"$MTOK"'"}')"
assert_eq "False" "$(printf '%s' "$R" | err_of)" "$R"
assert_eq "$newest" "$(app_head "$BENCH/apps/acme_crm")" "(the apply fast forwarded to the pin)"
assert_calls_contain '^bench build --app acme_crm$'
assert_calls_not_contain '^bench (new-site|update|--site .* (install-app|migrate))'
# nothing left: no token, nothing to apply
R="$(tc benchbar_lock_apply_plan '{"bench":"'"$BENCH"'"}')"
assert_eq "False None" "$(printf '%s' "$R" | jget - '" ".join(str(x) for x in (d["result"]["structuredContent"]["can_apply"], d["result"]["structuredContent"]["token"]))')" "$R"

# ---- app install and app update: the CLI's own token, directly
push_commits acme_crm 1
fm_json app update acme_crm --dry-run --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
UTOK="$(printf '%s' "$OUT" | jget - 'd["token"]')"
[[ "$UTOK" =~ ^[0-9a-f]{64}$ ]] || fail "app update --dry-run --json has a token: $OUT"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
fm_json app update acme_crm --dry-run --json --bench-dir "$BENCH"
assert_eq "$UTOK" "$(printf '%s' "$OUT" | jget - 'd["token"]')" "(the same plan, the same token)"
run_fm app update acme_crm --apply notatoken --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--apply needs the token of a plan"
run_fm app update acme_crm --apply "$UTOK" --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "pass its token with --apply TOKEN --yes"
run_fm app update acme_crm --apply "$UTOK" --yes --dry-run --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--apply runs the plan; --dry-run shows it"
# the remote moves after the plan: the token is stale, and nothing runs (the CLI fetched again itself)
push_commits acme_crm 1
reset_calls
run_fm app update acme_crm --apply "$UTOK" --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "app update plan changed since it was shown"
assert_calls_not_contain '^bench --site .* (backup|migrate)'
assert_calls_not_contain 'merge --ff-only'
fm_json app update acme_crm --dry-run --json --bench-dir "$BENCH"
UTOK="$(printf '%s' "$OUT" | jget - 'd["token"]')"
reset_calls
run_fm app update acme_crm --apply "$UTOK" --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^bench --site macdev backup$'
assert_calls_contain 'merge --ff-only --quiet [0-9a-f]{40}$'
fm_json app update acme_crm --dry-run --json --bench-dir "$BENCH"
assert_eq "False None" "$(printf '%s' "$OUT" | jget - 'str(d["can_apply"]) + " " + str(d["token"])')" "(up to date: no token)"
run_fm app update acme_crm --apply "$UTOK" --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "plan changed since it was shown" "(nothing left to do)"

make_app_remote acme_solo
add_policy acme_solo main
run_fm app add acme_solo --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
fm_json app install acme_solo --site macdev --dry-run --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
ITOK="$(printf '%s' "$OUT" | jget - 'd["token"]')"
[[ "$ITOK" =~ ^[0-9a-f]{64}$ ]] || fail "app install --dry-run --json has a token: $OUT"
assert_eq "True 2" "$(printf '%s' "$OUT" | jget - 'str(d["can_apply"]) + " " + str(len(d["steps"]))')" "(a backup and an install)"
fm_json app install acme_solo --site macdev --dry-run --json --bench-dir "$BENCH"
assert_eq "$ITOK" "$(printf '%s' "$OUT" | jget - 'd["token"]')" "(the same plan, the same token)"
fm_json app install acme_solo --site macdev --skip-backup --dry-run --json --bench-dir "$BENCH"
assert_eq "no" "$([[ "$(printf '%s' "$OUT" | jget - 'd["token"]')" == "$ITOK" ]] && printf yes || printf no)" "(skipping the backup is another plan)"
reset_calls
run_fm app install acme_solo --site macdev --apply "$(printf '0%.0s' $(seq 64))" --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "app install plan changed since it was shown"
assert_calls_not_contain 'install-app'
run_fm app install acme_solo --site macdev --apply "$ITOK" --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^bench --site macdev install-app acme_solo$'
fm_json app install acme_solo --site macdev --dry-run --json --bench-dir "$BENCH"
assert_eq "False None" "$(printf '%s' "$OUT" | jget - 'str(d["can_apply"]) + " " + str(d["token"])')" "(installed already: no token)"

# ---- profile create and remove over MCP; import, subscribe, update, export stay the person's
R="$(tc benchbar_profile_create '{"name":"mcpcopy","bench":"'"$BENCH"'"}')"
assert_eq "False 0" "$(printf '%s' "$R" | jget - '" ".join(str(x) for x in (d["result"]["isError"], d["result"]["structuredContent"]["exit"]))')" "$R"
assert_file "$HOME/.config/benchbar/profiles/mcpcopy.toml"
R="$(tc benchbar_profile_create '{"name":"mcpcopy","bench":"'"$TMP_DIR"'/nobench"}')"
assert_contains "$R" "not a bench benchbar knows"
R="$(tc benchbar_profile_create '{"name":"mcpcopy","bench":"'"$BENCH"'","dir":"/tmp"}')"
assert_contains "$R" "unknown argument(s)"
# the person imports a file; the agent removes it through a plan
sed "s#file://[^\"]*/\([A-Za-z_]*\)\.git#https://example.com/acme/\1.git#" "$HOME/.config/benchbar/profiles/mcpcopy.toml" >"$TMP_DIR/shared.toml"
run_fm profile import "$TMP_DIR/shared.toml" --as shared --yes
assert_eq "0" "$CODE" "$OUT"
assert_file "$HOME/.config/benchbar/profiles/shared.toml"
fm_json profile remove shared --dry-run --json
assert_eq "0" "$CODE" "$OUT"
PTOK="$(printf '%s' "$OUT" | jget - 'd["token"]')"
[[ "$PTOK" =~ ^[0-9a-f]{64}$ ]] || fail "profile remove --dry-run --json has a token: $OUT"
assert_file "$HOME/.config/benchbar/profiles/shared.toml" "(a plan moves nothing)"
run_fm profile remove shared --apply "$(printf '0%.0s' $(seq 64))" --yes
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "profile remove plan changed since it was shown"
assert_file "$HOME/.config/benchbar/profiles/shared.toml"
R="$(tc benchbar_profile_remove_plan '{"name":"shared"}')"
assert_eq "$PTOK" "$(printf '%s' "$R" | sc '["token"]')" "(the tool's token is the CLI's) $R"
R="$(tc benchbar_profile_remove '{"name":"shared","token":"'"$PTOK"'"}')"
assert_eq "False" "$(printf '%s' "$R" | err_of)" "$R"
assert_no_file "$HOME/.config/benchbar/profiles/shared.toml" "(moved aside)"
R="$(tc benchbar_profile_remove_plan '{"name":"mcpcopy"}')"
assert_eq "True" "$(printf '%s' "$R" | err_of)" "(your own file is not an import: nothing to plan)"
assert_file "$HOME/.config/benchbar/profiles/mcpcopy.toml"

# ---- pull: the CLI's token, and the tools on top of it
cp "$ROOT/tests/mocks/frappe-python" "$BENCH/env/bin/python"; chmod +x "$BENCH/env/bin/python"
BK="$TMP_DIR/pull-backup"; mkdir -p "$BK"
RS="erp.example.com"
mkgz "$BK/20260925_020000-erp_example_com-database.sql.gz" "INSERT INTO tabDefaultValue VALUES ('a','__default','installed_apps','[\"frappe\"]');"
mktar "$BK/20260925_020000-erp_example_com-files.tar"
mktar "$BK/20260925_020000-erp_example_com-private-files.tar"
printf '{"db_name":"_prod","db_password":"x"}' >"$BK/20260925_020000-erp_example_com-site_config_backup.json"
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
mkdir -p "$MOCK_STATE/keychain"; printf 'rootpw\n' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
# on Linux the password is a 0600 file in the state folder, and the MariaDB client is the one the apt package installs
mkdir -p "$TMP_DIR/xbin"; cp "$ROOT/tests/mocks/mariadb" "$TMP_DIR/xbin/mariadb"; chmod +x "$TMP_DIR/xbin/mariadb"
export FL_MARIADB_BIN="$TMP_DIR/xbin/mariadb"
mkdir -p "$FL_STATE_DIR/secrets"; printf 'rootpw\n' >"$FL_STATE_DIR/secrets/mariadb-root"; chmod 600 "$FL_STATE_DIR/secrets/mariadb-root"
pull_args() { printf '{"from_dir":"%s","as":"%s","bench":"%s"%s}' "$BK" "$1" "$BENCH" "${2:+,$2}"; }
R="$(tc benchbar_pull_plan "$(pull_args pulled.localhost)")"
assert_eq "False" "$(printf '%s' "$R" | err_of)" "$R"
PLTOK="$(printf '%s' "$R" | sc '["token"]')"
[[ "$PLTOK" =~ ^[0-9a-f]{64}$ ]] || fail "the pull plan has the CLI's token: $R"
assert_contains "$R" "Data from the bench ("
assert_no_file "$BENCH/sites/pulled.localhost" "(a plan creates nothing)"
# the default site is refused, in the plan and in the apply, before the CLI runs
reset_calls
R="$(tc benchbar_pull_plan "$(pull_args macdev)")"
assert_eq "True" "$(printf '%s' "$R" | err_of)" "$R"
assert_contains "$R" "default site"
R="$(tc benchbar_pull "$(pull_args macdev '"token":"'"$PLTOK"'"')")"
assert_eq "True" "$(printf '%s' "$R" | err_of)" "$R"
assert_calls_not_contain '^(bench|python benchbar-frappe|rsync|scp) '
# what an agent cannot ask for
for extra in '"keep_secrets":true' '"replace":true' '"new_backup":true' '"before_migrate":"x.sh"'; do
  R="$(tc benchbar_pull_plan "$(pull_args pulled.localhost "$extra")")"
  assert_contains "$R" "unknown argument(s)" "$extra"
done
R="$(tc benchbar_pull_plan '{"as":"pulled.localhost","source":"prod:erp.example.com","from_dir":"'"$BK"'"}')"
assert_contains "$R" "not both"
R="$(tc benchbar_pull_plan "$(pull_args pulled.localhost '"source":"--yes"')")"
assert_contains "$R" "must not start with '-'"
# the apply: a stale token first, then the plan's token
R="$(tc benchbar_pull "$(pull_args pulled.localhost '"token":"'"$(printf '0%.0s' $(seq 64))"'"')")"
assert_contains "$R" "needs a token that benchbar_pull_plan returned"
assert_no_file "$BENCH/sites/pulled.localhost"
reset_calls
R="$(tc benchbar_pull_plan "$(pull_args pulled.localhost '"skip_app":["hrms"]')")"
PLTOK="$(printf '%s' "$R" | sc '["token"]')"
R2="$(tc benchbar_pull "$(pull_args pulled.localhost '"skip_app":["hrms"],"token":"'"$PLTOK"'"')")"
assert_eq "False 0" "$(printf '%s' "$R2" | jget - '" ".join(str(x) for x in (d["result"]["isError"], d["result"]["structuredContent"]["exit"]))')" "$(printf '%s' "$R2" | jget - 'd["result"]["structuredContent"]["output"][-1500:]')"
assert_file "$BENCH/sites/pulled.localhost/site_config.json"
assert_calls_not_contain 'keep-secrets'
assert_contains "$R2" "pulled.localhost"
# the copy is neutralised: the CLI's own default, and nothing in the tool turned it off
assert_eq "True" "$(printf '%s' "$R2" | jget - 'str(d["result"]["structuredContent"]["result"].get("neutralised", {}).get("on"))')" "$R2"
