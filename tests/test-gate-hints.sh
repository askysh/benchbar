#!/usr/bin/env bash
# The refusal of the bench guess gate names the form that was typed (#401).
#
# A command that changes things and was not told which bench acts on the first one it finds; an agent with
# more than one bench known is refused: "Choose one: benchbar LINE --bench-dir PATH". LINE used to be the command
# and its first argument, so `app unfocus frappe` was sent to `benchbar app unfocus --bench-dir PATH`. LINE is now
# the line that was typed, with these rules (maintainers/DECISIONS.md):
#   - the words of the command, and its positional words up to what its usage line names, are quoted
#     (printf %q); the flags the command knows and their values are quoted too
#   - the value of a flag that could carry a secret (the words of history.sh), a word after "--", a flag the
#     command does not know (BENCHBAR_LENIENT_FLAGS=1) with its value, a word the command does not take, and a word
#     the redactor or the history would change (a URL with credentials) are left out: "..." once per run
# tests/golden/gate-hints.tsv has one line per sample: the key of the command in the commands table, the
# environment, the words typed, the hint. Each is run two ways below: the hint is the expected line, and its words,
# as the shell reads them, are the words that were typed plus --bench-dir PATH, "..." where a run of words was left out.
# A command of the table that changes things and takes an argument or a value must have a sample, or be named
# in EXEMPT with the reason, so that a new command cannot be forgotten.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/frappe-bench"
OTHER="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" macdev
make_fake_bench "$OTHER" other
: >"$FL_HOSTS_FILE"
DATA="$ROOT/tests/golden/gate-hints.tsv"
TABLE="$ROOT/lib/frappe-local/commands.sh"
SECRET=s3cr3t

fresh() { rm -f "$FL_STATE_FILE"; rm -rf "$FL_STATE_DIR/benches"; }
# the whole state folder as one number: a refused run must leave it byte for byte as it was (no log, no history)
state_sum() { (cd "$FL_STATE_DIR" && find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do printf '%s\n' "$f"; cat "$f"; done) | cksum; }

# the keys that change things, have an argument or a value, and have no sample, with the reason
EXEMPT="install|the dispatch skips the table's bench gate for it (the case list before the gate in benchbar): it takes its bench from its own arguments
adopt|as install
register|as install
ports setup|as install (the ports commands take the benches as arguments)
ports apply|as install
ports mode|as install
profile create|as install (the profile commands skip the gate)
profile export|as install
profile import|as install
profile subscribe|as install
profile update|as install
profile remove|as install
labs on|as install (labs is global, not a bench's)
labs off|as install
lan-guard|as install (the firewall rule is the computer's, not a bench's)
lan-guard install|as install
lan-guard remove|as install
lan-guard allow-node|as install
share join|a guest's share commands act on a room of another computer, on no bench (fl_share_guest_sub)
share leave|as share join
share forget|as share join"

# the hint of one refusal. Plain: the line of the notice; --for-agent: the fix of the one JSON line (that line is
# stdout; the error is its own text, which holds no word of the command line)
FOUND_HINT=""
refused_hint() {
  local words=("$@") w agent=0
  for w in "${words[@]}"; do [[ "$w" != --for-agent ]] || agent=1; done
  FOUND_HINT=""; ERR=""
  if [[ "$agent" == 1 ]]; then
    BENCHBAR_NONINTERACTIVE=1 run_fm_split "${words[@]}"
    assert_eq "1" "$CODE" "(--for-agent: refused) $OUT $ERR"
    assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c .)" "(--for-agent: one line on stdout) $OUT"
    FOUND_HINT="$(printf '%s' "$OUT" | python3 -c '
import json, re, sys
d = json.loads(sys.stdin.read())
assert "More than one bench is possible" in d["error"], d
m = re.search(r"Choose one: (benchbar .* --bench-dir PATH) \(or set BENCH_DIR\)", d["fix"])
print(m.group(1) if m else "")')"
    return 0
  fi
  BENCHBAR_NONINTERACTIVE=1 run_fm "${words[@]}"
  assert_eq "1" "$CODE" "(refused) $OUT"
  assert_contains "$OUT" "More than one bench is possible" "(the gate refuses) $OUT"
  FOUND_HINT="$(printf '%s\n' "$OUT" | sed -n 's/.*Choose one: \(benchbar .* --bench-dir PATH\) (or set BENCH_DIR).*/\1/p' | head -n 1)"
}

# words_match TYPED-WORDS HINT: the hint, read as a shell reads it, is the typed words plus --bench-dir PATH,
# with "..." in place of a run of one or more typed words and no "..." next to another
words_match() {
  python3 -I -c '
import shlex, sys
typed, hint = shlex.split(sys.argv[1]), shlex.split(sys.argv[2])
if hint[-2:] != ["--bench-dir", "PATH"] or hint[0] != "benchbar":
    sys.exit("the hint does not start with benchbar and end with --bench-dir PATH: %r" % hint)
hint = hint[1:-2]
if any(a == b == "..." for a, b in zip(hint, hint[1:])):
    sys.exit("two ... in a row: %r" % hint)
def ok(t, h):
    if not h:
        return not t
    if h[0] == "...":
        return any(ok(t[k:], h[1:]) for k in range(1, len(t) + 1))
    return bool(t) and t[0] == h[0] and ok(t[1:], h[1:])
if not ok(typed, hint):
    sys.exit("the hint %r is not the typed words %r with runs left out" % (hint, typed))
' "$1" "$2"
}

# the samples: one refusal each
KEYS_SEEN=" "
samples=()
while IFS= read -r line; do
  [[ -n "$line" && "$line" != '#'* ]] || continue
  samples+=("$line")
done <"$DATA"
[[ "${#samples[@]}" -ge 60 ]] || fail "the sample file has only ${#samples[@]} samples"
fresh
before="$(state_sum)"
for line in "${samples[@]}"; do
  IFS=$'\t' read -r key envs argv want <<<"$line"
  [[ -n "$want" ]] || fail "a sample line without its four fields: $line"
  KEYS_SEEN="${KEYS_SEEN}${key} "
  eval "words=($argv)"
  envnames=""
  if [[ "$envs" != - ]]; then
    for e in $envs; do export "${e?}"; envnames="$envnames ${e%%=*}"; done
  fi
  refused_hint "${words[@]}"
  for n in $envnames; do unset "$n"; done
  assert_eq "$want" "$FOUND_HINT" "(sample: $argv) the hint"
  if [[ -n "$FOUND_HINT" ]]; then
    words_match "$argv" "$FOUND_HINT" || fail "(sample: $argv) $FOUND_HINT"
  fi
  # the secret marker is in the output only when the expected hint has it
  if [[ "$want" != *"$SECRET"* ]]; then
    assert_not_contains "$OUT${ERR:-}" "$SECRET" "(sample: $argv) a word that must not come back is in the output"
  fi
  # a refusal comes before the log, the lock and the history: nothing is written
  assert_eq "$before" "$(state_sum)" "(sample: $argv) the state is as it was"
done

# the table has no mutating key with an argument or a value that nobody tested and nobody exempted
printf '%s\n' "$EXEMPT" >"$TMP_DIR/exempt.txt"
printf '%s' "$KEYS_SEEN" >"$TMP_DIR/keys-seen.txt"
missing="$(python3 -I - "$TABLE" "$TMP_DIR/exempt.txt" "$TMP_DIR/keys-seen.txt" <<'PY'
import re, sys
table, exempt_file, seen_file = sys.argv[1:4]
cmds, valued = {}, set()
for l in open(table, encoding="utf8"):
    p = l.rstrip("\n").split("~")
    if p[0] == "cmd" and len(p) > 8:
        cmds[p[1]] = (p[2], p[7])
    elif p[0] == "flag" and len(p) > 3 and p[3]:
        valued.add(p[1])
seen = set(open(seen_file).read().split(" "))
exempt = {}
for l in open(exempt_file):
    if l.strip():
        k, _, why = l.rstrip("\n").partition("|")
        exempt[k] = why
need = set()
for k, (usage, mut) in cmds.items():
    if mut != "yes":
        continue
    rest = usage[len("benchbar " + k):]
    if re.search(r"[A-Z]{2,}", rest) or re.search(r"[a-z]\|[a-z]", rest) or k in valued:
        need.add(k)
out = []
for k in sorted(need):
    if k not in seen and k not in exempt:
        out.append("no sample and not exempt: " + k)
for k, why in exempt.items():
    if k not in need:
        out.append("exempt but not a key that needs a sample (stale entry): " + k)
    elif k in seen:
        out.append("exempt and has a sample: " + k)
    if not why.strip():
        out.append("exempt without a reason: " + k)
for k in seen:
    if k not in ("", "-") and (k not in cmds or cmds[k][1] != "yes"):
        out.append("a sample for a key that is not mutating yes in the table: " + k)
print("\n".join(out))
PY
)"
assert_eq "" "$missing" "(every mutating key with an argument or a value has a sample or an exemption)"

# a person (no BENCHBAR_NONINTERACTIVE) is told which bench was picked, and the run goes on: no hint, no refusal
fresh
run_fm app unfocus frappe
assert_eq "0" "$CODE" "(a person) $OUT"
assert_contains "$OUT" "acting on" "(a person: the notice)"
assert_not_contains "$OUT" "Choose one" "(a person: no refusal)"

# the notice, the JSON error and the log of a refusal do not print the typed words: the secret of a refused
# run is nowhere in the state folder or the output of any mode (the samples above hold the output of the plain mode)
fresh
export BENCHBAR_LENIENT_FLAGS=1
BENCHBAR_NONINTERACTIVE=1 run_fm_split site default dev2.localhost --token "$SECRET" --for-agent
assert_eq "1" "$CODE" "(secret, --for-agent) $OUT $ERR"
assert_not_contains "$OUT$ERR" "$SECRET" "(the secret is not in a --for-agent refusal)"
BENCHBAR_NONINTERACTIVE=1 run_fm_split site default dev2.localhost --token "$SECRET" --json
assert_eq "1" "$CODE" "(secret, --json) $OUT $ERR"
assert_not_contains "$OUT$ERR" "$SECRET" "(the secret is not in a --json refusal)"
unset BENCHBAR_LENIENT_FLAGS
if grep -rq -- "$SECRET" "$FL_STATE_DIR" 2>/dev/null; then fail "the secret of a refused run is in the state folder"; fi

printf 'test-gate-hints: ok\n'
