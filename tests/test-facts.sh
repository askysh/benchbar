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
# a temp folder of their own: other tests running in parallel share /tmp
OWN_TMP="$TMP_DIR/own-tmp"; mkdir -p "$OWN_TMP"
set +e
TMPDIR="$OWN_TMP" FL_DOCTOR_JOBS=1 "$FM" doctor --json --bench-dir "$BENCH" >"$TMP_DIR/serial.json" 2>/dev/null
TMPDIR="$OWN_TMP" FL_DOCTOR_JOBS=6 "$FM" doctor --json --bench-dir "$BENCH" >"$TMP_DIR/parallel.json" 2>/dev/null
set -e
serial="$(jget "$TMP_DIR/serial.json" "$rows")"
parallel="$(jget "$TMP_DIR/parallel.json" "$rows")"
[[ "$(printf '%s\n' "$serial" | wc -l | tr -d ' ')" -gt 30 ]] || fail "the serial doctor reported too few checks: $serial"
assert_eq "$serial" "$parallel" "(the parallel doctor differs from the serial one)"
# the quick run too, and the order is the order of FL_CHECK_ORDER either way
assert_eq "$(jget "$TMP_DIR/serial.json" 'd["summary"]')" "$(jget "$TMP_DIR/parallel.json" 'd["summary"]')"

# ---- doctor leaves no folder of kept answers behind
left="$(find "$OWN_TMP" -maxdepth 1 -name 'benchbar-facts.*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$left"

# ---- the folder of a run is the run's own: one named in the environment is never deleted
mkdir -p "$TMP_DIR/not-mine"; : >"$TMP_DIR/not-mine/keep"
out="$(FL_FACTS_DIR="$TMP_DIR/not-mine" bash -c '. "$1"; printf "[%s]" "$FL_FACTS_DIR"; fl_facts_begin; fl_facts_end' _ "$FACTS")"
assert_eq "[]" "$out"
[[ -f "$TMP_DIR/not-mine/keep" ]] || fail "a folder named in FL_FACTS_DIR was deleted"

# ---- git config -l: a value after the key, whatever it holds (a branch named a=b)
APPS="$ROOT/lib/frappe-local/apps.sh"
mkdir -p "$TMP_DIR/cfgbench/apps/x"
git -C "$TMP_DIR/cfgbench/apps/x" init -q
git -C "$TMP_DIR/cfgbench/apps/x" config "branch.a=b.remote" "up=stream"
git -C "$TMP_DIR/cfgbench/apps/x" config "branch.a=b.merge" "refs/heads/a=b"
out="$(bash -c '
  . "$1"; . "$2"
  FL_BENCH_DIR="$3"
  fl_facts_begin
  fl_app_config_v r x "branch.a=b.remote"; fl_app_config_v m x "branch.a=b.merge"; fl_app_config_v none x "branch.a=b.nothing"
  fl_facts_end
  printf "%s|%s|[%s]" "$r" "$m" "$none"' _ "$FACTS" "$APPS" "$TMP_DIR/cfgbench")"
assert_eq "up=stream|refs/heads/a=b|[]" "$out"

# ---- a slot freed while the run waits for a slow check is refilled at once
DOCTOR="$ROOT/lib/frappe-local/doctor.sh"
out="$(bash -c '
  . "$1"; . "$2"
  D="$3"
  FL_DOCTOR_JOBS=2
  chk_a() { sleep 2; : >"$D/a.done"; }
  chk_b() { :; }
  chk_c() { if [[ -f "$D/a.done" ]]; then printf late; else printf early; fi >"$D/c.result"; }
  fl_facts_begin
  FL_DOC_PENDING="a b c"
  fl_doctor_pump
  fl_doctor_wait "${FL_DOC_PAR_PIDS[0]}"
  fl_par_wait_all
  fl_facts_end
  cat "$D/c.result"' _ "$FACTS" "$DOCTOR" "$TMP_DIR")"
assert_eq "early" "$out"

# ---- stopped mid run: no folder, no child, nothing on stderr but benchbar's own line.
# After 0.3, 0.8 and 1.5 s, and once a brew info is certainly under way ("brew":
# the real pgrep; the mock one answers for every pattern).
for t in 0.3 0.8 1.5 brew; do
  rm -rf "$TMP_DIR/sigtmp"; mkdir -p "$TMP_DIR/sigtmp"
  ( TMPDIR="$TMP_DIR/sigtmp" MOCK_BREW_SLEEP=7.37 FL_DOCTOR_JOBS=6 exec "$FM" doctor --json --bench-dir "$BENCH" >/dev/null 2>"$TMP_DIR/sig.err" ) &
  pid=$!
  if [[ "$t" == "brew" ]]; then
    for _ in $(seq 1 150); do /usr/bin/pgrep -f 'sleep 7.37' >/dev/null 2>&1 && break; sleep 0.2; done
    /usr/bin/pgrep -f 'sleep 7.37' >/dev/null 2>&1 || fail "no brew info was under way to stop"
  else
    sleep "$t"
  fi
  kill -TERM "$pid" 2>/dev/null || true
  code=0; wait "$pid" 2>/dev/null || code=$?
  assert_eq "143" "$code" "(stopped at ${t}s)"
  left="$(find "$TMP_DIR/sigtmp" -maxdepth 1 -name 'benchbar-facts.*' | wc -l | tr -d ' ')"
  assert_eq "0" "$left" "(a facts folder was left after a stop at ${t}s)"
  kids="$(/usr/bin/pgrep -f 'sleep 7.37' | wc -l | tr -d ' ' || true)"
  assert_eq "0" "$kids" "(a child outlived the run stopped at ${t}s)"
  extra="$(grep -v -e '^$' -e 'stopped by SIG' "$TMP_DIR/sig.err" || true)"
  assert_eq "" "$extra" "(stderr after a stop at ${t}s)"
done

printf 'test-facts: ok\n'
