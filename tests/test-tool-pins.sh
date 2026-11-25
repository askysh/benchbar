#!/usr/bin/env bash
# INST-9 (#133): the bench CLI and yarn are installed at exact versions, kept
# in lib/frappe-local/ui.sh (FL_PIN_FRAPPE_BENCH, FL_PIN_YARN), and
# nothing in the installer, repair or doctor installs either of them without a
# version.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
. "$ROOT/lib/frappe-local/ui.sh"; . "$ROOT/lib/frappe-local/run.sh"
. "$ROOT/lib/frappe-local/version-policy.sh"

# ---- the pins are exact versions, and the environment cannot change them
[[ "$FL_PIN_FRAPPE_BENCH" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "FL_PIN_FRAPPE_BENCH is not an exact version: ${FL_PIN_FRAPPE_BENCH}"
[[ "$FL_PIN_YARN" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "FL_PIN_YARN is not an exact version: ${FL_PIN_YARN}"
assert_eq "$FL_PIN_YARN" "$(FL_PIN_YARN=9.9.9 FL_PIN_FRAPPE_BENCH=9.9.9 bash -c ". '$ROOT/lib/frappe-local/ui.sh'; . '$ROOT/lib/frappe-local/ui.sh'; printf %s \"\$FL_PIN_YARN\"")" "(the environment does not set a pin)"
assert_eq "$FL_PIN_FRAPPE_BENCH" "$(FL_PIN_FRAPPE_BENCH=9.9.9 bash -c ". '$ROOT/lib/frappe-local/ui.sh'; . '$ROOT/lib/frappe-local/ui.sh'; printf %s \"\$FL_PIN_FRAPPE_BENCH\"")" "(the environment does not set a pin)"

# ---- the pinned bench handles every profile: it is not older than any bench_min
while IFS=$'\t' read -r profile _ _ _ _ _ _ _ _ _ _ _ _ _ _ bench_min; do
  [[ "$profile" == "profile" || -z "$bench_min" ]] && continue
  if fl_version_lt "$FL_PIN_FRAPPE_BENCH" "$bench_min"; then fail "the pinned bench ${FL_PIN_FRAPPE_BENCH} is older than ${bench_min}, the minimum of profile ${profile}"; fi
done <"$ROOT/config/release-profiles.tsv"

# ---- no install line leaves the version open
FILES=("$ROOT/00-mac-system-deps.sh" "$ROOT/00-linux-system-deps.sh" "$ROOT/01-install-bench-and-site.sh" "$ROOT"/lib/frappe-local/*.sh)
if grep -nE 'install -g "?yarn("|[[:space:]]|\)|$)' "${FILES[@]}" | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#'; then fail "yarn is installed without a version in the lines above"; fi
if grep -nE '(uv tool install|pipx install)( --[a-z]+)* "?frappe-bench("|[[:space:]]|$)' "${FILES[@]}" | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#'; then fail "frappe-bench is installed without a version in the lines above"; fi

printf 'test-tool-pins: ok\n'
