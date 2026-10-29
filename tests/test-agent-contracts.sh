#!/usr/bin/env bash
# The agent contracts (0.9): per command help and `commands --json`, one done
# line for every change, the non interactive mode, the honest state fields,
# doctor --ack and --quick, and logs with time. The Mac app's fixtures still
# decode: nothing is renamed or removed, fields are only added.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=tests/lib/install-stream.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/install-stream.sh"

BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" macdev
printf 'port 11000\n' >"$BENCH/config/redis_queue.conf"; printf 'port 13000\n' >"$BENCH/config/redis_cache.conf"
printf '127.0.0.1 macdev\n' >>"$FL_HOSTS_FILE"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
export MARIADB_ROOT_PASSWORD=rootpw
# the launchctl mock starts honcho; its working folder is this bench's
mkdir -p "$MOCK_STATE/cwd"; printf '%s' "$BENCH" >"$MOCK_STATE/cwd/4242"

# lines(): how many lines the last stream has; done_count(): its done lines
done_count() { sx 'len([x for x in e if x["event"] == "done"])'; }

# ---------------------------------------------------------------- 1. help and commands --json

run_fm commands --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "1" "$(printf '%s' "$OUT" | jget - 'd["schema_version"]')"
assert_eq "$VER" "$(printf '%s' "$OUT" | jget - 'd["cli_version"]')"
printf '%s' "$OUT" >"$TMP_DIR/commands.json"

# every label of every dispatcher has an entry in the table: the labels of the
# last `case` of benchbar's dispatch and of fl_cmd_site, _app, _profile, _lock
# and _ports are parsed from the source, so a new label without an entry fails here
python3 -I - "$ROOT" "$TMP_DIR/commands.json" <<'PY' || fail "a dispatcher label has no entry in the commands table (lib/frappe-local/commands.sh)"
import json, re, sys
root, table_file = sys.argv[1], sys.argv[2]
table = {c["name"] for c in json.load(open(table_file))["commands"]}

def labels_of(path, func, prefix):
    src = open(root + "/" + path).read().split("\n")
    if func:
        start = next(i for i, l in enumerate(src) if l.startswith(func + "() {"))
        end = next(i for i in range(start, len(src)) if src[i] == "}")
        cases = [i for i in range(start, end) if re.match(r'^  case "\$\w+" in$', src[i])]
        first, indent = cases[-1], 4
    else:
        cases = [i for i, l in enumerate(src) if l == 'case "$COMMAND" in']
        first, indent = cases[-1], 2
    out = []
    for line in src[first + 1:]:
        if line.startswith(" " * (indent - 2) + "esac"):
            break
        m = re.match(r'^' + " " * indent + r'([^\s#][^)]*)\)', line)
        if not m:
            continue
        for lab in m.group(1).split("|"):
            lab = lab.strip().strip('"')
            if lab and lab != "*":
                out.append(prefix + lab)
    return out

labels = []
labels += labels_of("benchbar", None, "")
labels += labels_of("lib/frappe-local/sites.sh", "fl_cmd_site", "site ")
labels += labels_of("lib/frappe-local/apps.sh", "fl_cmd_app", "app ")
labels += labels_of("lib/frappe-local/profiles.sh", "fl_cmd_profile", "profile ")
labels += labels_of("lib/frappe-local/teamlock.sh", "fl_cmd_lock", "lock ")
labels += labels_of("lib/frappe-local/port-management.sh", "fl_cmd_ports", "ports ")
assert len(labels) > 45, ("the label parser found too little", labels)
missing = sorted(l for l in labels if l not in table)
assert not missing, ("no table entry for", missing)
PY

# one entry per command, with the fields an agent plans with
assert_eq "True" "$(jget "$TMP_DIR/commands.json" 'all(set(("name", "usage", "summary", "tty", "sudo", "network", "mutating", "json", "flags", "env")) <= set(c) for c in d["commands"])')"
assert_eq "stream True True" "$(jget "$TMP_DIR/commands.json" '" ".join(str(x) for x in next((c["json"], c["sudo"], c["mutating"]) for c in d["commands"] if c["name"] == "install"))')"
assert_eq "document False False" "$(jget "$TMP_DIR/commands.json" '" ".join(str(x) for x in next((c["json"], c["mutating"], c["tty"]) for c in d["commands"] if c["name"] == "status"))')"
assert_eq "--ping" "$(jget "$TMP_DIR/commands.json" 'next(c["flags"][0]["name"] for c in d["commands"] if c["name"] == "status")')"

# X --help prints X's entry; the global --help stays the global text
run_fm install --help
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "benchbar install:"
assert_contains "$OUT" "ADMIN_PASSWORD"
assert_not_contains "$OUT" "Shell helpers"
run_fm site backup --help
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "benchbar site backup:"
assert_contains "$OUT" "--with-files"
run_fm site --help
assert_contains "$OUT" "benchbar site:"
run_fm --help
assert_contains "$OUT" "Shell helpers"
assert_contains "$OUT" "Setup"
# help never takes the lock, never touches a bench, never writes
reset_calls
snap="$(snapshot "$HOME" "$BENCH" "$FL_STATE_DIR")"
run_fm doctor --help
assert_eq "0" "$CODE" "$OUT"
run_fm logs --help
run_fm site drop --help --bench-dir "$BENCH"
assert_eq "$snap" "$(snapshot "$HOME" "$BENCH" "$FL_STATE_DIR")" "(help writes nothing, takes no lock)"
assert_eq "" "$(cat "$MOCK_LOG")" "(help calls no tool)"
run_fm docs --help
assert_contains "$OUT" "install"

# ---------------------------------------------------------------- 2. JSON only, and one done for every change

# donefields: the fields of every done (docs/json-schema.md, "Rules for readers")
# are there, with the types a reader relies on
DONE_OK='(lambda d: d["event"] == "done" and isinstance(d["exit"], int) and isinstance(d["changed"], list) and isinstance(d["warnings"], list) and isinstance(d["next_actions"], list) and ("state_after" in d))(e[-1])'

export MOCK_KICKSTART_PING=200
# up: the stream is JSON lines only (sx fails on any other line), ends with one done whose exit is the exit code
stream up --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "True" "$(sx "$DONE_OK")"
assert_eq "1" "$(done_count)"
assert_eq "0" "$(sx 'e[-1]["exit"]')"
assert_eq "start_service:done wait_site:done" "$(sx '" ".join("%s:%s" % (x["id"], x["status"]) for x in e if x["event"] == "step" and x["status"] == "done")')"
assert_eq "process" "$(sx 'e[-1]["changed"][0]["kind"]')"
assert_eq "running" "$(sx 'e[-1]["state_after"]["state"]')"
assert_contains "$(cat "$STREAM.err")" "bench is up"
# already running: a no-op, still one done, nothing changed
stream up --json --bench-dir "$BENCH"
assert_eq "0" "$CODE"
assert_eq "[]" "$(sx 'e[-1]["changed"]')"
assert_eq "1" "$(done_count)"
# restart
stream restart --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "restart_service:done wait_site:done" "$(sx '" ".join("%s:%s" % (x["id"], x["status"]) for x in e if x["event"] == "step" and x["status"] == "done")')"
assert_eq "restarted" "$(sx 'e[-1]["changed"][0]["detail"]')"
# down
stream down --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "stopped" "$(sx 'e[-1]["state_after"]["state"]')"
assert_eq "stopped" "$(sx 'e[-1]["changed"][0]["detail"]')"
# a start that does not answer: exit 1 in the done line and in the process, the warning and the next action
unset MOCK_KICKSTART_PING
stream up --json --bench-dir "$BENCH"
assert_eq "1" "$CODE"
assert_eq "1" "$(sx 'e[-1]["exit"]')"
assert_contains "$(sx 'e[-1]["warnings"][0]')" "no 200"
assert_contains "$(sx 'e[-1]["next_actions"][0]["command"]')" "logs"
assert_eq "1" "$(done_count)"
export MOCK_KICKSTART_PING=200
stream down --json --bench-dir "$BENCH"

# --jsonl is the same stream; --for-agent asks a mutating command for it
stream down --jsonl --bench-dir "$BENCH"
assert_eq "0" "$CODE"; assert_eq "True" "$(sx "$DONE_OK")"
stream up --for-agent --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"; assert_eq "True" "$(sx "$DONE_OK")"
assert_not_contains "$(cat "$STREAM.err")" $'\033' "(--for-agent is plain text)"
stream down --json --bench-dir "$BENCH"

# a dry run: the plan line and the done line, nothing else, nothing changed
for c in up down restart service; do
  snap="$(snapshot "$BENCH" "$FL_STATE_DIR")"; reset_calls
  stream "$c" --dry-run --json --yes --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$c: $(cat "$STREAM.err")"
  assert_eq "plan done" "$(sx '" ".join(x["event"] for x in e)')" "$c"
  assert_eq "True" "$(sx 'e[-1]["dry_run"] if "dry_run" in e[-1] else e[0].get("dry_run", True)')" "$c"
  assert_eq "[]" "$(sx 'e[-1]["changed"]')" "$c"
  assert_calls_not_contain '^launchctl (kickstart|bootout|bootstrap)' "$c"
done

# service on a second bench: the plan, one step per action with ids, the changes
B2="$HOME/dev/second-bench"
make_fake_bench "$B2" second
printf 'port 11001\n' >"$B2/config/redis_queue.conf"; printf 'port 13001\n' >"$B2/config/redis_cache.conf"
stream service --json --yes --bench-dir "$B2"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "plan" "$(sx 'e[0]["event"]')"
assert_eq "1" "$(done_count)"
assert_eq "True" "$(sx 'len([x for x in e[-1]["changed"] if x["kind"] in ("service", "ports", "hosts")]) > 0')"
assert_eq "True" "$(sx 'all(x["id"] for x in e if x["event"] == "step")')"

# site add: the stream, the default stays, the result fields are in the done
stream site add newsite --json --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE"
assert_contains "$(sx 'e[-1]["error"]')" "Administrator password"
ADMIN_PASSWORD=adminpw stream site add newsite --json --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "newsite macdev True" "$(sx '" ".join(str(e[-1][k]) for k in ("site", "default_site", "created"))')"
assert_eq "site" "$(sx 'e[-1]["changed"][0]["kind"]')"
assert_eq "macdev" "$(tr -d '[:space:]' <"$BENCH/sites/currentsite.txt")"
assert_not_contains "$(cat "$STREAM")" "adminpw"
# again: unchanged
ADMIN_PASSWORD=adminpw stream site add newsite --json --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE"; assert_eq "False" "$(sx 'e[-1]["created"]')"; assert_eq "[]" "$(sx 'e[-1]["changed"]')"
# site default
stream site default newsite --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "newsite" "$(sx 'e[-1]["default_site"]')"
assert_eq "newsite" "$(sx 'e[-1]["state_after"]["site"]')"
stream site default macdev --json --bench-dir "$BENCH"
assert_eq "macdev" "$(sx 'e[-1]["default_site"]')"

# site list says which site is the default
run_fm site list --json --bench-dir "$BENCH"
assert_eq "macdev" "$(printf '%s' "$OUT" | jget - 'd["default_site"]')"

# site backup and site drop: ONE document with --json (what the Mac app decodes), the done fields added
run_json() { set +e; OUT="$("$FM" "$@" 2>"$MOCK_STATE/stderr" </dev/null)"; CODE="$?"; ERR="$(cat "$MOCK_STATE/stderr")"; set -e; }
run_json site backup newsite --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$ERR"
assert_eq "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "(a document is one line)"
assert_eq "0 backup newsite" "$(printf '%s' "$OUT" | jget - '" ".join([str(d["exit"]), d["changed"][0]["kind"], d["changed"][0]["name"]])')"
assert_eq "True" "$(printf '%s' "$OUT" | jget - '"backup" in d and "warnings" in d and "next_actions" in d and "state_after" in d and "event" not in d')"
run_json site backup newsite --dry-run --json --bench-dir "$BENCH"
assert_eq "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["dry_run"] and "exit" not in d')" "(a plan document stays as it was)"
# the same under --jsonl: the stream, the document's fields in the done line
stream site backup newsite --jsonl --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "done" "$(sx '" ".join(x["event"] for x in e)')"
assert_eq "True" "$(sx "$DONE_OK and e[-1][\"backup\"][\"size_bytes\"] > 0")"
stream site backup newsite --dry-run --jsonl --bench-dir "$BENCH"
assert_eq "plan done" "$(sx '" ".join(x["event"] for x in e)')"
# drop: the document, then the stream
mkdir -p "$BENCH/sites/dropme"; printf '{}\n' >"$BENCH/sites/dropme/site_config.json"
printf '# >>> benchbar >>>\n127.0.0.1 dropme\n# <<< benchbar <<<\n' >>"$FL_HOSTS_FILE"
run_json site drop dropme --confirm-site dropme --dry-run --json --bench-dir "$BENCH"
assert_eq "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
assert_eq "macdev" "$(printf '%s' "$OUT" | jget - 'd["default_site"]')"
stream site drop dropme --confirm-site dropme --dry-run --jsonl --bench-dir "$BENCH"
assert_eq "plan done" "$(sx '" ".join(x["event"] for x in e)')"
stream site drop dropme --confirm-site dropme --jsonl --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "True" "$(sx "$DONE_OK and e[-1][\"dropped\"] and e[-1][\"default_site\"] == \"macdev\"")"
assert_eq "hosts site" "$(sx '" ".join(sorted(set(x["kind"] for x in e[-1]["changed"] if x["kind"] in ("site", "hosts"))))')"

# repair --json: the engine's events, one done with exit and exit_code (the same number), the shared fields
run_events() {
  set +e
  "$FM" "$@" >"$STREAM" 2>"$STREAM.err" </dev/null
  CODE=$?
  set -e
}
ev() { python3 -I -c '
import json, sys
e = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(eval(sys.argv[2]))' "$STREAM" "$1"; }
run_events repair --json --dry-run --bench-dir "$B2"
assert_eq "0" "$CODE"; assert_eq "plan" "$(ev '" ".join(x["event"] for x in e)')" "(a repair dry run is the plan alone)"
run_events repair --json --yes --bench-dir "$B2"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "True" "$(ev 'e[-1]["event"] == "done" and e[-1]["exit"] == e[-1]["exit_code"] == 0 and "changed" in e[-1] and "state_after" in e[-1] and "next_actions" in e[-1]')"
assert_eq "1" "$(ev 'len([x for x in e if x["event"] == "done"])')"

# the apps: add --apply and update, as a document and as a stream
# shellcheck source=tests/lib/apps-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apps-fixtures.sh"
APPB="$HOME/app-bench"
make_fake_bench "$APPB" appsite
printf 'frappe\n' >"$APPB/sites/apps.txt"; rmdir "$APPB/apps/erpnext"
printf 'frappe 15.0.0\n' >"$APPB/sites/appsite/installed_apps"
make_app_remote acme_crm
add_policy acme_crm main
run_json app add acme_crm --site appsite --dry-run --json --bench-dir "$APPB"
assert_eq "0" "$CODE" "$ERR"
assert_eq "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
stream app add acme_crm --site appsite --dry-run --jsonl --bench-dir "$APPB"
assert_eq "plan done" "$(sx '" ".join(x["event"] for x in e)')"
run_json app add acme_crm --site appsite --apply "$TOKEN" --yes --json --bench-dir "$APPB"
assert_eq "0" "$CODE" "$ERR"
assert_eq "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "(the document the Mac app decodes is one line)"
assert_eq "True 0 app" "$(printf '%s' "$OUT" | jget - '" ".join([str(d["ok"]), str(d["exit"]), d["changed"][0]["kind"]])')"
# update: a dry run as a document and as a stream, then the real stream
push_commits acme_crm 2
run_json app update acme_crm --dry-run --json --bench-dir "$APPB"
assert_eq "0" "$CODE" "$ERR"
assert_eq "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
assert_eq "2" "$(printf '%s' "$OUT" | jget - 'd["commits_total"]')"
stream app update acme_crm --dry-run --jsonl --bench-dir "$APPB"
assert_eq "plan done" "$(sx '" ".join(x["event"] for x in e)')"
assert_eq "2" "$(sx 'e[0]["commits_total"]')"
stream app update acme_crm --json --yes --bench-dir "$APPB"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "plan" "$(sx 'e[0]["event"]')"; assert_eq "1" "$(done_count)"
assert_eq "True" "$(sx "$DONE_OK and e[-1][\"updated\"] and any(x[\"kind\"] == \"app\" for x in e[-1][\"changed\"])")"
assert_eq "True" "$(sx 'all(x["id"] for x in e if x["event"] == "step")')"

# ---------------------------------------------------------------- 3. the non interactive mode

# refused before the lock, the log and any bench call; every missing input in ONE error
logs_now() { find "$FL_STATE_DIR/logs" -type f 2>/dev/null | wc -l | tr -d ' '; }
noni() { BENCHBAR_NONINTERACTIVE=1 run_fm "$@"; }
rm -rf "$MOCK_STATE/keychain"
unset MARIADB_ROOT_PASSWORD
n_logs="$(logs_now)"; reset_calls
noni site add noniuser --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "missing:"
assert_contains "$OUT" "ADMIN_PASSWORD"
assert_contains "$OUT" "MARIADB_ROOT_PASSWORD"
assert_contains "$OUT" "--yes"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c 'Cannot start, missing')" "(one error names them all)"
assert_calls_not_contain '^bench ' "(no bench call)"
assert_no_file "$FL_STATE_DIR/lock" "(no lock)"
assert_no_file "$BENCH/.benchbar.lock" "(no bench lock)"
assert_eq "$n_logs" "$(logs_now)" "(no log written)"
assert_no_file "$BENCH/sites/noniuser"
# sudo that would ask is named too (a Mac hosts line needs it)
rm -f "$MOCK_STATE/sudo_cred"
noni site add noniuser --bench-dir "$BENCH"
assert_contains "$OUT" "sudo"
touch "$MOCK_STATE/sudo_cred"
# the secret's source is never said: the message does not tell where the password lives
assert_not_contains "$OUT" "Keychain"
# --yes and the secrets: it goes through (the mode only refuses what cannot be answered)
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
BENCHBAR_NONINTERACTIVE=1 ADMIN_PASSWORD=adminpw MARIADB_ROOT_PASSWORD=rootpw run_fm site add noniuser --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_file "$BENCH/sites/noniuser"
# a stored password counts as known (benchbar's own store)
mkdir -p "$MOCK_STATE/keychain"; printf 'rootpw' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
BENCHBAR_NONINTERACTIVE=1 ADMIN_PASSWORD=adminpw run_fm site add noniuser2 --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
rm -rf "$MOCK_STATE/keychain"
# site drop: the password
mkdir -p "$BENCH/sites/dropme2"; printf '{}\n' >"$BENCH/sites/dropme2/site_config.json"
reset_calls; n_logs="$(logs_now)"
noni site drop dropme2 --confirm-site dropme2 --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "MARIADB_ROOT_PASSWORD"
assert_calls_not_contain '^bench '; assert_no_file "$FL_STATE_DIR/lock"; assert_eq "$n_logs" "$(logs_now)"
assert_file "$BENCH/sites/dropme2"
# install: --yes, the Administrator password and a sudo that would ask, all in one
NEWB="$HOME/noni-bench"
stream_machine
rm -f "$MOCK_STATE/sudo_cred"
reset_calls; n_logs="$(logs_now)"
noni install --bench-dir "$NEWB" --site noni.localhost
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "--yes"; assert_contains "$OUT" "ADMIN_PASSWORD"; assert_contains "$OUT" "sudo"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c 'Cannot start, missing')"
assert_calls_not_contain '^(bench|brew install|brew services|launchctl)'
assert_no_file "$FL_STATE_DIR/lock"; assert_eq "$n_logs" "$(logs_now)"; assert_no_file "$NEWB"
touch "$MOCK_STATE/sudo_cred"
# uninstall-service: no terminal and no --yes is refused in any mode, naming --yes
run_fm uninstall-service --bench-dir "$BENCH" </dev/null
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--yes"
assert_file "$BENCH/benchbar-run.sh"
noni uninstall-service --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--yes"
assert_file "$BENCH/Procfile.lean"
# fl_confirm under the mode names --yes instead of reading no
mkdir -p "$MOCK_STATE/keychain"; printf 'rootpw' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
noni mariadb-password --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--yes"
assert_not_contains "$OUT" "rootpw"
rm -rf "$MOCK_STATE/keychain"
# the flag sets the mode: --for-agent
run_fm site add noniuser3 --for-agent --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "ADMIN_PASSWORD"

printf 'test-agent-contracts: ok\n'
