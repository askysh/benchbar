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
assert_not_contains "$OUT" "$ID_A" "(a bench lease over a leased site names no id either)"
asj agent-b lease take --site two.localhost --bench-dir "$BENCH" --json
assert_eq "1" "$CODE" "$OUT"
assert_eq "lease_held" "$(done_of 'd["error_id"]')"
assert_not_contains "$OUT" "$ID_A" "(the stream of a clash names no id)"
# the holder asking again is told to renew, and is not given its id back in the refusal either
as agent-a lease take --site two.localhost --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "is already leased by agent-a"
assert_contains "$OUT" "benchbar lease renew"
assert_not_contains "$OUT" "$ID_A" "(a clash never prints a lease id, not even the holder's own)"
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
# leases are coordination, not access control: a person sees an id only as the holder, like anyone else
set +e; OUT="$(BENCHBAR_NONINTERACTIVE=0 "$FM" lease list --json 2>/dev/null)"; set -e
assert_eq "0" "$(printf '%s' "$OUT" | jget - 'len([l for l in d["leases"] if l["id"]])')" "(a person who is not the holder sees no id)"
assert_eq "3" "$(printf '%s' "$OUT" | jget - 'len(d["leases"])')" "(but sees every lease: holder, scope, expiry)"
set +e; OUT="$(BENCHBAR_NONINTERACTIVE=0 BENCHBAR_CALLER=agent-a "$FM" lease list --json 2>/dev/null)"; set -e
assert_eq "2" "$(printf '%s' "$OUT" | jget - 'len([l for l in d["leases"] if l["id"]])')" "(a person naming the holder sees that holder's ids: agent-a has two leases)"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'all(l["id"] for l in d["leases"] if l["holder"] == "agent-a")')"
asj agent-b lease list --bench "$OTHER" --json
assert_eq "1" "$(printf '%s' "$OUT" | jget - 'len(d["leases"])')"
as agent-b lease list --bench-dir "$BENCH"
assert_contains "$OUT" "agent-a"
assert_contains "$OUT" "running tests"
assert_not_contains "$OUT" "$ID_A"
assert_not_contains "$OUT" "secondsite"
as agent-b lease list
assert_contains "$OUT" "Only the holder of a lease sees its id"

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
# a rollback to a snapshot replaces the site, like a restore; taking a snapshot only adds one
as agent-c site rollback two.localhost --to latest --yes
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "is leased by agent-a"
as agent-c site snapshot two.localhost
assert_not_contains "$OUT" "is leased" "(a snapshot is what a lease holder needs, like a backup)"
# removing snapshots changes the site's folder, so a lease gates it, whichever way the site is placed:
# after drop, first or after an option, and behind an option with a value
person site snapshot drop two.localhost 20260101_000000 --yes
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "is leased by agent-a"
person site snapshot drop two.localhost --prune --yes
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "is leased by agent-a"
person site snapshot drop --prune two.localhost --yes
assert_eq "1" "$CODE" "(--prune before the site: $OUT)"; assert_contains "$OUT" "The site two.localhost of $BENCH is leased by agent-a"
person site snapshot drop --keep 2 --prune two.localhost --yes
assert_eq "1" "$CODE" "(an option with a value before the site: $OUT)"; assert_contains "$OUT" "is leased by agent-a"
# benchbar run: a change of the leased site is stopped, a read of the allow list is not
as agent-c run --site two.localhost --yes -- migrate
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "is leased by agent-a"
as agent-c run --site two.localhost -- version
assert_not_contains "$OUT" "is leased" "(run version only reads)"
ops_before="$(find "$FL_STATE_DIR/ops" -type f 2>/dev/null | grep -c . || true)"
as agent-c site restore two.localhost --from 20260101_000000 --yes --background
assert_eq "1" "$CODE" "(a background run is refused at once, not in a detached run: $OUT)"
assert_contains "$OUT" "is leased by agent-a"
assert_eq "$ops_before" "$(find "$FL_STATE_DIR/ops" -type f 2>/dev/null | grep -c . || true)" "(and no operation was started)"
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
# a person at a real terminal (a pty on stdin; nothing here reads from it) sees an id only as the holder too
run_fm_tty lease list --json
assert_eq "0" "$(printf '%s' "$OUT" | jget - 'len([l for l in d["leases"] if l["id"]])')"
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
assert_eq "64" "$CODE" "(an option the catalogue does not list stops at the parser: $OUT)"
assert_contains "$OUT" "Unknown option for lease take: --wat"
as agent-a lease frobnicate
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Unknown lease command: frobnicate"
for bad in 'bad name!' '-lead' 'a/b' "$(printf 'x%.0s' $(seq 1 41))"; do
  as "$bad" lease take --bench "$BENCH"
  assert_eq "1" "$CODE" "(a caller of [$bad]: $OUT)"
  assert_contains "$OUT" "BENCHBAR_CALLER is not a usable name"
done
assert_no_file "$LEASES" "(nothing of those was written)"
# the holder: BENCHBAR_CALLER, else the login name; an agent run without a name of its own is refused,
# since every such agent would be "agent" and share each other's leases
set +e; OUT="$(BENCHBAR_NONINTERACTIVE=1 "$FM" lease take --site macdev --bench-dir "$BENCH" 2>&1)"; CODE="$?"; set -e
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Set BENCHBAR_CALLER to a name of its own"
set +e; OUT="$(BENCHBAR_NONINTERACTIVE=1 "$FM" lease take --site macdev --bench-dir "$BENCH" --for-agent 2>/dev/null)"; CODE="$?"; set -e
assert_eq "1" "$CODE" "$OUT"
assert_eq "lease_caller_required" "$(done_of 'd["error_id"]')"
set +e; OUT="$(BENCHBAR_NONINTERACTIVE=1 "$FM" lease take --site macdev --bench-dir "$BENCH" --dry-run 2>&1)"; CODE="$?"; set -e
assert_eq "1" "$CODE" "(a dry run refuses it too: $OUT)"
assert_no_file "$LEASES" "(nothing of those was written)"
# an agent without a name may still read: it is nobody's holder
set +e; OUT="$(BENCHBAR_NONINTERACTIVE=1 "$FM" lease list --json 2>/dev/null)"; CODE="$?"; set -e
assert_eq "0" "$CODE" "$OUT"
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
# each take's output and exit code are kept: a take that is lost here (seen once in CI, run
# 44933354251 of 21 November: five leases, nothing else known) must say which one and why
takes_log() {
  local n
  for n in 1 2 3 4 5 6; do printf '\n  take %s: %s' "$n" "$(tr '\n' '|' <"$TMP_DIR/take.$1.$n" 2>/dev/null)"; done
  printf '\n  leases.tsv: %s' "$(tr '\n' '|' <"$LEASES" 2>/dev/null)"
}
for n in 1 2 3 4 5 6; do
  (BENCHBAR_NONINTERACTIVE=1 BENCHBAR_CALLER="par-${n}" "$FM" lease take --site "s${n}.localhost" --bench-dir "$BENCH" --for 5 >"$TMP_DIR/take.par.$n" 2>&1; printf 'exit=%s\n' "$?" >>"$TMP_DIR/take.par.$n") &
done
wait
assert_eq "6" "$(lease_count)" "(six takes at once, six leases)$(takes_log par)"
assert_eq "6" "$(cut -f1 "$LEASES" | sort -u | grep -c .)" "(six different ids)"
assert_no_file "$FL_STATE_DIR/leases.lock"
# a lock left by a run that died is taken over after 30 seconds, not before
mkdir "$FL_STATE_DIR/leases.lock"
touch -t 202001010000 "$FL_STATE_DIR/leases.lock"
as agent-a lease take --site macdev --bench-dir "$BENCH" --for 1
assert_eq "0" "$CODE" "(a stale lock folder does not stop a take: $OUT)"
assert_no_file "$FL_STATE_DIR/leases.lock"
# six takes meeting one stale lock: every one is taken, and the stale folder is renamed away and removed once
python3 -c 'import os, sys; os.remove(sys.argv[1])' "$LEASES"
mkdir "$FL_STATE_DIR/leases.lock"
touch -t 202001010000 "$FL_STATE_DIR/leases.lock"
for n in 1 2 3 4 5 6; do
  (BENCHBAR_NONINTERACTIVE=1 BENCHBAR_CALLER="stale-${n}" "$FM" lease take --site "s${n}.localhost" --bench-dir "$BENCH" --for 5 >"$TMP_DIR/take.stale.$n" 2>&1; printf 'exit=%s\n' "$?" >>"$TMP_DIR/take.stale.$n") &
done
wait
assert_eq "6" "$(lease_count)" "(six takes over one stale lock)$(takes_log stale)"
assert_no_file "$FL_STATE_DIR/leases.lock"
assert_eq "0" "$(find "$FL_STATE_DIR" -maxdepth 1 -name 'leases.lock.stale*' | grep -c . || true)" "(no renamed lock is left behind)"
assert_no_file "$FL_STATE_DIR/leases.lock.reclaim"
# The race behind the lost lease, step by step (CI run 45156540716: a take said ok and its lease was
# not in the file, four takes ended with "busy"). A waiter judges the lock stale. Before it acts,
# another waiter removes the stale folder and a third run takes the lock: a live lock under the
# same name. The waiter must not move or remove that one. The age reads stand in for the other
# runs: the first one says "stale" and swaps the folder for a live holder's, the third lets the
# holder go.
RACE_DIR="$TMP_DIR/race"; mkdir -p "$RACE_DIR/state/leases.lock"
race_out="$(FL_STATE_DIR="$RACE_DIR/state" RACE="$RACE_DIR" bash -c '
  set -euo pipefail
  . "$1/lib/frappe-local/lock.sh"; . "$1/lib/frappe-local/lease.sh"
  dir="$FL_STATE_DIR/leases.lock"; n=0
  # the age is asked for inside $( ): the count is kept in a file
  fl__lock_age() {
    local c; c="$(cat "$RACE/n" 2>/dev/null || printf 0)"; c=$((c + 1)); printf "%s" "$c" >"$RACE/n"
    if [[ "$1" != "$dir" ]]; then printf 0; return 0; fi
    case "$c" in
      1) command rmdir "$dir"; command mkdir "$dir"; : >"$RACE/holder"; printf 31 ;;
      2) printf 0 ;;
      *) if [[ -e "$RACE/holder" ]]; then command rm -f "$RACE/holder"; command rmdir "$dir"; fi; printf 0 ;;
    esac
  }
  mv() { if [[ "$1" == "$dir" && -e "$RACE/holder" ]]; then printf "moved a live lock\n"; fi; command mv "$@"; }
  rmdir() { if [[ "$1" == "$dir" && -e "$RACE/holder" ]]; then printf "removed a live lock\n"; fi; command rmdir "$@"; }
  fl__lease_lock && printf "locked\n"
  fl__lease_unlock
' _ "$ROOT" 2>&1)" || fail "the lock was not taken once the live holder let go: $race_out"
assert_not_contains "$race_out" "a live lock" "(a waiter that judged an older folder stale touched the lock a third run had just taken)"
assert_contains "$race_out" "locked"
assert_no_file "$RACE_DIR/state/leases.lock"
assert_no_file "$RACE_DIR/state/leases.lock.reclaim"
# Two runs make the lock folder at once (issue 138; CI on Ubuntu 26.04, run 45348315776: six takes
# said ok and the file held five leases). uutils coreutils' mkdir looks for the folder first and,
# when another process makes it in between, exits 0 all the same: both runs held the lock, both read
# the file before either wrote it, and the second write dropped the first one's lease. The mkdir
# here answers as uutils does in that race (a folder that is there counts as made). A take must
# still wait for the holder, and two reclaimers must not share the guard.
UU_DIR="$TMP_DIR/uu"; mkdir -p "$UU_DIR/state" "$UU_DIR/bin"
uu_out="$(FL_STATE_DIR="$UU_DIR/state" bash -c '
  set -euo pipefail
  . "$1/lib/frappe-local/lock.sh"; . "$1/lib/frappe-local/lease.sh"
  # the real mkdir by its path: on bash 3.2 a failed "command mkdir" ends the run under set -e even
  # inside || or an if
  mk="$(type -P mkdir)"
  mkdir() { "$mk" "$@" 2>/dev/null || [[ -d "${!#}" ]]; }
  sleep() { :; }
  fl__lease_lock && printf "first holds\n"
  if (fl__lease_lock); then printf "second holds too\n"; else printf "second waits\n"; fi
  fl__lease_unlock
  if (fl__lease_lock); then printf "second holds once the first let go\n"; fi
  fl__lease_unlock
  g="$FL_STATE_DIR/leases.lock.reclaim"
  fl_mkdir_excl "$g" && printf "guard taken\n"
  if fl_mkdir_excl "$g"; then printf "guard taken twice\n"; fi
  fl_rmdir_excl "$g"
' _ "$ROOT" 2>&1)" || fail "the lease lock under a mkdir that answers as uutils does: $uu_out"
assert_contains "$uu_out" "first holds"
assert_contains "$uu_out" "second waits" "(a run whose mkdir said yes to a folder another run holds took the lock: $uu_out)"
assert_not_contains "$uu_out" "second holds too"
assert_contains "$uu_out" "second holds once the first let go"
assert_contains "$uu_out" "guard taken"
assert_not_contains "$uu_out" "guard taken twice"
assert_no_file "$UU_DIR/state/leases.lock"
assert_no_file "$UU_DIR/state/leases.lock.reclaim"
# the same six takes at once with that mkdir first on PATH, the CI runner's case end to end
# shellcheck disable=SC2016 # expands in the mkdir script
printf '#!/bin/bash\n# mkdir as uutils coreutils answers the run that lost the race to make a folder: made\n"%s" "$@" 2>/dev/null || [[ -d "${!#}" ]]\n' "$(command -v mkdir)" >"$UU_DIR/bin/mkdir"
chmod +x "$UU_DIR/bin/mkdir"
python3 -c 'import os, sys; os.remove(sys.argv[1])' "$LEASES"
for n in 1 2 3 4 5 6; do
  (PATH="$UU_DIR/bin:$PATH" BENCHBAR_NONINTERACTIVE=1 BENCHBAR_CALLER="uu-${n}" "$FM" lease take --site "s${n}.localhost" --bench-dir "$BENCH" --for 5 >"$TMP_DIR/take.uu.$n" 2>&1; printf 'exit=%s\n' "$?" >>"$TMP_DIR/take.uu.$n") &
done
wait
assert_eq "6" "$(lease_count)" "(six takes at once under a mkdir that answers as uutils does)$(takes_log uu)"
assert_no_file "$FL_STATE_DIR/leases.lock"
# A lock folder that takes no claim (no space, no inodes, no permission) is a write error, said at
# once: no run holds it, so waiting for one would end in a wrong "busy". The mkdir below makes the
# folder read only. root writes there anyway, so the check needs a user.
CW_DIR="$TMP_DIR/cw"; mkdir -p "$CW_DIR/state" "$CW_DIR/bin"
cw_user=0
chmod a-w "$CW_DIR/state"
if [[ ! -w "$CW_DIR/state" ]]; then cw_user=1; fi
chmod u+w "$CW_DIR/state"
if [[ "$cw_user" == 1 ]]; then
  cw_out="$(FL_STATE_DIR="$CW_DIR/state" bash -c '
    set -euo pipefail
    . "$1/lib/frappe-local/lock.sh"; . "$1/lib/frappe-local/lease.sh"
    fl_die() { printf "DIE %s\n" "$1"; exit 1; }
    mk="$(type -P mkdir)"
    mkdir() { "$mk" "$@" || return; [[ "$1" == -p ]] || chmod a-w "${!#}"; }
    rc=0; fl_mkdir_excl "$FL_STATE_DIR/x" || rc=$?; printf "excl=%s\n" "$rc"
    command rmdir "$FL_STATE_DIR/x"
    rc=0; fl__lease_lock || rc=$?; printf "lease=%s\n" "$rc"
    SECONDS=0; (fl_lock_acquire "$FL_STATE_DIR/lock") || true; printf "waited=%s\n" "$SECONDS"
  ' _ "$ROOT" 2>&1)" || true
  assert_contains "$cw_out" "excl=2" "(a folder that takes no claim is not a lock another run holds: $cw_out)"
  assert_contains "$cw_out" "lease=2"
  assert_contains "$cw_out" "DIE Could not write the lock $CW_DIR/state/lock."
  assert_contains "$cw_out" "waited=0"
  assert_no_file "$CW_DIR/state/leases.lock"
  assert_no_file "$CW_DIR/state/lock"
  # end to end: lease take says what is wrong, takes nothing and leaves no folder behind
  # shellcheck disable=SC2016 # expands in the mkdir script
  printf '#!/bin/bash\n# leases.lock is made read only: its claim cannot be written\n"%s" "$@" || exit\ncase "${!#}" in */leases.lock) chmod a-w "${!#}" ;; esac\n' "$(command -v mkdir)" >"$CW_DIR/bin/mkdir"
  chmod +x "$CW_DIR/bin/mkdir"
  python3 -c 'import os, sys; os.remove(sys.argv[1])' "$LEASES"
  set +e; OUT="$(PATH="$CW_DIR/bin:$PATH" BENCHBAR_NONINTERACTIVE=1 BENCHBAR_CALLER=cw "$FM" lease take --site s1.localhost --bench-dir "$BENCH" --for 5 2>&1)"; CODE="$?"; set -e
  assert_eq "1" "$CODE" "$OUT"
  assert_contains "$OUT" "Could not write the lock $FL_STATE_DIR/leases.lock."
  assert_not_contains "$OUT" "busy"
  assert_no_file "$FL_STATE_DIR/leases.lock"
  assert_eq "0" "$(lease_count)" "(nothing was taken)"
fi
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
# the help keeps the column of the lines around it
assert_contains "$OUT" "  pull HOST:SITE      Copy a production site over SSH"

echo "ok: test-lease"
