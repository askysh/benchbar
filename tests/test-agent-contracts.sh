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
# the apply as a stream: every step line has an id, KIND_TARGET as app update's
make_app_remote acme_two
add_policy acme_two main
run_json app add acme_two --site appsite --dry-run --json --bench-dir "$APPB"
TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
stream app add acme_two --site appsite --apply "$TOKEN" --yes --jsonl --bench-dir "$APPB"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "1" "$(done_count)"
assert_eq "True" "$(sx 'all(x.get("id") for x in e if x["event"] == "step") and any(x["event"] == "step" for x in e)')"
assert_eq "True" "$(sx 'any(x.get("id") == "install_appsite" for x in e if x["event"] == "step")')"
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
assert_eq "2" "$CODE" "$OUT" "(exit 2: the MariaDB root password is among the missing)"
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
assert_eq "2" "$CODE" "$OUT"; assert_contains "$OUT" "MARIADB_ROOT_PASSWORD"
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
assert_eq "2" "$CODE"; assert_contains "$OUT" "ADMIN_PASSWORD"

# ---------------------------------------------------------------- 4. honest state fields

# bench_bin: the bench the service runs, from the PATH its agent bakes in; null when there is none
run_fm status --json --bench-dir "$BENCH"
assert_eq "None" "$(printf '%s' "$OUT" | jget - 'd["bench_bin"]')"
printf '#!/bin/sh\nexit 0\n' >"$HOME/.local/bin/bench"; chmod +x "$HOME/.local/bin/bench"
reset_calls
run_fm status --json --bench-dir "$BENCH"
assert_eq "$HOME/.local/bin/bench" "$(printf '%s' "$OUT" | jget - 'd["bench_bin"]')"
# it costs the status path no process (launchctl is the one the state already needs)
assert_calls_not_contain '^(bench|which|command) ' "(bench_bin starts nothing)"
rm -f "$HOME/.local/bin/bench"
# the same state_after of a done carries it
printf '#!/bin/sh\nexit 0\n' >"$HOME/.local/bin/bench"; chmod +x "$HOME/.local/bin/bench"
stream down --json --bench-dir "$BENCH"
assert_eq "$HOME/.local/bin/bench" "$(sx 'e[-1]["state_after"]["bench_bin"]')"
rm -f "$HOME/.local/bin/bench"

# not_adopted: a folder that is a bench, with no service of benchbar's and not remembered
NA="$HOME/elsewhere/na-bench"
make_fake_bench "$NA" na-site
mkdir -p "$HOME/elsewhere/empty-bench/sites" "$HOME/elsewhere/empty-bench/apps/frappe"
printf '{}\n' >"$HOME/elsewhere/empty-bench/sites/common_site_config.json"
run_fm status --json --bench-dir "$NA"
assert_eq "0" "$CODE" "$OUT"
assert_eq "not_adopted None None" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in (d["state"], d["site"], d["web_url"]))')"
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'any(s["default"] for s in d["sites"])')" "(no site of this bench is marked default)"
assert_not_contains "$OUT" "macdev" "(the default bench's site never leaks into another bench's status)"
run_fm status --json --bench-dir "$HOME/elsewhere/empty-bench"
assert_eq "not_adopted None" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in (d["state"], d["site"]))')"
assert_not_contains "$OUT" "macdev"
run_fm status --bench-dir "$NA"
assert_contains "$OUT" "does not manage this bench yet"
# remembered (register), or with a service of its own: no longer not_adopted
run_fm register "$NA"
run_fm status --json --bench-dir "$NA"
assert_eq "stopped na-site" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in (d["state"], d["site"]))')"
# the default bench and a bench with a service are never not_adopted
run_fm status --json --bench-dir "$BENCH"
assert_eq "stopped" "$(printf '%s' "$OUT" | jget - 'd["state"]')"
# list --json still lists it, and it costs the same
run_fm list --json
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'any(b["path"] == "'"$NA"'" for b in d["benches"])')"

# the ping rules: status --ping asks every site only while the bench runs; a stopped bench starts nothing and asks nothing
reset_calls
stream down --json --bench-dir "$BENCH"
reset_calls
run_fm status --json --ping --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^curl ' "(a stopped bench is not pinged, site by site)"
assert_calls_not_contain '^launchctl (kickstart|bootstrap)' "(status never starts)"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'all(s["ping_code"] is None for s in d["sites"])')"
reset_calls
run_fm list --json
assert_calls_not_contain '^curl ' "(list never pings, at rest or running)"
add_proc 4242 "honcho start -f Procfile.lean" "$BENCH"
export MOCK_CURL_CODE=200
reset_calls
run_fm status --json --ping --bench-dir "$BENCH"
assert_eq "200" "$(printf '%s' "$OUT" | jget - '[s["ping_code"] for s in d["sites"] if s["default"]][0]')"
assert_calls_contain '^curl ' "(a running bench is pinged)"
reset_calls
run_fm list --json
assert_calls_not_contain '^curl ' "(list never pings)"
: >"$MOCK_PROCS"; unset MOCK_CURL_CODE

# ---------------------------------------------------------------- 5. doctor --ack, --quick and the lock's owner

mkdir -p "$HOME/Applications/CleanMyMac X.app"
dj() { run_json doctor --json --bench-dir "$BENCH"; }
dj
assert_eq "warn False []" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in ([c for c in d["checks"] if c["id"] == "cleanmymac"][0]["level"], [c for c in d["checks"] if c["id"] == "cleanmymac"][0]["acked"], d["acked"]))')"
WARNS_BEFORE="$(printf '%s' "$OUT" | jget - 'd["summary"]["warn"]')"
# ack: recorded, with the message it acknowledged
run_fm doctor --ack cleanmymac --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "acknowledged cleanmymac"
dj
assert_eq "warn True cleanmymac" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in ([c for c in d["checks"] if c["id"] == "cleanmymac"][0]["level"], [c for c in d["checks"] if c["id"] == "cleanmymac"][0]["acked"], ",".join(d["acked"])))')"
assert_eq "$WARNS_BEFORE" "$(printf '%s' "$OUT" | jget - 'd["summary"]["warn"]')" "(the check is kept at level warn)"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "acked: CleanMyMac"
assert_not_contains "$OUT" "[WARN] CleanMyMac"
run_fm doctor --fix-hints --bench-dir "$BENCH"
assert_not_contains "$OUT" "Ignore List" "(--fix-hints leaves an acked warning out)"
# ack is per bench
run_json doctor --json --bench-dir "$B2"
assert_eq "False" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "cleanmymac"][0]["acked"]')"
# the message changes: the ack lapses
mv "$HOME/Applications/CleanMyMac X.app" "$HOME/Applications/CleanMyMac Pro.app"
dj
assert_eq "False" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "cleanmymac"][0]["acked"]')"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] CleanMyMac"
# unack, twice
run_fm doctor --unack cleanmymac --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "no longer acknowledged"
run_fm doctor --unack cleanmymac --bench-dir "$BENCH"
assert_contains "$OUT" "was not acknowledged"
# a FAIL cannot be acked; an unknown id and an ok check say so
mv "$BENCH/env/bin/python" "$BENCH/env/bin/python.x"
run_fm doctor --ack env_python --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "cannot be acknowledged"
mv "$BENCH/env/bin/python.x" "$BENCH/env/bin/python"
run_fm doctor --ack nosuchcheck --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "No check named"
run_fm doctor --ack honcho --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "nothing to acknowledge"
rm -rf "$HOME/Applications/CleanMyMac Pro.app"

# --quick: the slow checks are left out and named
export MOCK_CURL_CODE=200
reset_calls
run_json doctor --json --quick --bench-dir "$BENCH"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["quick"] and "ping" in d["skipped_checks"] and "bench_version" in d["skipped_checks"] and not any(c["id"] in d["skipped_checks"] for c in d["checks"])')"
assert_calls_not_contain '^curl ' "(the site ping is a slow check)"
dj
assert_eq "False []" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in (d["quick"], d["skipped_checks"]))')"
run_fm doctor --quick --bench-dir "$BENCH"
assert_contains "$OUT" "quick: skipped the slow checks:"
unset MOCK_CURL_CODE

# the lock: "Reclaiming stale lock left by pid N" says what held it and since when
(
  set +e
  # shellcheck source=lib/frappe-local/ui.sh
  . "$ROOT/lib/frappe-local/ui.sh"
  # shellcheck source=lib/frappe-local/lock.sh
  . "$ROOT/lib/frappe-local/lock.sh"
  COMMAND=site; ARGS=(add x)
  fl_lock_acquire "$TMP_DIR/lockinfo" >/dev/null 2>&1
  printf '%s' "$(cat "$TMP_DIR/lockinfo/info")" >"$TMP_DIR/lockinfo.txt"
  fl_lock_release
)
assert_contains "$(cat "$TMP_DIR/lockinfo.txt")" "site add"
assert_not_contains "$(cat "$TMP_DIR/lockinfo.txt")" " x" "(the subcommand only, never an argument)"
mkdir -p "$FL_STATE_DIR/lock"; printf '999999\n' >"$FL_STATE_DIR/lock/pid"
printf 'site add\t2026-10-29T10:00:00Z\n' >"$FL_STATE_DIR/lock/info"
run_fm service --yes --bench-dir "$B2"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "Reclaiming stale lock left by pid 999999 (benchbar site add, started 2026-10-29T10:00:00Z)"

# ---------------------------------------------------------------- 6. logs with time

LB="$HOME/log-bench"
make_fake_bench "$LB" logsite
cat >"$LB/logs/bench.log" <<'LOG'
23:59:58 system | web.1 started (pid=11)
23:59:59 web.1        | * Running on http://127.0.0.1:8000
00:00:02 worker.1     | job done
00:00:03 web.1        | Traceback (most recent call last):
  File "x.py", line 1, in <module>
00:00:04 socketio.1   | listening on 9000
LOG
# the file's time: 2026-10-29 00:00:10 UTC, so the first two lines are from the day before
TZ=UTC touch -t 202610290000.10 "$LB/logs/bench.log"
tlogs() { TZ=UTC run_json logs --json --no-follow --bench-dir "$LB" "$@"; }
tlogs
assert_eq "0" "$CODE" "$ERR"
assert_eq "2026-10-29T00:00:10Z" "$(printf '%s' "$OUT" | jget - 'd["mtime"]')"
assert_eq "[None, None]" "$(printf '%s' "$OUT" | jget - '[d["since"], d.get("truncated_to")]')"
assert_eq "6 6" "$(printf '%s' "$OUT" | jget - '"%d %d" % (len(d["lines"]), len(d["ts"]))')" "(one ts per line)"
assert_eq "['2026-10-28T23:59:58Z', '2026-10-28T23:59:59Z', '2026-10-29T00:00:02Z', '2026-10-29T00:00:03Z', None, '2026-10-29T00:00:04Z']" "$(printf '%s' "$OUT" | jget - 'd["ts"]')" "(a line without a time has none, and inherits none)"
# --since: at or after, the untimed line under a kept line stays
tlogs --since 2026-10-29T00:00:03Z
assert_eq "['00:00:03 web.1        | Traceback (most recent call last):', '  File \"x.py\", line 1, in <module>', '00:00:04 socketio.1   | listening on 9000'] 2026-10-29T00:00:03Z" "$(printf '%s' "$OUT" | jget - 'str(d["lines"]) + " " + d["since"]')"
assert_eq "['2026-10-29T00:00:03Z', None, '2026-10-29T00:00:04Z']" "$(printf '%s' "$OUT" | jget - 'd["ts"]')"
tlogs --since 2026-10-29T00:00:05Z
assert_eq "[] []" "$(printf '%s' "$OUT" | jget - 'str(d["lines"]) + " " + str(d["ts"])')"
# local time without a zone; a zone; a date; the last lines after the filter
tlogs --since "2026-10-29 00:00:04"
assert_eq "1" "$(printf '%s' "$OUT" | jget - 'len(d["lines"])')"
tlogs --since 2026-10-29T05:30:03+05:30
assert_eq "3" "$(printf '%s' "$OUT" | jget - 'len(d["lines"])')"
tlogs --since 2026-10-29
assert_eq "0" "$(printf '%s' "$OUT" | jget - 'len([t for t in d["ts"] if t and t < "2026-10-29"])')"
tlogs -n2 --since 2026-10-28T23:59:59Z
assert_eq "2 2" "$(printf '%s' "$OUT" | jget - '"%d %d" % (len(d["lines"]), len(d["ts"]))')"
# a process filter keeps its own lines' times
tlogs --process web
assert_eq "['2026-10-28T23:59:59Z', '2026-10-29T00:00:03Z', None]" "$(printf '%s' "$OUT" | jget - 'd["ts"]')"
# --since-restart: after the start state.json recorded
mkdir -p "$LB/logs/.benchbar"
printf '{"schema_version":1,"state":"running","started_at":"2026-10-29T00:00:02Z"}\n' >"$LB/logs/.benchbar/state.json"
tlogs --since-restart
assert_eq "4 2026-10-29T00:00:02Z" "$(printf '%s' "$OUT" | jget - '"%d %s" % (len(d["lines"]), d["since"])')"
rm -f "$LB/logs/.benchbar/state.json"
tlogs --since-restart
assert_eq "1" "$CODE"; assert_contains "$ERR" "no recorded start"; assert_eq "" "$OUT" "(a refusal under --json is text on stderr, stdout stays empty)"
tlogs --since nonsense
assert_eq "1" "$CODE"; assert_contains "$ERR" "Cannot read the time"
run_fm logs --since 2026-10-29T00:00:03Z --no-follow --bench-dir "$LB"
assert_eq "1" "$CODE"; assert_contains "$OUT" "need --json"
# the dates a line can carry itself (worker logs): local time
printf '2026-10-28 23:59:58,123 first\ncontinued\n2026-10-29 00:00:01,456 second\n' >"$LB/logs/worker.log"
TZ=UTC touch -t 202610290000.10 "$LB/logs/worker.log"
tlogs --worker
assert_eq "['2026-10-28T23:59:58Z', None, '2026-10-29T00:00:01Z']" "$(printf '%s' "$OUT" | jget - 'd["ts"]')"
# a zone east of UTC: the line's local time is converted, not read as UTC
if [[ "$(TZ=Asia/Kolkata date +%z)" == "+0530" ]]; then
  printf '05:29:58 web.1 | late\n05:30:03 web.1 | later\n' >"$LB/logs/bench.log"
  TZ=Asia/Kolkata touch -t 202610290530.10 "$LB/logs/bench.log"
  TZ=Asia/Kolkata run_json logs --json --no-follow --bench-dir "$LB"
  assert_eq "['2026-10-28T23:59:58Z', '2026-10-29T00:00:03Z']" "$(printf '%s' "$OUT" | jget - 'd["ts"]')"
fi
# no file: empty, no times, no mtime
run_json logs --json --no-follow --previous --bench-dir "$LB"
assert_eq "None [] []" "$(printf '%s' "$OUT" | jget - '"%s %s %s" % (d["mtime"], d["lines"], d["ts"])')"
# the redaction keeps the line count: ts stays in step
printf '10:00:01 web.1 | password=hunter2 ok\n10:00:02 web.1 | fine\n' >"$LB/logs/bench.log"
tlogs
assert_eq "2 2" "$(printf '%s' "$OUT" | jget - '"%d %d" % (len(d["lines"]), len(d["ts"]))')"
assert_not_contains "$OUT" "hunter2"

# ---------------------------------------------------------------- 7. the MCP server

FAKE="$TMP_DIR/fake-benchbar-contracts"
cat >"$FAKE" <<SH
#!/usr/bin/env bash
# records what the server runs and with which environment
printf '%s|%s\n' "\$*" "\${BENCHBAR_NONINTERACTIVE:-unset}" >>"$TMP_DIR/mcp-argv.log"
case "\$*" in
  "up --plain --json"*) printf '%s\n' '{"schema_version":1,"cli_version":"x","event":"step","id":"start_service","status":"done"}' '{"schema_version":1,"cli_version":"x","event":"done","exit":0,"changed":[{"kind":"process","name":"b","detail":"started"}],"warnings":[],"next_actions":[],"state_after":null}'; echo "[OK] bench is up" >&2; exit 0 ;;
  "list --json") printf '{"benches":[]}\n'; exit 0 ;;
  *) printf '{"state":"running"}\n'; exit 0 ;;
esac
SH
chmod +x "$FAKE"
INIT='{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}'
mcp_call() { printf '%s\n' "$INIT" "$1" | BENCHBAR_MCP_CLI="$FAKE" "$FM" mcp 2>/dev/null | tail -n +2; }
: >"$TMP_DIR/mcp-argv.log"
R="$(mcp_call '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"benchbar_status","arguments":{}}}')"
assert_contains "$(cat "$TMP_DIR/mcp-argv.log")" "status --json --ping|1" "(status pings every site; the CLI is told nothing can be asked)"
R="$(mcp_call '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"benchbar_up","arguments":{}}}')"
assert_contains "$(cat "$TMP_DIR/mcp-argv.log")" "up --plain --json|1"
assert_contains "$(cat "$TMP_DIR/mcp-argv.log")" "status --json --ping|1" "(the status after an action pings too)"
assert_eq "0 [OK] bench is up True" "$(printf '%s' "$R" | jget - '" ".join(str(x) for x in (d["result"]["structuredContent"]["exit_code"], d["result"]["structuredContent"]["output"], d["result"]["structuredContent"]["result"]["changed"][0]["kind"] == "process"))')" "(the result keeps its fields; the done line is added)"
: >"$TMP_DIR/mcp-argv.log"
R="$(mcp_call '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"benchbar_logs_tail","arguments":{"since":"2026-10-29T00:00:03Z","since_restart":true,"lines":5}}}')"
assert_contains "$(cat "$TMP_DIR/mcp-argv.log")" "logs --json --no-follow -n5 --since 2026-10-29T00:00:03Z --since-restart"
# the real CLI through the real server: times come through, and a size cap drops lines and times together
R="$(printf '%s\n' "$INIT" '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"benchbar_logs_tail","arguments":{"bench":"'"$LB"'","lines":10}}}' | "$FM" mcp 2>/dev/null | tail -n +2)"
assert_eq "2 2 True" "$(printf '%s' "$R" | jget - '"%d %d %s" % (len(d["result"]["structuredContent"]["lines"]), len(d["result"]["structuredContent"]["ts"]), d["result"]["structuredContent"]["mtime"] is not None)')"
for i in $(seq 1 400); do printf '10:00:%02d web.1 | filler line number %d to make this log bigger\n' $((i % 60)) "$i"; done >"$LB/logs/bench.log"
R="$(printf '%s\n' "$INIT" '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"benchbar_logs_tail","arguments":{"bench":"'"$LB"'","lines":400}}}' | BENCHBAR_MCP_MAX_BYTES=6000 "$FM" mcp 2>/dev/null | tail -n +2)"
assert_eq "True True" "$(printf '%s' "$R" | jget - 'str(d["result"]["structuredContent"].get("truncated")) + " " + str(len(d["result"]["structuredContent"]["lines"]) == len(d["result"]["structuredContent"]["ts"]) < 400)')"

# ---------------------------------------------------------------- 2b. every command with --json: JSON and nothing else

# the commands that print one document: one line, parses, and a refusal leaves stdout empty
for c in "status" "list" "doctor" "site list" "site backups newsite" "logs --no-follow" "where" "app list --no-sites" "ports check" "profile list" "commands" "doctor --prerequisites"; do
  # shellcheck disable=SC2086
  run_json $c --json --bench-dir "$BENCH"
  assert_eq "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "$c: one line (exit $CODE)"
  assert_eq "ok" "$(printf '%s' "$OUT" | jget - '"ok" if isinstance(d, dict) else "no"')" "$c"
done
for c in "status" "doctor" "logs --no-follow" "site list" "app list"; do
  # shellcheck disable=SC2086
  run_json $c --json --bench-dir "$HOME/no-such-bench"
  assert_eq "1" "$CODE" "$c"; assert_eq "" "$OUT" "$c: a refusal under --json leaves stdout empty"
  assert_contains "$ERR" "No bench at"
done
# every dry run with --json: the plan alone (a stream: plan, then done), never text on stdout
# site add's dry run is its plan with a token, one document like app update's;
# --jsonl makes it the stream
run_json site add dryrunsite --dry-run --json --bench-dir "$BENCH"
assert_eq "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "site add --dry-run --json: one line"
[[ "$(printf '%s' "$OUT" | jget - 'd["token"]')" =~ ^[0-9a-f]{64}$ ]] || fail "site add plan without a token: $OUT"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["dry_run"]')" "(the plan document says it is a dry run)"
ADMIN_PASSWORD=pw stream site add dryrunsite --dry-run --jsonl --bench-dir "$BENCH"
assert_eq "plan done" "$(sx '" ".join(x["event"] for x in e)')"
stream adopt "$B2" --dry-run --json --bench-dir "$B2"
assert_eq "plan done" "$(sx '" ".join(x["event"] for x in e)')"
stream install --dry-run --json --bench-dir "$HOME/dry-install" --site dry.localhost
assert_eq "plan done" "$(sx '" ".join(x["event"] for x in e)')"
stream ports apply 0000 --dry-run --json --yes --bench-dir "$BENCH" -- "$BENCH"
assert_eq "done 1" "$(sx '"%s %s" % (e[-1]["event"], e[-1]["exit"])')" "(a refused ports apply still ends with its done line)"
run_events repair --json --dry-run --bench-dir "$BENCH"
assert_eq "plan" "$(ev '" ".join(x["event"] for x in e)')"

# ---------------------------------------------------------------- 8. refusals end the stream; honest changed[]; ack; repair

rm -rf "$MOCK_STATE/keychain"
unset MARIADB_ROOT_PASSWORD
export BENCHBAR_NONINTERACTIVE=1
n_logs="$(logs_now)"; reset_calls
# install --json --yes without ADMIN_PASSWORD: the stream ends with a done naming it, nothing else happened
stream install --json --yes --bench-dir "$HOME/noni2" --site noni2.localhost
assert_eq "1" "$CODE" "$(cat "$STREAM.err")"
assert_eq "done" "$(sx '" ".join(x["event"] for x in e)')"
assert_eq "1 ['ADMIN_PASSWORD']" "$(sx '"%s %s" % (e[-1]["exit"], e[-1]["missing"])')"
assert_contains "$(sx 'e[-1]["error"]')" "ADMIN_PASSWORD"
assert_calls_not_contain '^(bench|brew install|brew services|launchctl)'
assert_no_file "$FL_STATE_DIR/lock"; assert_eq "$n_logs" "$(logs_now)" "(no log)"; assert_no_file "$HOME/noni2"
# site add --for-agent with nothing: every missing input, exit 2 because the MariaDB password is one of them
stream site add noni3 --for-agent --bench-dir "$BENCH"
assert_eq "2" "$CODE"
assert_eq "done 2" "$(sx '"%s %s" % (e[-1]["event"], e[-1]["exit"])')"
assert_eq "True" "$(sx '{"ADMIN_PASSWORD", "MARIADB_ROOT_PASSWORD", "--yes"} <= set(e[-1]["missing"])')"
assert_eq "$n_logs" "$(logs_now)"; assert_no_file "$FL_STATE_DIR/lock"
# a one document command under --json: the one document, with exit, error and missing
mkdir -p "$BENCH/sites/dropme3"; printf '{}\n' >"$BENCH/sites/dropme3/site_config.json"
run_json site drop dropme3 --confirm-site dropme3 --json --bench-dir "$BENCH"
assert_eq "2" "$CODE"
assert_eq "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
assert_eq "2 ['MARIADB_ROOT_PASSWORD']" "$(printf '%s' "$OUT" | jget - '"%s %s" % (d["exit"], d["missing"])')"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["error"]')" "MARIADB_ROOT_PASSWORD"
assert_calls_not_contain '^bench '
# the plain refusal is exit 2 too (AGENTS.md)
run_fm site add noni3 --bench-dir "$BENCH"
assert_eq "2" "$CODE" "$OUT"
unset BENCHBAR_NONINTERACTIVE

# repair --json with no bench: a done line with exit 1 and an error, not silence
run_events repair --json --yes --bench-dir "$HOME/no-such-bench"
assert_eq "1" "$CODE"
assert_eq "done 1" "$(ev '"%s %s" % (e[-1]["event"], e[-1]["exit"])')"
assert_contains "$(ev 'e[-1]["error"]')" "No bench"

# changed[] says only what changed: an app already on the site is not a change
export MARIADB_ROOT_PASSWORD=rootpw
ADMIN_PASSWORD=pw stream site add appsite1 --apps erpnext --json --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "app site" "$(sx '" ".join(sorted(set(x["kind"] for x in e[-1]["changed"] if x["kind"] in ("site", "app"))))')"
ADMIN_PASSWORD=pw stream site add appsite1 --apps erpnext --json --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "[]" "$(sx '[x for x in e[-1]["changed"] if x["kind"] in ("site", "app")]')" "(a second run changes nothing)"

# doctor --ack under --json: one small document, under the lock, and an ack does not adopt a bench
mkdir -p "$HOME/Applications/CleanMyMac X.app"
run_json doctor --ack cleanmymac --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$ERR"
assert_eq "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
assert_eq "ack cleanmymac True 0" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in (d["action"], d["check"], "cleanmymac" in d["acked"], d["exit"]))')"
assert_eq "state" "$(printf '%s' "$OUT" | jget - 'd["changed"][0]["kind"]')"
run_json doctor --unack cleanmymac --json --bench-dir "$BENCH"
assert_eq "unack []" "$(printf '%s' "$OUT" | jget - '"%s %s" % (d["action"], d["acked"])')"
HOLD=$$   # a live process: this test shell
mkdir -p "$FL_STATE_DIR/lock"; printf '%s\n' "$HOLD" >"$FL_STATE_DIR/lock/pid"
run_fm doctor --ack cleanmymac --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Another benchbar run is active"
run_fm doctor --bench-dir "$BENCH"
assert_not_contains "$OUT" "Another benchbar run"
rm -rf "$FL_STATE_DIR/lock"
NA2="$HOME/elsewhere/na2-bench"; make_fake_bench "$NA2" na2-site
run_fm doctor --ack cleanmymac --bench-dir "$NA2"
assert_eq "0" "$CODE" "$OUT"
run_fm status --json --bench-dir "$NA2"
assert_eq "not_adopted" "$(printf '%s' "$OUT" | jget - 'd["state"]')" "(an ack alone does not make a bench known)"
rm -rf "$HOME/Applications/CleanMyMac X.app"

# ---------------------------------------------------------------- 9. second review

# repair --dry-run --json with the app's arguments on a missing bench: a reason on stderr, a done line on stdout
run_events repair --dry-run --json --bench-dir "$HOME/no-such-bench-either"
assert_eq "1" "$CODE"
assert_eq "done 1" "$(ev '"%s %s" % (e[-1]["event"], e[-1]["exit"])')"
assert_contains "$(ev 'e[-1]["error"]')" "No bench"
assert_contains "$(cat "$STREAM.err")" "No bench" "(the app summarizes stderr and stdout: the reason is there)"
# a dry run that works is still the plan alone
run_events repair --dry-run --json --bench-dir "$BENCH"
assert_eq "plan" "$(ev '" ".join(x["event"] for x in e)')"

# a stream refusal: state_after is null, and the reason is on stderr too
export BENCHBAR_NONINTERACTIVE=1
rm -rf "$MOCK_STATE/keychain"; unset MARIADB_ROOT_PASSWORD
stream site add refused1 --json --bench-dir "$BENCH"
assert_eq "None" "$(sx 'e[-1]["state_after"]')"
assert_contains "$(cat "$STREAM.err")" "[FAIL] Cannot start, missing:"
unset BENCHBAR_NONINTERACTIVE
# without the mode: neither password known is exit 2 too (a missing ADMIN_PASSWORD came first and said 1)
run_fm site add refused2 --bench-dir "$BENCH" </dev/null
assert_eq "2" "$CODE" "$OUT"
export MARIADB_ROOT_PASSWORD=rootpw
run_fm site add refused2 --bench-dir "$BENCH" </dev/null
assert_eq "1" "$CODE" "$OUT"

# a key-value lock born in the future (the clock stepped back) is broken, not waited on for good
(
  set +e
  # shellcheck source=lib/frappe-local/ui.sh
  . "$ROOT/lib/frappe-local/ui.sh"
  # shellcheck source=lib/frappe-local/state.sh
  . "$ROOT/lib/frappe-local/state.sh"
  mkdir -p "$TMP_DIR/kv.d"; : >"$TMP_DIR/kv.d/f"; mkdir "$TMP_DIR/kv.d/f.lck"
  touch -t 203501010000 "$TMP_DIR/kv.d/f.lck"
  fl__kv_lock "$TMP_DIR/kv.d/f" >/dev/null 2>&1 &
  waiter=$!
  n=0
  while kill -0 "$waiter" 2>/dev/null && [[ "$n" -lt 400 ]]; do sleep 0.1; n=$((n + 1)); done
  if kill -0 "$waiter" 2>/dev/null; then kill "$waiter" 2>/dev/null; echo hung >"$TMP_DIR/kv.result"; else echo broken >"$TMP_DIR/kv.result"; fi
)
assert_eq "broken" "$(cat "$TMP_DIR/kv.result")" "(a lock from the future is broken)"

# ---------------------------------------------------------------- 10. third review

# the non interactive mode never lets sudo prompt: a hosts line that needs a
# password is skipped with its command, as under --json, and sudo -v never runs
cp "$FL_HOSTS_FILE" "$TMP_DIR/hosts.keep"
grep -v ' macdev$' "$TMP_DIR/hosts.keep" >"$FL_HOSTS_FILE"
rm -f "$MOCK_STATE/sudo_cred"; reset_calls
BENCHBAR_NONINTERACTIVE=1 run_fm repair --yes --bench-dir "$BENCH"
assert_calls_not_contain '^sudo -v' "(BENCHBAR_NONINTERACTIVE=1 repair must not prompt for sudo)"
assert_contains "$OUT" "cannot ask for one"
assert_eq "0" "$(grep -c ' macdev$' "$FL_HOSTS_FILE" || true)" "(the hosts step was skipped)"
reset_calls
stream --for-agent repair --yes --bench-dir "$BENCH"
assert_calls_not_contain '^sudo -v' "(--for-agent repair must not prompt for sudo)"
assert_eq "done" "$(ev 'e[-1]["event"]')"
cp "$TMP_DIR/hosts.keep" "$FL_HOSTS_FILE"; touch "$MOCK_STATE/sudo_cred"

# warnings[] and next_actions[] say what is still wrong after the verify pass,
# not what the plan found before the run fixed it
mv "$BENCH/Procfile.lean" "$TMP_DIR/Procfile.lean.aside"
run_events repair --yes --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "done 0 True" "$(ev '"%s %s %s" % (e[-1]["event"], e[-1]["exit"], any(c["name"] == "write_procfile" for c in e[-1]["changed"]))')"
assert_eq "[]" "$(ev '[w for w in e[-1]["warnings"] if "Procfile" in w]')" "(a fixed problem is not a warning)"
assert_eq "[]" "$(ev '[a for a in e[-1]["next_actions"] if "repair" in a["command"]]')" "(nothing left for repair to do)"

# site drop --new-default: the default's move is in changed[] too (it ran in a subshell)
mkdir -p "$BENCH/sites/dropdef"; printf '{}\n' >"$BENCH/sites/dropdef/site_config.json"
run_fm site default dropdef --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
stream site drop dropdef --confirm-site dropdef --new-default macdev --jsonl --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "True" "$(sx '{"kind": "site", "name": "macdev", "detail": "now the default site"} in e[-1]["changed"]')" "$(cat "$STREAM")"
assert_eq "macdev macdev" "$(sx '"%s %s" % (e[-1]["default_site"], e[-1]["state_after"]["site"])')" "$(cat "$STREAM")"

# site add NEW --dry-run: nothing was created, and the done line of the stream says it was a dry run
# (--json is the one document plan, which claims nothing either)
ADMIN_PASSWORD=pw stream site add drynew --dry-run --jsonl --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "False True" "$(sx '"%s %s" % (e[-1].get("created", False), e[-1].get("dry_run"))')" "$(cat "$STREAM")"
run_json site add drynew --dry-run --json --bench-dir "$BENCH"
assert_eq "0 False" "$CODE $(printf '%s' "$OUT" | jget - 'd.get("created", False)')" "$OUT"
assert_no_file "$BENCH/sites/drynew"

printf 'test-agent-contracts: ok\n'
