#!/usr/bin/env bash
# What the heavy commands cost in programs started, as test-status-cost does
# for status: doctor, doctor --json, install --dry-run, adopt --dry-run and
# app list on a fake setup of two registered benches and one to adopt. A
# budget is the measured count plus about 10 percent: the test documents
# today's cost and fails when a change makes a command start more programs.
# Lower a budget when a change makes a command cheaper.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# execs: every program benchbar started, mocked or shimmed, except its own
# interpreter. mockkill stands in for the kill builtin.
execs() { grep -v -c -E '^mockkill ' "$MOCK_LOG" || true; }
# summary: the five programs started most, "sed 40, grep 31, ..."
summary() { awk '{ print ($1 == "exec") ? $2 : $1 }' "$MOCK_LOG" | sort | uniq -c | sort -rn | head -5 | awk '{ printf "%s%s %s", (NR > 1 ? ", " : ""), $2, $1 }'; }

# shims: log "exec NAME" and run the real program, as in test-status-cost.
# Programs a mock starts are not logged (_mocklib.sh exports BENCHBAR_TEST_MOCK).
SHIMS="$TMP_DIR/shims"
mkdir -p "$SHIMS"
for n in sed awk tr head tail cut sort uniq grep cat cksum basename dirname id uname shasum date readlink wc mktemp mv rm cp ls stat touch mkdir find xargs sleep python3 perl ruby ps sysctl df getconf hostname sw_vers; do
  real="$(command -v "$n" 2>/dev/null)" || continue
  case "$real" in "$ROOT"/tests/mocks/*) continue ;; esac
  cat >"$SHIMS/$n" <<SHIM
#!/bin/bash
if [[ -z "\${BENCHBAR_TEST_MOCK:-}" ]]; then printf 'exec %s\n' "$n" >>"\$MOCK_LOG"; fi
exec "$real" "\$@"
SHIM
  chmod +x "$SHIMS/$n"
done

# cost NAME BUDGET CODES ARGS...: run benchbar ARGS with the shims first on
# PATH, check its exit code is one of CODES ("0" or "0 1") and that it started
# at most BUDGET programs, and print the count
cost() {
  local name="$1" max="$2" codes="$3" n saved="$PATH"
  shift 3
  reset_calls
  PATH="$SHIMS:$PATH"
  run_fm "$@"
  PATH="$saved"
  case " $codes " in *" $CODE "*) ;; *) fail "$name: exit $CODE, expected one of $codes"$'\n'"$OUT" ;; esac
  n="$(execs)"
  printf '%s: %s programs, budget %s (%s)\n' "$name" "$n" "$max" "$(summary)"
  [[ "$n" -le "$max" ]] || fail "$name: $n programs started, budget $max"$'\n'"$(awk '{ print ($1 == "exec") ? $2 : $1 }' "$MOCK_LOG" | sort | uniq -c | sort -rn)"
}

# two registered benches, two sites each, the first with its service; a
# third bench that nothing manages yet, for adopt
BENCH="$HOME/work/a/frappe-bench"
OTHER="$HOME/work/b/second"
THIRD="$HOME/work/c/third"
make_fake_bench "$BENCH" macdev
make_fake_bench "$OTHER" secondsite
make_fake_bench "$THIRD" thirdsite
sed_inplace 's/"webserver_port": 8000/"webserver_port": 8001/; s/"socketio_port": 9000/"socketio_port": 9001/' "$OTHER/sites/common_site_config.json"
for b in "$BENCH" "$OTHER"; do
  mkdir -p "$b/sites/two.localhost"
  printf '{}\n' >"$b/sites/two.localhost/site_config.json"
done
printf '127.0.0.1 macdev secondsite two.localhost\n' >>"$FL_HOSTS_FILE"
run_fm register "$BENCH" "$OTHER"
assert_eq "0" "$CODE" "$OUT"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
export ADMIN_PASSWORD=admin MARIADB_ROOT_PASSWORD=root

# the budgets: measured on macOS and Linux (the larger of the two), plus 10 percent
cost "doctor" 350 "0 1" doctor --bench-dir "$BENCH"
cost "doctor --json" 436 "0 1" doctor --json --bench-dir "$BENCH"
cost "install --dry-run --yes" 746 "0" install --dry-run --yes --bench-dir "$HOME/fresh-bench" --site freshsite
cost "adopt --dry-run --yes" 457 "0" adopt "$THIRD" --dry-run --yes
cost "app list --json" 102 "0" app list --json --bench-dir "$BENCH"

printf 'test-command-cost: ok\n'
