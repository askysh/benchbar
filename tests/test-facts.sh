#!/usr/bin/env bash
# What one doctor run reads once (lib/frappe-local/facts.sh): kept answers and
# their file names, background jobs, and a parallel doctor that says exactly what a
# serial one says.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---- file names: short keys are their own, others never share one, long ones fit
FACTS="$ROOT/lib/frappe-local/facts.sh"
names="$(bash -c '
  . "$1"
  for k in abc a_b a_5fb "a b" "a/b" "git:app:log -1 --author=<x@y.z>" "$(printf "x%.0s" $(seq 1 300))" "$(printf "x%.0s" $(seq 1 301))"; do
    fl_fact_path_v p "$k"; printf "%s\n" "$p"
  done' _ "$FACTS")"
assert_eq "8" "$(printf '%s\n' "$names" | wc -l | tr -d ' ')"
assert_eq "8" "$(printf '%s\n' "$names" | sort -u | wc -l | tr -d ' ')" "(two keys got one file name)"
assert_eq "k-abc" "$(printf '%s\n' "$names" | sed -n 1p)"
longest="$(printf '%s\n' "$names" | awk '{ if (length($0) > m) m = length($0) } END { print m }')"
[[ "$longest" -le 200 ]] || fail "a file name of $longest bytes"

# ---- fl_memo_v: asked once in a run, with its exit code; every time outside one
out="$(bash -c '
  . "$1"
  n="$2/count"; : >"$n"
  cmd() { printf x >>"$n"; printf "two\nlines\n"; return 3; }
  fl_memo_v a key cmd; r1=$?
  outside="$(wc -c <"$n" | tr -d " ")"
  fl_facts_begin
  fl_memo_v a key cmd; r2=$?
  fl_memo_v b key cmd; r3=$?
  fl_memo k2 cmd >/dev/null
  inside="$(wc -c <"$n" | tr -d " ")"
  printf "%s|%s|%s|%s|%s|%s" "$r1" "$r2" "$r3" "$outside" "$inside" "$(printf %s "$b" | wc -l | tr -d " ")"
  fl_facts_forget key
  fl_memo_v a key cmd >/dev/null
  printf "|%s" "$(wc -c <"$n" | tr -d " ")"
  fl_facts_end
  [[ -z "$FL_FACTS_DIR" ]] && printf "|ended"' _ "$FACTS" "$TMP_DIR")"
# the fifth field is the lines of the kept output, trailing newline kept; outside: 1 run; inside: the first ask runs it (2 in all), the second reads it, k2 is a new key (3);
# forget runs it again (4)
assert_eq "3|3|3|1|3|2|4|ended" "$out"

# ---- background jobs are bounded and a finished job frees its slot
out="$(bash -c '
  . "$1"
  FL_DOCTOR_JOBS=2
  fl_par_free && printf "free;"
  sleep 1 & fl_par_add "$!"; sleep 1 & fl_par_add "$!"
  fl_par_free || printf "full;"
  fl_par_wait_all; fl_par_free && printf "free again"' _ "$FACTS")"
assert_eq "free;full;free again" "$out"

# ---- a parallel doctor says what a serial one says (same ids, levels, messages, fixes, order)
BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH" macdev
add_listener 8000 4101 python3 127.0.0.1
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
rows='"\n".join("|".join([c["id"], c["level"], c["message"], str(c["fix_command"]), str(c["action"])]) for c in d["checks"])'
set +e
FL_DOCTOR_JOBS=1 "$FM" doctor --json --bench-dir "$BENCH" >"$TMP_DIR/serial.json" 2>/dev/null
FL_DOCTOR_JOBS=6 "$FM" doctor --json --bench-dir "$BENCH" >"$TMP_DIR/parallel.json" 2>/dev/null
set -e
serial="$(jget "$TMP_DIR/serial.json" "$rows")"
parallel="$(jget "$TMP_DIR/parallel.json" "$rows")"
[[ "$(printf '%s\n' "$serial" | wc -l | tr -d ' ')" -gt 30 ]] || fail "the serial doctor reported too few checks: $serial"
assert_eq "$serial" "$parallel" "(the parallel doctor differs from the serial one)"
# the quick run too, and the order is the order of FL_CHECK_ORDER either way
assert_eq "$(jget "$TMP_DIR/serial.json" 'd["summary"]')" "$(jget "$TMP_DIR/parallel.json" 'd["summary"]')"

# ---- doctor leaves no folder of kept answers behind
left="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'benchbar-facts.*' -newer "$TMP_DIR/serial.json" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$left"

printf 'test-facts: ok\n'
