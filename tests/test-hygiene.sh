#!/usr/bin/env bash
# Secret and input hygiene: the sudo credential is dropped before any third
# party code runs (F37), the wkhtmltopdf package is hashed and installed from a
# root owned copy (F38), the passwords from the environment never reach a
# child process other than the one that needs them (F39), confirmations come
# from flags, not from the environment (F17), and the Keychain item is written
# through "security -i" with an explicit trusted application (F43).
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

add_proc 900 "mariadbd --datadir=/x"
add_proc 901 "redis-server *:6379"
printf 'mariadb@10.11 started akash file\nredis started akash file\n' >"$MOCK_BREW_SERVICES"
run00() { set +e; OUT="$("$ROOT/00-mac-system-deps.sh" "$@" 2>&1)"; CODE=$?; set -e; }
run01() { set +e; OUT="$("$ROOT/01-install-bench-and-site.sh" "$@" 2>&1)"; CODE=$?; set -e; }
# probe_result NAME: every "sudo -n true" result a mock recorded (ok or denied), one per line
probe_result() { cat "$MOCK_STATE/sudo_probe/$1" 2>/dev/null || true; }
# leaked NAME: the password variables a mock saw in its environment
leaked() { grep -E '^(MARIADB_ROOT_PASSWORD|ADMIN_PASSWORD)=' "$MOCK_STATE/env/$1" 2>/dev/null || true; }
BENCH="$HOME/frappe-bench"

# ---- F17: FL_ASSUME_YES from the environment is not --yes
mkdir -p "$MOCK_STATE/keychain"; printf 'kc-secret-1\n' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
FL_ASSUME_YES=1 run_fm mariadb-password </dev/null
assert_eq "1" "$CODE" "$OUT"
assert_not_contains "$OUT" "kc-secret-1" "(the environment must not print the password)"
assert_not_contains "$OUT" "--yes" "(no failure text tells an agent to pass --yes)"
assert_contains "$OUT" "terminal"
run_fm_tty mariadb-password --yes
assert_eq "0" "$CODE" "$OUT"; assert_eq "kc-secret-1" "$OUT"
# FL_MAKE_DEFAULT from the environment does not move the default bench
A="$HOME/dev/bench-a"; B="$HOME/dev/bench-b"
make_fake_bench "$A" sitea; make_fake_bench "$B" siteb
run_fm adopt "$A" --yes
assert_eq "0" "$CODE" "$OUT"
FL_MAKE_DEFAULT=1 run_fm adopt "$B" --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "the default bench stays ${A}"
assert_eq "$A" "$(sed -n 's/^BENCH_DIR=//p' "$FL_STATE_FILE")"
run_fm adopt "$B" --yes --make-default
assert_eq "0" "$CODE" "$OUT"
assert_eq "$B" "$(sed -n 's/^BENCH_DIR=//p' "$FL_STATE_FILE")"
rm -rf "$A" "$B"; : >"$FL_STATE_FILE"
rm -f "$HOME"/Library/LaunchAgents/com.benchbar.*.plist

# ---- F37, F38, F39: benchbar install on a fresh machine
rm -f "$MOCK_STATE/keychain/benchbar-mariadb--root" "$MOCK_STATE/sudo_cred"
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
touch "$MOCK_STATE/wkhtml_missing"; rm -f "$MOCK_STATE/wkhtml_installed"
printf '127.0.0.1 localhost\n' >"$FL_HOSTS_FILE"
reset_calls; rm -rf "$MOCK_STATE/sudo_probe" "$MOCK_STATE/env"
MOCK_SUDO_PROBE=1 MOCK_ENV_DUMP=1 MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw \
  run_fm install --yes --bench-dir "$BENCH" --site macdev
assert_eq "0" "$CODE" "$OUT"
# F37: one sudo prompt, the two privileged steps, then the credential is gone
assert_eq "1" "$(grep -c '^sudo -v$' "$MOCK_LOG")" "(one sudo prompt for the whole run)"
assert_calls_contain '^sudo -k$'
grep -q '^127.0.0.1 macdev$' "$FL_HOSTS_FILE" || fail "the hosts line is written up front"
assert_file "$MOCK_STATE/wkhtml_installed"
# everything that ran afterwards found no cached sudo credential
for m in yarn brew bench; do
  [[ -n "$(probe_result "$m")" ]] || fail "the ${m} mock must have run and probed sudo"
  assert_not_contains "$(probe_result "$m")" "ok" "(${m} ran while the sudo credential was still cached)"
done
# the order on the record: between sudo -v and sudo -k only the two privileged steps ran
between="$(sed -n '/^sudo -v$/,/^sudo -k$/p' "$MOCK_LOG")"
assert_contains "$between" "sudo installer -pkg"
assert_contains "$between" "sudo tee -a"
! grep -q -E '^(brew|yarn|npm|pipx|uv|bench|git) ' <<<"$between" || fail "third party code ran while the sudo credential was live:"$'\n'"$between"
# phase 00 found the package in place and did not download or install again
assert_eq "1" "$(grep -c '^curl .*wkhtmltox' "$MOCK_LOG")" "(one download)"
assert_eq "1" "$(grep -c '^sudo installer ' "$MOCK_LOG")" "(one install)"
assert_contains "$OUT" "[OK] wkhtmltopdf patched Qt build"
# F38: the package is copied into a root owned folder under /tmp, hashed there as root, installed from there
assert_calls_contain '^sudo mktemp -d /tmp/benchbar-wkhtmltopdf\.'
assert_calls_contain '^sudo install -m 0644 -o root .*/downloads/wkhtmltox-0.12.6-2.macos-cocoa.pkg /tmp/benchbar-wkhtmltopdf\.'
assert_calls_contain '^sudo shasum -a 256 /tmp/benchbar-wkhtmltopdf\..*/wkhtmltox-0.12.6-2.macos-cocoa.pkg$'
assert_calls_contain '^sudo installer -pkg /tmp/benchbar-wkhtmltopdf\..*/wkhtmltox-0.12.6-2.macos-cocoa.pkg -target /$'
assert_calls_not_contain '^sudo installer -pkg .*/downloads/' "(never install the user writable copy)"
assert_calls_contain '^sudo rm -rf /tmp/benchbar-wkhtmltopdf\.'
assert_calls_not_contain '^sudo rm -rf [^/]' "(sudo rm only on the fresh temp folder)"
[[ -z "$(ls -d /tmp/benchbar-wkhtmltopdf.* 2>/dev/null)" ]] || fail "the root temp folder is removed afterwards"
assert_contains "$OUT" "sha256 ok"
assert_file "$FL_STATE_DIR/downloads/wkhtmltox-0.12.6-2.macos-cocoa.pkg" "(the download cache stays)"
# INST-6: sudo runs its tools by absolute path, not by a bare name that the user's PATH decides
assert_file "$MOCK_STATE/sudo_argv0" "(the sudo mock records how each tool was named)"
for tool in /usr/bin/mktemp /usr/bin/install /usr/bin/shasum /usr/sbin/installer /bin/rm /usr/bin/tee; do
  grep -q -x "abs ${tool}" "$MOCK_STATE/sudo_argv0" || fail "sudo ran ${tool} by a bare name: $(cat "$MOCK_STATE/sudo_argv0")"
done
! grep -q -E '^bare (mktemp|install|shasum|installer|rm|tee|awk|env|chmod|mv) ' "$MOCK_STATE/sudo_argv0" || fail "sudo ran a tool by its bare name: $(cat "$MOCK_STATE/sudo_argv0")"
# the files sudo reads and writes do not come from the environment either (only the tests' FL_TESTING=1)
# shellcheck disable=SC2016  # the bash -c script is quoted on purpose
got="$(env -u FL_TESTING FL_HOSTS_FILE=/tmp/evil-hosts FL_WKHTML_PKG_BIN=/tmp/evil-bin FL_WKHTML_DOWNLOAD_DIR=/tmp/evil-dl SCRIPT_DIR="$ROOT" bash -c '
  . "$SCRIPT_DIR/lib/frappe-local/ui.sh"; . "$SCRIPT_DIR/lib/frappe-local/run.sh"; . "$SCRIPT_DIR/lib/frappe-local/checks.sh"; . "$SCRIPT_DIR/lib/frappe-local/wkhtmltopdf.sh"
  printf "%s %s %s" "$FL_HOSTS_FILE" "$FL_WKHTML_PKG_BIN" "$FL_WKHTML_DOWNLOAD_DIR"' 2>/dev/null || true)"
assert_eq "/etc/hosts /usr/local/bin/wkhtmltopdf ${FL_STATE_DIR}/downloads" "$got" "(env overrides of what sudo touches are ignored)"
# INST-6, the sudo program itself: on macOS "sudo" is a function that runs /usr/bin/sudo, so a
# sudo planted in a PATH folder the user can write is never found. Outside the tests (no
# FL_TESTING) neither the PATH nor FL_SUDO_BIN can change which program runs. The planted
# one only writes a marker, and it runs below only in the case that names it on purpose.
PLANT="$TMP_DIR/planted-bin"; mkdir -p "$PLANT"
printf '#!/bin/bash\necho planted >"%s/planted-sudo-ran"\necho planted-sudo\n' "$TMP_DIR" >"$PLANT/sudo"
chmod +x "$PLANT/sudo"
# shellcheck disable=SC2016  # the bash -c script is quoted on purpose
plant_probe() { env "$@" PATH="$PLANT:$PATH" FL_PLATFORM=macos SCRIPT_DIR="$ROOT" bash -c '
  . "$SCRIPT_DIR/lib/frappe-local/sudo.sh"
  [[ "$(type -t sudo)" == function ]] || { echo "sudo is not a function"; exit 3; }
  printf "%s" "$FL_SUDO_BIN"' 2>&1; }
got="$(plant_probe -u FL_TESTING FL_SUDO_BIN="$PLANT/sudo")"
assert_eq "/usr/bin/sudo" "$got" "(outside the tests FL_SUDO_BIN is ignored)"
[[ ! -e "$TMP_DIR/planted-sudo-ran" ]] || fail "the planted sudo ran"
# a call goes to /usr/bin/sudo (-V prints the version and asks for nothing), never to the planted one
# shellcheck disable=SC2016
got="$(env -u FL_TESTING -u FL_SUDO_BIN PATH="$PLANT:$PATH" FL_PLATFORM=macos SCRIPT_DIR="$ROOT" bash -c '. "$SCRIPT_DIR/lib/frappe-local/sudo.sh"; sudo -V' 2>&1 | head -1)"
assert_not_contains "$got" "planted-sudo"
[[ ! -e "$TMP_DIR/planted-sudo-ran" ]] || fail "the planted sudo ran for a call of sudo"
# a test names its own program (the mock) on purpose
got="$(plant_probe FL_TESTING=1 FL_SUDO_BIN="$PLANT/sudo")"
assert_eq "$PLANT/sudo" "$got" "(FL_TESTING=1 lets a test name the sudo program)"
# Linux keeps the PATH lookup (Ubuntu's sudo has a secure_path)
# shellcheck disable=SC2016
got="$(env -u FL_TESTING FL_PLATFORM=linux SCRIPT_DIR="$ROOT" bash -c '. "$SCRIPT_DIR/lib/frappe-local/sudo.sh"; type -t sudo || true' 2>&1)"
assert_not_contains "$got" "function"
# F39: no third party child saw the passwords, yet the site was created with them
for m in yarn brew bench; do
  assert_file "$MOCK_STATE/env/$m" "(the ${m} mock must have run)"
  assert_eq "" "$(leaked "$m")" "(${m} saw a password variable)"
done
assert_calls_contain '^bench new-site macdev --mariadb-root-password @secret0@ --admin-password @secret1@'
assert_eq "rootpw adminpw" "$(tr '\n' ' ' <"$MOCK_STATE/stdin-new-site" | sed 's/ $//')"
assert_eq "rootpw" "$(keychain_get)"
assert_not_contains "$OUT" "adminpw"; assert_not_contains "$(cat "$MOCK_LOG")" "adminpw"

# second run: unchanged, no sudo at all
reset_calls; rm -rf "$MOCK_STATE/sudo_probe" "$MOCK_STATE/env"
MOCK_SUDO_PROBE=1 MOCK_ENV_DUMP=1 run_fm install --yes --bench-dir "$BENCH" --site macdev
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "unchanged: all"
assert_calls_not_contain '^sudo '
assert_eq "" "$(leaked bench)"

# ---- F38 dry-run: the plan names the root owned copy, nothing runs
rm -f "$MOCK_STATE/wkhtml_installed"; reset_calls
run00 --dry-run --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^sudo '
rm -rf "$FL_STATE_DIR/downloads"
run_fm install --dry-run --yes --bench-dir "$BENCH" --site macdev
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "dry-run: sudo mktemp -d /tmp/benchbar-wkhtmltopdf.XXXXXX"
assert_contains "$OUT" "dry-run: sudo install -m 0644 -o root"
assert_contains "$OUT" "dry-run: sudo shasum -a 256"
assert_contains "$OUT" "dry-run: sudo installer -pkg"
assert_calls_not_contain '^sudo '
touch "$MOCK_STATE/wkhtml_installed"

# ---- F37: 00 run on its own still asks for sudo itself, and drops it after the PDF step
rm -f "$MOCK_STATE/wkhtml_installed" "$MOCK_STATE/sudo_cred"; rm -rf "$FL_STATE_DIR/downloads"
reset_calls; rm -rf "$MOCK_STATE/sudo_probe"
MOCK_SUDO_PROBE=1 run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^sudo -v$'
assert_calls_contain '^sudo installer -pkg /tmp/benchbar-wkhtmltopdf\.'
assert_calls_contain '^sudo -k$'
# brew runs after the PDF step (build deps): no cached credential by then
assert_not_contains "$(probe_result brew)" "ok" "(brew ran while the sudo credential was still cached)"
assert_no_file "$MOCK_STATE/sudo_cred"
# a 00 run that needs no sudo never touches it
reset_calls
run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^sudo '

# ---- F39: 01 run directly with the passwords in the environment
rm -rf "$BENCH" "$MOCK_STATE/env"; : >"$FL_STATE_FILE"
reset_calls
MOCK_ENV_DUMP=1 MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run01 --yes --offline
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain "^bench new-site macdev"
assert_eq "rootpw adminpw" "$(tr '\n' ' ' <"$MOCK_STATE/stdin-new-site" | sed 's/ $//')"
assert_file "$MOCK_STATE/env/bench" "(the bench mock must have run)"
assert_eq "" "$(leaked bench)" "(bench saw a password variable)"
# and 00 with the root password in the environment: brew never sees it
rm -rf "$MOCK_STATE/env"
MOCK_ENV_DUMP=1 MARIADB_ROOT_PASSWORD=rootpw run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "verified (from MARIADB_ROOT_PASSWORD)"
assert_eq "" "$(leaked brew)" "(brew saw the root password)"
assert_eq "" "$(leaked yarn)" "(yarn saw the root password)"

# ---- F43: the Keychain item is written through "security -i", the password never on argv,
# with /usr/bin/security as the one trusted application; a hard password round trips
tricky='a b"c\d'"'"'e'
rm -f "$MOCK_STATE/keychain/benchbar-mariadb--root"
printf '%s' "$tricky" >"$MOCK_STATE/mariadb_root_pw"
reset_calls
MARIADB_ROOT_PASSWORD="$tricky" run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "saved to the Keychain"
assert_eq "$tricky" "$(keychain_get)" "(the stored value must be exactly the password)"
assert_calls_contain '^security -i$'
assert_calls_not_contain '^security add-generic-password' "(the add command goes through stdin, not argv)"
assert_not_contains "$(cat "$MOCK_LOG")" 'c\d' "(no part of the password on a command line)"
grep -q -- '-T /usr/bin/security' "$MOCK_STATE/keychain/benchbar-mariadb--root.cmd" || fail "the item names /usr/bin/security as its trusted application"
grep -q -- ' -U ' "$MOCK_STATE/keychain/benchbar-mariadb--root.cmd" || fail "the item is updated in place (-U)"
run_fm_tty mariadb-password --yes
assert_eq "0" "$CODE" "$OUT"; assert_eq "$tricky" "$OUT"
# a second run finds the same value and writes nothing
reset_calls
MARIADB_ROOT_PASSWORD="$tricky" run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^security -i$'
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"

printf 'test-hygiene: ok\n'
