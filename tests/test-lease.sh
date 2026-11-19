#!/usr/bin/env bash
# Leases per bench and site (issue 184): benchbar lease take, renew, release and list; the commands that a
# lease stands in front of (lease.sh, fl_lease_gate) and the ones it never stops; --lease and --break-lease;
# expiry; the id that only its holder and a person see; status --json's leases.
# The harness is a person's run only when BENCHBAR_NONINTERACTIVE=0 (the app's tree, tests/test-person-guard.sh);
# an agent is BENCHBAR_NONINTERACTIVE=1 with a BENCHBAR_CALLER of its own.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
exec </dev/null

BENCH="$HOME/dev/frappe-bench"
OTHER="$HOME/work/b/second"
make_fake_bench "$BENCH" macdev
make_fake_bench "$OTHER" secondsite
sed_inplace 's/"webserver_port": 8000/"webserver_port": 8001/; s/"socketio_port": 9000/"socketio_port": 9001/' "$OTHER/sites/common_site_config.json"
mkdir -p "$BENCH/sites/two.localhost"
printf '{"db_name": "_two"}\n' >"$BENCH/sites/two.localhost/site_config.json"
printf '127.0.0.1 macdev two.localhost secondsite\n' >>"$FL_HOSTS_FILE"
run_fm register "$BENCH" "$OTHER"
assert_eq "0" "$CODE" "$OUT"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
LEASES="$FL_STATE_DIR/leases.tsv"

# the clock: every run sees this time (FL_NOW, FL_TESTING only)
T0=1800000000
export FL_NOW="$T0"
iso() { python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(sys.argv[1]))))' "$1"; }

# as WHO ARGS...: an agent run named WHO (BENCHBAR_NONINTERACTIVE=1), the text of stdout and stderr in OUT
as() {
  local who="$1"; shift
  set +e; OUT="$(BENCHBAR_NONINTERACTIVE=1 BENCHBAR_CALLER="$who" "$FM" "$@" 2>&1)"; CODE="$?"; set -e
}
# asj WHO ARGS...: the same, stdout only (the JSON)
asj() {
  local who="$1"; shift
  set +e; OUT="$(BENCHBAR_NONINTERACTIVE=1 BENCHBAR_CALLER="$who" "$FM" "$@" 2>/dev/null)"; CODE="$?"; set -e
}
# person ARGS...: the app's run: a person clicked (BENCHBAR_NONINTERACTIVE=0 under the app's process tree)
person() { set +e; OUT="$(BENCHBAR_NONINTERACTIVE=0 "$FM" "$@" 2>&1)"; CODE="$?"; set -e; }
# done_of EXPR: a field of the last line of OUT (the done line of a stream, or a document)
done_of() { printf '%s\n' "$OUT" | tail -n 1 | jget - "$1"; }
lease_count() { if [[ -f "$LEASES" ]]; then grep -c . "$LEASES" || true; else printf 0; fi; }

# ---- take: a lease on one site, the id back, the file private
asj agent-a lease take --site two.localhost --bench-dir "$BENCH" --for 20 --note "running tests" --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "done" "$(done_of 'd["event"]')"
ID_A="$(done_of 'd["lease"]["id"]')"
case "$ID_A" in l-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) fail "not a lease id: $ID_A" ;; esac
assert_eq "site" "$(done_of 'd["lease"]["scope"]')"
assert_eq "two.localhost" "$(done_of 'd["lease"]["site"]')"
assert_eq "$BENCH" "$(done_of 'd["lease"]["bench"]')"
assert_eq "agent-a" "$(done_of 'd["lease"]["holder"]')"
assert_eq "running tests" "$(done_of 'd["lease"]["note"]')"
assert_eq "20" "$(done_of 'd["lease"]["minutes"]')"
assert_eq "$(iso $((T0 + 1200)))" "$(done_of 'd["lease"]["expires_at"]')"
assert_eq "$(iso "$T0")" "$(done_of 'd["lease"]["since"]')"
assert_eq "True" "$(done_of 'd["lease"]["yours"]')"
assert_eq "1" "$(lease_count)"
perm="$(stat -c %a "$LEASES" 2>/dev/null || stat -f %Lp "$LEASES")"
assert_eq "600" "$perm" "(an id is a bearer token: the file is private)"
assert_no_file "$FL_STATE_DIR/leases.lock" "(the lock folder is gone)"
# the human run says it, with the id and what to do with it
as agent-b lease take --site macdev --bench-dir "$BENCH" --for 5
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "taken on site macdev of $BENCH for 5 minutes"
assert_contains "$OUT" "--lease l-"
ID_B="$(printf '%s\n' "$OUT" | sed -n 's/.*lease \(l-[0-9a-f]*\) taken.*/\1/p')"
assert_eq "2" "$(lease_count)"

# ---- one holder at a time: the same site, a bench over a leased site, a site under a leased bench
as agent-b lease take --site two.localhost --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "is already leased by agent-a until $(iso $((T0 + 1200))) (running tests)"
assert_not_contains "$OUT" "$ID_A" "(a refusal never names another holder's id)"
as agent-b lease take --bench "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "is already leased by agent-"
as agent-a lease take --site two.localhost --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "You hold it as lease $ID_A"
as agent-a lease take --bench "$OTHER" --for 5
assert_eq "0" "$CODE" "(another bench is its own: $OUT)"
ID_O="$(printf '%s\n' "$OUT" | sed -n 's/.*lease \(l-[0-9a-f]*\) taken.*/\1/p')"
assert_eq "3" "$(lease_count)"

# ---- list: the id only for the holder and for a person; yours; --bench filters
asj agent-b lease list --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "3" "$(printf '%s' "$OUT" | jget - 'len(d["leases"])')"
assert_eq "None" "$(printf '%s' "$OUT" | jget - '[l["id"] for l in d["leases"] if l["holder"] == "agent-a" and l["site"]][0]')" "(agent-b is not shown agent-a's id)"
assert_eq "$ID_B" "$(printf '%s' "$OUT" | jget - '[l["id"] for l in d["leases"] if l["holder"] == "agent-b"][0]')" "(it is shown its own)"
assert_eq "480" "$(printf '%s' "$OUT" | jget - 'd["max_minutes"]')"
asj agent-a lease list --json
assert_eq "$ID_A" "$(printf '%s' "$OUT" | jget - '[l["id"] for l in d["leases"] if l["site"] == "two.localhost"][0]')"
assert_eq "None" "$(printf '%s' "$OUT" | jget - '[l["id"] for l in d["leases"] if l["holder"] == "agent-b"][0]')"
set +e; OUT="$(BENCHBAR_NONINTERACTIVE=0 "$FM" lease list --json 2>/dev/null)"; set -e
assert_eq "3" "$(printf '%s' "$OUT" | jget - 'len([l for l in d["leases"] if l["id"]])')" "(a person at the app sees every id)"
asj agent-b lease list --bench "$OTHER" --json
assert_eq "1" "$(printf '%s' "$OUT" | jget - 'len(d["leases"])')"
as agent-b lease list --bench-dir "$BENCH"
assert_contains "$OUT" "agent-a"
assert_contains "$OUT" "running tests"
assert_not_contains "$OUT" "$ID_A"
assert_not_contains "$OUT" "secondsite"
as agent-b lease list
assert_contains "$OUT" "Only the holder of a lease and a person at a terminal see its id"

# ---- status --json lists the bench's leases, never an id; another bench has its own
run_fm status --json --bench-dir "$BENCH"
assert_eq "2" "$(printf '%s' "$OUT" | jget - 'len(d["leases"])')"
assert_eq "agent-a" "$(printf '%s' "$OUT" | jget - '[l for l in d["leases"] if l["scope"] == "site" and l["site"] == "two.localhost"][0]["holder"]')"
assert_eq "running tests" "$(printf '%s' "$OUT" | jget - '[l for l in d["leases"] if l["site"] == "two.localhost"][0]["note"]')"
assert_not_contains "$OUT" "$ID_A"
assert_not_contains "$OUT" "$ID_B"
run_fm status --json --bench-dir "$OTHER"
assert_eq "1" "$(printf '%s' "$OUT" | jget - 'len(d["leases"])')"
assert_eq "bench" "$(printf '%s' "$OUT" | jget - 'd["leases"][0]["scope"]')"
assert_eq "None" "$(printf '%s' "$OUT" | jget - 'd["leases"][0]["site"]')"

# ---- a lease stops a change of what it covers, naming who holds it and until when
reset_calls
as agent-b restart
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "The site two.localhost of $BENCH is leased by agent-a until $(iso $((T0 + 1200))) (running tests)"
assert_contains "$OUT" "The site macdev of $BENCH is leased by agent-b"
assert_contains "$OUT" "Nothing was changed"
assert_not_contains "$OUT" "$ID_A"
assert_calls_not_contain 'launchctl' "(a refused restart touched no agent)"
assert_no_file "$FL_STATE_DIR/lock" "(a refused run takes no run lock)"
asj agent-c down --json
assert_eq "1" "$CODE" "$OUT"
assert_eq "lease_held" "$(done_of 'd["error_id"]')"
assert_eq "1" "$(done_of 'd["exit"]')"
assert_contains "$(done_of 'd["error"]')" "is leased by agent-a"
# the other bench is not covered
as agent-c restart --bench-dir "$OTHER" --dry-run
assert_not_contains "$OUT" "is leased"
# a site lease stops the commands of that site, a bench lease and the whole bench commands too
as agent-c site drop two.localhost --confirm-site two.localhost
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "The site two.localhost of $BENCH is leased by agent-a"
as agent-c site restore two.localhost --from 20260101_000000 --yes
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "is leased by agent-a"
as agent-c pull prod:two --as two.localhost --yes
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "is leased by agent-a"
as agent-c app update frappe --yes
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "is leased by agent-"
as agent-c app install erpnext --site two.localhost
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "is leased by agent-a"
as agent-c service --yes
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "is leased by agent-"
as agent-c repair --yes
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "is leased by agent-"
as agent-c ports apply tokentoken1 --yes -- "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "is leased by agent-"
as agent-c uninstall-service --all --yes
assert_eq "1" "$CODE" "(--all is every bench with a lease: $OUT)"
assert_contains "$OUT" "is leased by agent-"
# one site is not another: site commands of a free site, and the bench level ones, pass a site lease
as agent-c site drop nosuch.localhost --confirm-site nosuch.localhost
assert_not_contains "$OUT" "is leased"
as agent-c site default macdev
assert_not_contains "$OUT" "is leased" "(site default is stopped by a bench lease only: $OUT)"
# reads, a dry run and the commands a lease never stops
for words in "status --json" "site list" "doctor --quick" "app list --no-sites" "site backups macdev" "lease list" "logs --no-follow"; do
  # shellcheck disable=SC2086
  as agent-c $words --bench-dir "$BENCH"
  assert_not_contains "$OUT" "is leased" "(a read is never refused: $words)"
done
as agent-c restart --dry-run --bench-dir "$BENCH"
assert_not_contains "$OUT" "is leased" "(a dry run is a read)"
as agent-c site drop two.localhost --confirm-site two.localhost --dry-run --bench-dir "$BENCH"
assert_not_contains "$OUT" "is leased"
as agent-c up --bench-dir "$BENCH"
assert_not_contains "$OUT" "is leased" "(up never interrupts, so a lease does not stop it)"
as agent-c site backup two.localhost --bench-dir "$BENCH"
assert_not_contains "$OUT" "is leased" "(a backup is what a lease holder needs most)"

# ---- passing a lease: its own id, repeatable, and only for what it covers
as agent-a site drop two.localhost --confirm-site two.localhost --lease "$ID_A" --dry-run
assert_not_contains "$OUT" "is leased"
as agent-a site drop two.localhost --lease "$ID_A"
assert_not_contains "$OUT" "is leased" "(the holder's id lets the command past the gate: $OUT)"
as agent-a site drop two.localhost --lease="$ID_A"
assert_not_contains "$OUT" "is leased"
as agent-a site drop two.localhost --lease "$ID_B"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "The site two.localhost of $BENCH is leased by agent-a"
as agent-a restart --lease "$ID_A"
assert_eq "1" "$CODE" "(the lease on macdev still stands: $OUT)"
assert_not_contains "$OUT" "The site two.localhost"
assert_contains "$OUT" "The site macdev of $BENCH is leased by agent-b"
as agent-a restart --lease "$ID_A" --lease "$ID_B"
assert_not_contains "$OUT" "is leased" "(both ids: nothing stands in the way: $OUT)"
as agent-a restart --lease l-000000000000
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "The lease id you passed (l-000000000000) is not active"
as agent-a restart --lease nonsense
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "'nonsense' is not a lease id"
as agent-a restart --lease
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "--lease needs a lease id"
# the same through a stream
asj agent-a restart --json --lease "$ID_A"
assert_eq "lease_held" "$(done_of 'd["error_id"]')"

# ---- --break-lease is a person's: refused for agents (exit 2), passed for a person with a warning
as agent-c restart --break-lease
assert_eq "2" "$CODE" "$OUT"
assert_contains "$OUT" "--break-lease is a person's decision"
assert_contains "$OUT" "is leased by agent-"
as agent-c restart --break-lease --for-agent
assert_eq "2" "$CODE" "$OUT"
asj agent-c restart --break-lease --json
assert_eq "2" "$CODE" "$OUT"
assert_eq "lease_break_refused" "$(done_of 'd["error_id"]')"
# no terminal and no claim of a person
set +e; OUT="$(env -u BENCHBAR_NONINTERACTIVE "$FM" restart --break-lease 2>&1)"; CODE="$?"; set -e
assert_eq "2" "$CODE" "(a plain pipe is not a person: $OUT)"
# a person: the app says so, under its process tree
person restart --break-lease
assert_not_contains "$OUT" "--break-lease is a person's decision"
assert_contains "$OUT" "--break-lease: going ahead although The site two.localhost"
# the lease stands: breaking it is for that one run
assert_eq "3" "$(lease_count)"
# a person at a real terminal sees every id in the list (a pty on stdin; nothing here reads from it)
run_fm_tty lease list --json
assert_eq "3" "$(printf '%s' "$OUT" | jget - 'len([l for l in d["leases"] if l["id"]])')"
# nothing in the way, nothing to break
as agent-c restart --bench-dir "$OTHER" --break-lease --dry-run
assert_not_contains "$OUT" "is a person's decision"

# ---- renew and release
asj agent-a lease renew "$ID_A" --for 60 --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "$(iso $((T0 + 3600)))" "$(done_of 'd["lease"]["expires_at"]')"
assert_eq "60" "$(done_of 'd["lease"]["minutes"]')"
assert_eq "running tests" "$(done_of 'd["lease"]["note"]')"
assert_eq "agent-a" "$(done_of 'd["lease"]["holder"]')"
assert_eq "3" "$(lease_count)"
as agent-a lease renew "$ID_A"
assert_eq "0" "$CODE" "(without --for: its own length again: $OUT)"
assert_contains "$OUT" "until $(iso $((T0 + 3600)))"
as agent-a lease renew l-0123456789ab
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "is not active"
asj agent-a lease renew l-0123456789ab --json
assert_eq "lease_unknown" "$(done_of 'd["error_id"]')"
as agent-a lease renew "$ID_A" --for 481
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "from 1 to 480"
as agent-a lease renew
assert_eq "1" "$CODE" "$OUT"
asj agent-b lease release "$ID_B" --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "True" "$(done_of 'd["released"]')"
assert_eq "2" "$(lease_count)"
asj agent-b lease release "$ID_B" --json
assert_eq "0" "$CODE" "(a lease that is gone is released: $OUT)"
assert_eq "False" "$(done_of 'd["released"]')"
as agent-b lease release "$ID_B"
assert_contains "$OUT" "unchanged: lease $ID_B is not active"
as agent-b lease release bogus
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "'bogus' is not a lease id"
as agent-b lease release
assert_eq "1" "$CODE" "$OUT"
as agent-b lease take --site macdev --bench-dir "$BENCH" --dry-run
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "dry-run: would take a lease on site macdev"
assert_eq "2" "$(lease_count)" "(a dry run takes nothing)"

# ---- expiry: past its end a lease is ignored everywhere, and the next write drops it
export FL_NOW=$((T0 + 3601))
asj agent-c lease list --json
assert_eq "0" "$(printf '%s' "$OUT" | jget - 'len(d["leases"])')" "(both leases are past their end)"
assert_eq "2" "$(lease_count)" "(a read writes nothing: the expired lines are still on disk)"
run_fm status --json --bench-dir "$BENCH"
assert_eq "0" "$(printf '%s' "$OUT" | jget - 'len(d["leases"])')"
as agent-c site drop two.localhost --confirm-site two.localhost
assert_not_contains "$OUT" "is leased" "(an expired lease stops nothing)"
as agent-a lease renew "$ID_A" --for 5
assert_eq "1" "$CODE" "(an expired lease cannot be renewed: $OUT)"
assert_contains "$OUT" "it expired, or it was released"
# a new lease on the same place drops the expired ones on write
as agent-c lease take --site two.localhost --bench-dir "$BENCH" --for 1
assert_eq "0" "$CODE" "(the place is free again: $OUT)"
assert_eq "1" "$(lease_count)" "(written: the expired lines are pruned) $(cat "$LEASES")"
as agent-c lease release "$(sed -n 's/^\(l-[0-9a-f]*\).*/\1/p' "$LEASES")"
assert_no_file "$LEASES" "(no lease left: no file)"
run_fm status --json --bench-dir "$BENCH"
assert_eq "0" "$(printf '%s' "$OUT" | jget - 'len(d["leases"])')"
export FL_NOW="$T0"

# ---- input: the length, the holder, the target, the note
as agent-a lease take --site macdev --bench-dir "$BENCH" --for 0
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "--for takes a number of minutes from 1 to 480, not '0'"
as agent-a lease take --site macdev --bench-dir "$BENCH" --for 481
assert_eq "1" "$CODE" "$OUT"
as agent-a lease take --site macdev --bench-dir "$BENCH" --for abc
assert_eq "1" "$CODE" "$OUT"
as agent-a lease take --site macdev --bench-dir "$BENCH" --for -5
assert_eq "1" "$CODE" "$OUT"
as agent-a lease take --site macdev --bench-dir "$BENCH" --for
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "--for needs a value"
as agent-a lease take
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "needs --bench PATH or --site NAME"
as agent-a lease take --bench "$BENCH" --site macdev
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "a bench or on a site, not both"
as agent-a lease take --site nosuch.localhost --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "No site 'nosuch.localhost'"
as agent-a lease take --site 'Bad Name' --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Invalid site name"
as agent-a lease take --bench "$TMP_DIR/not-a-bench"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "is not a Frappe bench"
as agent-a lease take --bench "$BENCH" --wat
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Unknown argument for lease take: --wat"
as agent-a lease frobnicate
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Unknown lease command: frobnicate"
for bad in 'bad name!' '-lead' 'a/b' "$(printf 'x%.0s' $(seq 1 41))"; do
  as "$bad" lease take --bench "$BENCH"
  assert_eq "1" "$CODE" "(a caller of [$bad]: $OUT)"
  assert_contains "$OUT" "BENCHBAR_CALLER is not a usable name"
done
assert_no_file "$LEASES" "(nothing of those was written)"
# the holder: BENCHBAR_CALLER, else "agent" for an agent, else the login name
set +e; OUT="$(BENCHBAR_NONINTERACTIVE=1 "$FM" lease take --site macdev --bench-dir "$BENCH" 2>&1)"; set -e
assert_contains "$OUT" "held by agent"
ID_X="$(printf '%s\n' "$OUT" | sed -n 's/.*lease \(l-[0-9a-f]*\) taken.*/\1/p')"
as agent lease release "$ID_X"
set +e; OUT="$(BENCHBAR_NONINTERACTIVE=0 "$FM" lease take --site macdev --bench-dir "$BENCH" 2>&1)"; set -e
assert_contains "$OUT" "held by tester" "(the login name, FL_OS_USER here)"
ID_X="$(printf '%s\n' "$OUT" | sed -n 's/.*lease \(l-[0-9a-f]*\) taken.*/\1/p')"
person lease release "$ID_X"
assert_eq "0" "$CODE" "$OUT"
# the note: printable ASCII, no line break, trimmed, 120 characters
as agent-a lease take --site macdev --bench-dir "$BENCH" --note "$(printf '  tab\there\nnew line caf\xc3\xa9  ')"
assert_eq "0" "$CODE" "$OUT"
[[ "$(grep -c . "$LEASES")" == "1" ]] || fail "a note must stay on one line: $(cat "$LEASES")"
assert_eq "11" "$(awk -F'\t' '{ print NF }' "$LEASES")" "(eleven fields, whatever the note held)"
asj agent-a lease list --json
assert_eq "tab?here?new line caf??" "$(printf '%s' "$OUT" | jget - 'd["leases"][0]["note"]')"
as agent-a lease release "$(sed -n 's/^\(l-[0-9a-f]*\).*/\1/p' "$LEASES")"
long="$(printf 'n%.0s' $(seq 1 200))"
as agent-a lease take --site macdev --bench-dir "$BENCH" --note "$long"
asj agent-a lease list --json
assert_eq "120" "$(printf '%s' "$OUT" | jget - 'len(d["leases"][0]["note"])')"
as agent-a lease release "$(sed -n 's/^\(l-[0-9a-f]*\).*/\1/p' "$LEASES")"
as agent-a lease take --site macdev --bench-dir "$BENCH"
asj agent-a lease list --json
assert_eq "None" "$(printf '%s' "$OUT" | jget - 'd["leases"][0]["note"]')"
assert_eq "30" "$(printf '%s' "$OUT" | jget - 'd["leases"][0]["minutes"]')" "(30 minutes without --for)"
as agent-a lease release "$(sed -n 's/^\(l-[0-9a-f]*\).*/\1/p' "$LEASES")"

# ---- many at once: the lock keeps every line
for n in 1 2 3 4 5 6; do
  mkdir -p "$BENCH/sites/s${n}.localhost"
  printf '{}\n' >"$BENCH/sites/s${n}.localhost/site_config.json"
done
for n in 1 2 3 4 5 6; do
  (BENCHBAR_NONINTERACTIVE=1 BENCHBAR_CALLER="par-${n}" "$FM" lease take --site "s${n}.localhost" --bench-dir "$BENCH" --for 5 >/dev/null 2>&1) &
done
wait
assert_eq "6" "$(lease_count)" "(six takes at once, six leases) $(cat "$LEASES")"
assert_eq "6" "$(cut -f1 "$LEASES" | sort -u | grep -c .)" "(six different ids)"
assert_no_file "$FL_STATE_DIR/leases.lock"
# a lock left by a run that died is taken over after 30 seconds, not before
mkdir "$FL_STATE_DIR/leases.lock"
touch -t 202001010000 "$FL_STATE_DIR/leases.lock"
as agent-a lease take --site macdev --bench-dir "$BENCH" --for 1
assert_eq "0" "$CODE" "(a stale lock folder does not stop a take: $OUT)"
assert_no_file "$FL_STATE_DIR/leases.lock"
# the cap
python3 - "$LEASES" "$BENCH" "$((T0 + 600))" <<'PY'
import sys
path, bench, exp = sys.argv[1:4]
with open(path, "w") as f:
    for i in range(64):
        f.write("\t".join(["l-%012x" % i, "site", bench, "cap%d.localhost" % i, "filler", "2027-01-15T08:00:00Z", "1800000000",
                           "2027-01-15T08:10:00Z", exp, "10", "-"]) + "\n")
PY
as agent-a lease take --site macdev --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "There are 64 active leases already"
rm -f "$LEASES"
# a malformed line is skipped, not fatal, and never reaches a reader's JSON
printf 'garbage\nl-aaaaaaaaaaaa\tbench\t%s\t-\tx\t-\t1\t-\t%s\t5\t-\n\tbench\t\n' "$BENCH" "$((T0 + 600))" >"$LEASES"
asj agent-a lease list --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "1" "$(printf '%s' "$OUT" | jget - 'len(d["leases"])')"
run_fm status --json --bench-dir "$BENCH"
assert_eq "1" "$(printf '%s' "$OUT" | jget - 'len(d["leases"])')"
rm -f "$LEASES"

# ---- the catalogue, the help and the flags every command takes
run_fm commands --json
assert_contains "$OUT" '"lease take"'
assert_contains "$OUT" '"--break-lease"'
run_fm lease take --help
assert_contains "$OUT" "benchbar lease take (--bench PATH | --site NAME)"
assert_contains "$OUT" "BENCHBAR_CALLER"
run_fm lease --help
assert_contains "$OUT" "lease take|release|renew|list"
run_fm --help
assert_contains "$OUT" "lease take"
assert_contains "$OUT" "--break-lease"

echo "ok: test-lease"
