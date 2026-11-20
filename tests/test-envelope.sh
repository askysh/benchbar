#!/usr/bin/env bash
# The result envelope (docs/json-schema.md, "The result envelope") for every command of the catalogue.
# `benchbar commands --json` is the list: each command with a JSON mode runs under --for-agent, once on
# success and once on a failure, and its last stdout line must carry `exit` (the process exit code), `error`
# when it failed and, for a command that changes things, changed[], warnings[], next_actions[] and
# state_after. A command that has no JSON mode must be on NO_JSON below, with the reason: a new command
# lands in one of the two lists or this test fails, so no command can skip the envelope by being forgotten.
# shellcheck source=tests/lib/agent-contracts-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/agent-contracts-fixtures.sh"
# a second bench on its own ports (the same ports as the first would be a port conflict that stops up)
B2="$HOME/dev/second-bench"
make_fake_bench "$B2" second
cat >"$B2/sites/common_site_config.json" <<JSON
{"default_site": "second", "redis_cache": "redis://127.0.0.1:13001", "redis_queue": "redis://127.0.0.1:11001", "socketio_port": 9001, "webserver_port": 8001}
JSON
printf 'port 11001\n' >"$B2/config/redis_queue.conf"; printf 'port 13001\n' >"$B2/config/redis_cache.conf"
export BENCHBAR_LABS=lan-rooms,quick-switch
# share log reads the log with the share's node and walks its path for a folder another user could write:
# on a Mac and on a CI runner TMPDIR is the user's own, but in the bash 3.2 container it is /tmp (1777,
# root:root), which the walk calls group-writable. The group of the folder the fixtures live in is the one
# the walk may trust here, the way Homebrew's own admin group is on a Mac.
FL_SHARE_ADMIN_GROUP="$(stat -c %G "$(dirname "$TMP_DIR")" 2>/dev/null || stat -f %Sg "$(dirname "$TMP_DIR")")"
export FL_SHARE_ADMIN_GROUP
export MOCK_KICKSTART_PING=200
NOBENCH="$HOME/no-such-bench"

# the fixtures the success rows need: real git apps with a remote, a second site, a team config repo,
# a release to compare with, a server to pull from, and Open as on for the users row
export MOCK_GIT_REAL=1
REMOTES="$TMP_DIR/remotes"; mkdir -p "$REMOTES" "$TMP_DIR/x"
for a in frappe erpnext; do
  printf '%s\n' "$a" >"$BENCH/apps/$a/README"
  (cd "$BENCH/apps/$a" && git init -q -b version-15 . && git add -A && git -c user.email=t@example.com -c user.name=t commit -q -m init \
    && git clone -q --bare . "$REMOTES/$a.git" && git remote add origin "file://$REMOTES/$a.git" && git fetch -q origin && git branch -q -u origin/version-15)
done
mkdir -p "$BENCH/sites/newsite"; printf '{"db_name": "_newsite"}\n' >"$BENCH/sites/newsite/site_config.json"
mkdir -p "$TMP_DIR/team-config/profiles"
(cd "$TMP_DIR/team-config" && git init -q -b main . && printf 'base = "v15-lts"\ndescription = "Team A"\n' >profiles/team-a.toml && git add -A \
  && git -c user.email=t@example.com -c user.name=t commit -q -m profiles && git init -q --bare -b main "$REMOTES/team-config.git" \
  && git remote add origin "file://$REMOTES/team-config.git" && git push -q origin main)
printf '{"url": "https://api.github.com/repos/askysh/benchbar/releases/1", "html_url": "https://github.com/askysh/benchbar/releases/tag/v%s", "tag_name": "v%s", "draft": false}\n' "$VER" "$VER" >"$MOCK_STATE/release.json"
RS="erp.example.com"; RB="$MOCK_STATE/remote/home/frappe-bench"; BK="$RB/sites/$RS/private/backups"
mkdir -p "$BK" "$RB/env/bin"
cp "$ROOT/tests/mocks/frappe-python" "$RB/env/bin/python"; chmod +x "$RB/env/bin/python"
for a in frappe erpnext; do
  mkdir -p "$RB/apps/$a/.git"; printf 'ref: refs/heads/version-15\n' >"$RB/apps/$a/.git/HEAD"
  printf 'https://github.com/frappe/%s.git\n' "$a" >"$RB/apps/$a/.git/origin_url"
done
printf 'frappe  15.40.0 version-15\nerpnext 15.30.0 version-15\n' >"$RB/sites/$RS/installed_apps"
printf '{"db_name": "_prod", "db_password": "proddbpw"}' >"$RB/sites/$RS/site_config.json"
gzip -c </dev/null >"$BK/20260925_020000-erp_example_com-database.sql.gz"
mktar "$BK/20260925_020000-erp_example_com-files.tar"
mktar "$BK/20260925_020000-erp_example_com-private-files.tar"
cp "$RB/sites/$RS/site_config.json" "$BK/20260925_020000-erp_example_com-site_config_backup.json"
printf '{\n "db_name": "_macdev",\n "db_password": "fake-db-pw",\n "developer_mode": 1\n}\n' >"$BENCH/sites/macdev/site_config.json"
BENCHBAR_SUDO=gui run_fm site open-as on macdev --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"

# commands with no JSON mode: a terminal program, a text only helper, or a group that prints its usage
NO_JSON=" fg watch console db docs mcp help mariadb-password path site app lock profile share lan-guard ports profile-show op bench "

# key|args that succeed|args that fail ("-" for none)|exit of the success row (default 0)
# $B is the bench, $NOBENCH a folder that is no bench; @TOKEN@ is the token of `ports plan` for the bench.
# The rows run in this order, on one fixture bench: up before open and users, create before export and import.
# The last field is for a row that cannot exit 0 for an agent: a person's decision (labs on, share setup, start,
# code, invite, open-as and teardown, lan-guard remove and allow-node) is refused under --for-agent with exit 1
# (2 for labs on), and with nothing shared (a person has to start it) the commands of a room refuse with exit 1.
ROWS="
install|install --dry-run|install
run|run -- version|run -- frobnicate
notices|notices|notices --dismiss
wait|wait --timeout 0|wait --timeout soon|1
op list|op list|op list --limit 0
op status|op status|op status ../../etc/passwd
op wait|op wait op-20261119-101500-4242 --timeout 1|op wait ../../etc/passwd|1
adopt|adopt $BENCH --dry-run|adopt $NOBENCH --dry-run
service|service --dry-run|service --bench-dir $NOBENCH
doctor|doctor|doctor --bench-dir $NOBENCH
repair|repair --dry-run|repair --dry-run --bench-dir $NOBENCH
status|status|status --bench-dir $NOBENCH
list|list|-
scan|scan $HOME|scan
register|register $B2|register $NOBENCH
up|up|up --bench-dir $NOBENCH
open|open --print-url|open --bench-dir $NOBENCH
users|users|users --bench-dir $NOBENCH
restart|restart|restart --bench-dir $NOBENCH
down|down|down --bench-dir $NOBENCH
logs|logs --no-follow|logs --no-follow --bench-dir $NOBENCH
autostart|autostart on|autostart --bench-dir $NOBENCH
listen|listen local|listen bogus
uninstall-service|uninstall-service --dry-run --yes|uninstall-service --all --bench-dir $NOBENCH
pull|pull prod:erp.example.com --as copy1 --dry-run|pull
report|report --out $TMP_DIR/report|report --bogus
self-update|self-update --check|self-update --bogus
where|where|-
commands|commands|-
ports plan|ports plan -- $BENCH|ports plan -- $NOBENCH
ports setup|ports setup --dry-run -- $BENCH|ports setup -- $NOBENCH
ports apply|ports apply @TOKEN@ --yes -- $BENCH|ports apply
ports check|ports check|ports check --bench-dir $NOBENCH
ports mode|ports mode fixed|ports mode bogus
site list|site list|site list --bench-dir $NOBENCH
site add|site add s3 --dry-run|site add --bench-dir $NOBENCH
site default|site default macdev|site default nosuchsite
site open-as|site open-as status|site open-as bogus
site hosts|site hosts --yes|site hosts --bench-dir $NOBENCH
site backup|site backup macdev|site backup nosuchsite
site backups|site backups macdev|site backups nosuchsite
site snapshot|site snapshot macdev --label envelope|site snapshot nosuchsite
site snapshots|site snapshots macdev|site snapshots nosuchsite
site rollback|site rollback macdev --to latest --dry-run|site rollback --dry-run
site restore|site restore macdev --from nonexist --dry-run|site restore --dry-run
site drop|site drop newsite --confirm-site newsite --dry-run|site drop nosuchsite --confirm-site nosuchsite --dry-run
app list|app list|app list --bench-dir $NOBENCH
app add|app add frappe --dry-run|app add --dry-run
app install|app install erpnext --site macdev --yes|app install nosuchapp --site nosuchsite
app update|app update frappe --dry-run|app update nosuchapp --dry-run
app focus|app focus --list|app focus nosuchapp
app unfocus|app unfocus erpnext|app unfocus
lock write|lock write --yes --lock $TMP_DIR/benchbar.toml|lock write --bench-dir $NOBENCH
lock check|lock check --lock $TMP_DIR/benchbar.toml|lock check --bench-dir $NOBENCH
lock apply|lock apply --yes --lock $TMP_DIR/benchbar.toml|lock apply --bench-dir $NOBENCH
profile list|profile list|-
profile create|profile create envprof --from-bench $BENCH --yes|profile create envprof --from-bench $NOBENCH
profile export|profile export envprof --out $TMP_DIR/x/acme.toml --yes|profile export nosuchprofile --plan
profile import|profile import $TMP_DIR/x/acme.toml --yes|profile import $NOBENCH --plan
profile subscribe|profile subscribe file://$REMOTES/team-config.git --yes|profile subscribe
profile update|profile update --all --plan|profile update nosuchprofile --plan
profile remove|profile remove acme --yes|profile remove
profile check|profile check envprof|profile check nosuchprofile
labs|labs|labs on
labs list|labs list|-
labs on|labs on lan-rooms|labs on nosuchlab|2
labs off|labs off lan-rooms|labs off nosuchlab
labs status|labs status lan-rooms|labs status nosuchlab
lan-guard|lan-guard install --dry-run|lan-guard nosuchverb
lan-guard install|lan-guard install --dry-run|lan-guard install
lan-guard status|lan-guard status|-
lan-guard remove|lan-guard remove|lan-guard remove|1
lan-guard allow-node|lan-guard allow-node|lan-guard allow-node|1
share setup|share setup --dry-run|share setup --site nosuchsite|1
share users|share users|share users --site nosuchsite
share preflight|share preflight --static|-|1
share start|share start --dry-run|share start|1
share stop|share stop|-
share extend|share extend --by 1h|share extend|1
share status|share status|-
share code|share code|-|1
share invite|share invite|-|1
share lock|share lock|-|1
share unlock|share unlock|-|1
share people|share people|-
share devices|share devices|-
share remove|share remove d_0123abcd --yes|share remove|1
share revoke|share revoke d_0123abcd --yes|share revoke|1
share assign|share assign d_0123abcd nowhere|share assign|1
share log|share log --limit 5|-
share open-as|share open-as nobody|share open-as|1
share teardown|share teardown --yes|-|1
bench forget|bench forget $B2 --dry-run|bench forget $B2 --apply bogus --yes
bench remove|bench remove $B2 --dry-run|bench remove $B2 --apply bogus --yes
bench gc|bench gc --dry-run|bench gc --apply bogus --yes
bench scratch|bench scratch $B2 --ttl 3 --yes|bench scratch $NOBENCH --yes
db orphans|db orphans|db orphans --bogus
stats|stats|stats --bench-dir $NOBENCH
"

BENCHBAR_LABS="" run_fm commands --json
assert_eq "0" "$CODE" "$OUT"
printf '%s' "$OUT" >"$TMP_DIR/commands.json"
BENCHBAR_LABS=lan-rooms,quick-switch run_fm commands --json
printf '%s' "$OUT" >"$TMP_DIR/commands-labs.json"

# coverage: every command with a JSON mode has a row, every command without one is listed with NO_JSON
python3 -I - "$TMP_DIR/commands-labs.json" "$NO_JSON" "$ROWS" <<'PY' || fail "a command of the catalogue is on neither ROWS nor NO_JSON (tests/test-envelope.sh)"
import json, sys
cat = {c["name"]: c for c in json.load(open(sys.argv[1]))["commands"]}
no_json = set(sys.argv[2].split())
rows = {l.split("|")[0] for l in sys.argv[3].strip().split("\n")}
bad = []
for name, c in sorted(cat.items()):
    if c["json"] == "none":
        if name not in no_json and name.replace(" ", "-") not in no_json:
            bad.append("%s has no JSON mode and is not on NO_JSON" % name)
    elif name not in rows:
        bad.append("%s (%s) has no row in ROWS" % (name, c["json"]))
for r in rows:
    if r not in cat:
        bad.append("ROWS names %s, which is not in the catalogue" % r)
assert not bad, bad
PY

# check LABEL MUTATING: the last stdout line of the run in $STREAM and its exit code in $CODE
FAILS=""
check() {
  local msg rc
  set +e
  msg="$(python3 -I - "$STREAM" "$CODE" "$1" "$2" "$VER" 2>&1 <<'PY'
import json, sys
path, code, label, mutating, ver = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
lines = [l for l in open(path) if l.strip()]
assert lines, "%s: nothing on stdout (exit %d)" % (label, code)
objs = []
for l in lines:
    o = json.loads(l)
    assert isinstance(o, dict), "%s: a line that is not an object" % label
    assert o.get("schema_version") == 1 and o.get("cli_version") == ver, "%s: no schema_version and cli_version" % label
    objs.append(o)
d = objs[-1]
assert type(d.get("exit")) is int, "%s: last line has no integer exit: %r" % (label, sorted(d))
assert d["exit"] == code, "%s: exit %r is not the process exit %d" % (label, d["exit"], code)
if code != 0:
    assert isinstance(d.get("error"), str) and d["error"], "%s: failed (exit %d) without an error" % (label, code)
if mutating == "yes":
    assert d.get("event") == "done", "%s: a command that changes things ends with a done line" % label
    for k in ("changed", "warnings", "next_actions"):
        assert isinstance(d.get(k), list), "%s: %s is not a list" % (label, k)
    assert "state_after" in d, "%s: no state_after" % label
for k in ("warnings", "next_actions", "changed"):
    if k in d:
        assert isinstance(d[k], list), "%s: %s is not a list" % (label, k)
PY
)"
  rc=$?
  set -e
  # ENVELOPE_AUDIT=FILE: one line per run, for the table of a pull request: label|exit code|ok or what is wrong
  [[ -z "${ENVELOPE_AUDIT:-}" ]] || printf '%s|%s|%s\n' "$1" "$CODE" "$([[ "$rc" == "0" ]] && echo ok || echo "${msg##*AssertionError: }")" >>"$ENVELOPE_AUDIT"
  if [[ "$rc" != "0" ]]; then FAILS="${FAILS}"$'\n'"  ${msg##*AssertionError: } || stdout: $(head -c 250 "$STREAM" | tr '\n' ' ')"; fi
}

# commands whose success row changes something in this fixture: changed[] must name it
CHANGES="|register|app install|lock write|profile create|"
while IFS='|' read -r key ok_args bad_args ok_exit; do
  [[ -n "$key" ]] || continue
  # ENVELOPE_ONLY=REGEX: only the rows whose key matches, while a row is being fixed
  [[ -z "${ENVELOPE_ONLY:-}" || "$key" =~ $ENVELOPE_ONLY ]] || continue
  mutating="$(python3 -I -c 'import json,sys; print(next(c["mutating"] for c in json.load(open(sys.argv[1]))["commands"] if c["name"] == sys.argv[2]))' "$TMP_DIR/commands-labs.json" "$key")"
  mut="$([[ "$mutating" == "True" ]] && echo yes || echo no)"
  # open and users need a bench that serves (a listener on its web port); restart and later rows need the ports free again
  case "$key" in
    open) add_listener 8000 4242 python; add_listener 13000 4243 redis-server ;;
    restart) { grep -v -E "^(8000|13000) " "$MOCK_LISTEN" || true; } >"$MOCK_LISTEN.new"; mv "$MOCK_LISTEN.new" "$MOCK_LISTEN" ;;
  esac
  if [[ "$ok_args" == *@TOKEN@* ]]; then
    token="$("$FM" ports plan --json -- "$BENCH" </dev/null 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
    ok_args="${ok_args//@TOKEN@/$token}"
  fi
  # shellcheck disable=SC2086
  run_events --for-agent $ok_args
  [[ "$CODE" == "${ok_exit:-0}" ]] || FAILS="${FAILS}"$'\n'"  ${key} (success): exit ${CODE}, not ${ok_exit:-0} || stdout: $(head -c 200 "$STREAM" | tr '\n' ' ') || stderr: $(head -c 200 "$STREAM.err" | tr '\n' ' ')"
  check "$key (success)" "$mut"
  if [[ "$CHANGES" == *"|${key}|"* ]]; then
    [[ "$(python3 -I -c 'import json,sys; print(len(json.loads([l for l in open(sys.argv[1]) if l.strip()][-1])["changed"]))' "$STREAM")" -ge 1 ]] \
      || FAILS="${FAILS}"$'\n'"  ${key} (success): changed[] is empty, but the run changed something"
  fi
  if [[ "$bad_args" != "-" ]]; then
    # shellcheck disable=SC2086
    run_events --for-agent $bad_args
    [[ "$CODE" != "0" ]] || FAILS="${FAILS}"$'\n'"  ${key} (failure): exit 0, but the row must fail"
    check "$key (failure)" "$mut"
  fi
done <<<"$ROWS"
[[ -z "$FAILS" ]] || fail "commands without the envelope:$FAILS"

# ---------------------------------------------------------------- a second run changes nothing

# changed_n: how many entries the last done line has in changed[]
changed_n() { python3 -I -c 'import json,sys; print(len(json.loads([l for l in open(sys.argv[1]) if l.strip()][-1])["changed"]))' "$STREAM"; }
# again FIRST ARGS...: the command runs twice and exits 0 both times. FIRST is "changes" (the first run
# changed something, so the second run is a real "nothing to do") or "any".
again() {
  local first="$1"; shift
  run_events --for-agent "$@"
  assert_eq "0" "$CODE" "$* (first run): $(head -c 300 "$STREAM.err")"
  [[ "$first" != "changes" ]] || assert_eq "1" "$([[ "$(changed_n)" -ge 1 ]] && echo 1 || echo 0)" "$* (first run records what it changed)"
  run_events --for-agent "$@"
  assert_eq "0" "$CODE" "$* (second run): $(head -c 300 "$STREAM.err")"
  assert_eq "0" "$(changed_n)" "$* (second run: changed is empty)"
}
if [[ -z "${ENVELOPE_ONLY:-}" ]]; then
  again changes autostart off
  again any listen local
  again changes ports mode automatic --bench-dir "$BENCH"
  again any ports mode fixed --bench-dir "$BENCH"
  again any register "$B2"
  again any app install erpnext --site macdev --yes
fi

# ---------------------------------------------------------------- the other output modes

# --jsonl on a read, --jsonl on a changer and plain --json on a changer end with the envelope too
if [[ -z "${ENVELOPE_ONLY:-}" ]]; then
  run_events --jsonl list
  check "list (--jsonl read)" no
  run_events --jsonl site default macdev
  check "site default (--jsonl changer)" yes
  run_events --json site default macdev
  check "site default (--json changer)" yes
  run_events --jsonl site default nosuchsite
  check "site default (--jsonl failure)" yes
  [[ -z "$FAILS" ]] || fail "output modes without the envelope:$FAILS"
  # the first uninstall removes the service of the bench: the last run, nothing uses the bench after it
  again changes uninstall-service --yes --bench-dir "$BENCH"
fi

# ---------------------------------------------------------------- the MCP server: the same fields in structuredContent

INIT='{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}'
mcp_tool() { printf '%s\n' "$INIT" '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"'"$1"'","arguments":'"$2"'}}' | "$FM" mcp 2>/dev/null | tail -n +2; }
# a read: the document with exit
R="$(mcp_tool benchbar_status '{"bench":"'"$BENCH"'"}')"
assert_eq "0 True" "$(printf '%s' "$R" | jget - '"%s %s" % (d["result"]["structuredContent"]["exit"], d["result"]["isError"] is False)')" "(a read result has exit)"
R="$(mcp_tool benchbar_site_list '{"bench":"'"$BENCH"'"}')"
assert_eq "0" "$(printf '%s' "$R" | jget - 'd["result"]["structuredContent"]["exit"]')" "(site list)"
# a read that fails: isError, with exit and error as structuredContent
R="$(mcp_tool benchbar_status '{"bench":"'"$NOBENCH"'"}')"
assert_eq "True 1 True" "$(printf '%s' "$R" | jget - '"%s %s %s" % (d["result"]["isError"], d["result"]["structuredContent"]["exit"], bool(d["result"]["structuredContent"]["error"]))')" "(a failed read has exit and error)"
# an action: exit at the top, and the done line's changed, warnings and next_actions beside result
R="$(mcp_tool benchbar_down '{"bench":"'"$BENCH"'"}')"
assert_eq "0 True True True" "$(printf '%s' "$R" | jget - '" ".join(str(x) for x in (d["result"]["structuredContent"]["exit"], isinstance(d["result"]["structuredContent"]["changed"], list), isinstance(d["result"]["structuredContent"]["warnings"], list), isinstance(d["result"]["structuredContent"]["next_actions"], list)))')" "(an action result has the envelope)"
assert_eq "0" "$(printf '%s' "$R" | jget - 'd["result"]["structuredContent"]["exit_code"]')" "(exit_code stays)"
