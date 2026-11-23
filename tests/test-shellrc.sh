#!/usr/bin/env bash
# Marker block handling in shell rc files.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
. "$ROOT/lib/frappe-local/ui.sh"
. "$ROOT/lib/frappe-local/run.sh"
. "$ROOT/lib/frappe-local/templates.sh"
. "$ROOT/lib/frappe-local/state.sh"
. "$ROOT/lib/frappe-local/shellrc.sh"
# a TMPDIR of its own: the leftover check below lists benchbar-rc.* files,
# and the tests that run beside this one write theirs to the shared /tmp
TMPDIR="$TMP_DIR/tmp"; mkdir -p "$TMPDIR"; export TMPDIR

rc="$TMP_DIR/zshrc"
printf 'export A=1\n' >"$rc"
c1="$(fl_template_render shell-helpers "PROFILE_EXPORTS=export P=1" "BENCHBAR=/x/benchbar")"
c2="$(fl_template_render shell-helpers "PROFILE_EXPORTS=export P=2" "BENCHBAR=/x/benchbar")"

# a regression guard, not a 0.7.0 change: the block keeps ~/.local/bin on
# PATH even when Homebrew puts benchbar on PATH, since pipx and uv put
# bench there (which path a Homebrew CLI records is test-homebrew's)
# shellcheck disable=SC2016 # the block's own line, unexpanded
assert_contains "$c1" 'export PATH="$HOME/.local/bin:$PATH"'

assert_eq "missing" "$(fl_rc_block_status "$rc" "$c1")"
fl_rc_block_write "$rc" "$c1"
assert_eq "present" "$(fl_rc_block_state "$rc")"
assert_eq "current" "$(fl_rc_block_status "$rc" "$c1")"
assert_eq "outdated" "$(fl_rc_block_status "$rc" "$c2")"
assert_eq "1" "$(grep -c -x -F "$FL_RC_START" "$rc")"
grep -q '^export A=1$' "$rc" || fail "user content must survive"

# replace in place: still exactly one block, new content, user content intact
printf 'export Z=9\n' >>"$rc"
fl_rc_block_write "$rc" "$c2"
assert_eq "1" "$(grep -c -x -F "$FL_RC_START" "$rc")"
assert_eq "1" "$(grep -c -x -F "$FL_RC_END" "$rc")"
grep -q '^export P=2$' "$rc" || fail "block content must be replaced"
! grep -q '^export P=1$' "$rc" || fail "old block content must be gone"
grep -q '^export Z=9$' "$rc" || fail "content after the block must survive"
assert_eq "current" "$(fl_rc_block_status "$rc" "$c2")"
[[ -n "$(find "$FL_BACKUP_ROOT" -type f | awk 'NR==1')" ]] || fail "rc file must be backed up before a write"

# ---- a symlinked rc file (a dotfiles repo): the write lands in the target,
# the link stays a link, the target keeps its mode
real="$TMP_DIR/dotfiles/zshrc"; mkdir -p "$TMP_DIR/dotfiles"
printf 'export FROM_DOTFILES=1\n' >"$real"; chmod 0644 "$real"
link="$TMP_DIR/linked-zshrc"; ln -s "$real" "$link"
fl_rc_block_write "$link" "$c1"
[[ -L "$link" ]] || fail "the rc file must stay a symlink"
assert_eq "$real" "$(readlink "$link")"
grep -q -x -F "$FL_RC_START" "$real" || fail "the block must land in the symlink's target"
grep -q '^export FROM_DOTFILES=1$' "$real" || fail "the target's own content must survive"
mode() { if [[ "$STAT_GNU" == "1" ]]; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }
assert_eq "644" "$(mode "$real")" "(the target keeps its mode)"
fl_rc_block_write "$link" "$c2"
[[ -L "$link" ]] || fail "a replace must keep the symlink too"
assert_eq "current" "$(fl_rc_block_status "$link" "$c2")"
fl_rc_block_remove "$link"
[[ -L "$link" ]] || fail "a removal must keep the symlink"
assert_eq "missing" "$(fl_rc_block_state "$link")"
grep -q '^export FROM_DOTFILES=1$' "$real" || fail "the target's own content must survive the removal"

# ---- ZDOTDIR: zsh reads $ZDOTDIR/.zshrc (the file remembered by the writes above is cleared first)
fl_kv_del "$FL_STATE_FILE" RC_FILE
assert_eq "$TMP_DIR/zdot/.zshrc" "$(FL_RC_FILE='' ZDOTDIR="$TMP_DIR/zdot" SHELL=/bin/zsh fl_rc_file)"
assert_eq "$HOME/.zshrc" "$(FL_RC_FILE='' SHELL=/bin/zsh fl_rc_file)"

# ---- a stage that fails leaves the file byte-identical: awk that cannot run
printf 'export KEEP=1\n%s\nexport P=1\n%s\n' "$FL_RC_START" "$FL_RC_END" >"$rc"
before="$(cat "$rc")"
# shellcheck disable=SC2329  # called by fl_rc_block_write
awk() { return 1; }
set +e; fl_rc_block_write "$rc" "$c2" >/dev/null 2>&1; code=$?; set -e
assert_eq "1" "$code" "(a failed rewrite is a failure)"
assert_eq "$before" "$(cat "$rc")" "(a failed rewrite leaves the file as it was)"
set +e; fl_rc_block_remove "$rc" >/dev/null 2>&1; code=$?; set -e
unset -f awk
assert_eq "1" "$code" "(a failed removal is a failure)"
assert_eq "$before" "$(cat "$rc")" "(a failed removal leaves the file as it was)"

# ---- the last stage failing (the rename onto the target) leaves the file
# byte-identical too: no truncated rc file, nothing left next to it
chmod 600 "$rc"
# shellcheck disable=SC2329  # called by fl_rc_replace_file
mv() { return 1; }
set +e; fl_rc_block_write "$rc" "$c2" >/dev/null 2>&1; code=$?; set -e
unset -f mv
assert_eq "1" "$code" "(a failed rename is a failure)"
assert_eq "$before" "$(cat "$rc")" "(a failed rename leaves the file as it was)"
[[ -z "$(ls "$rc".* 2>/dev/null)" ]] || fail "no temp file may stay next to the rc file: $(ls "$rc".*)"
# a successful write keeps the file's mode
fl_rc_block_write "$rc" "$c2" >/dev/null
assert_eq "600" "$(stat -c %a "$rc" 2>/dev/null || stat -f %Lp "$rc")" "(the rc file keeps its mode)"
chmod 644 "$rc"

# ---- the rc file a block was written to is remembered: a run without the
# terminal's ZDOTDIR (the app, launchd) finds the same file
mkdir -p "$TMP_DIR/zdot"
ZDOTDIR="$TMP_DIR/zdot" FL_RC_FILE='' fl_rc_block_write "$(FL_RC_FILE='' ZDOTDIR="$TMP_DIR/zdot" SHELL=/bin/zsh fl_rc_file)" "$c2" >/dev/null
assert_eq "$TMP_DIR/zdot/.zshrc" "$(FL_RC_FILE='' SHELL=/bin/zsh fl_rc_file)" "(the remembered rc file wins over ~/.zshrc without ZDOTDIR)"
assert_eq "$TMP_DIR/zdot/.zshrc" "$(fl_state_get RC_FILE)"
rm -f "$TMP_DIR/zdot/.zshrc"
assert_eq "$HOME/.zshrc" "$(FL_RC_FILE='' SHELL=/bin/zsh fl_rc_file)" "(a remembered file that is gone is not used)"
fl_kv_del "$FL_STATE_FILE" RC_FILE
[[ -z "$(ls "${TMPDIR:-/tmp}"/benchbar-rc.* 2>/dev/null)" ]] || fail "no temp files may be left behind: $(ls "${TMPDIR:-/tmp}"/benchbar-rc.*)"

# the block is valid zsh and bash
fl_rc_block_extract "$rc" >"$TMP_DIR/block.sh"
bash -n "$TMP_DIR/block.sh"
command -v zsh >/dev/null 2>&1 && zsh -n "$TMP_DIR/block.sh"

# broken markers: append a fresh block and warn, never edit in place
printf 'export A=1\n%s\nbroken\n# <<< benchbar <\n' "$FL_RC_START" >"$rc"
assert_eq "broken" "$(fl_rc_block_state "$rc")"
out="$(fl_rc_block_write "$rc" "$c1")"
assert_contains "$out" "[WARN]"
grep -q '^broken$' "$rc" || fail "malformed block must be left alone"
assert_eq "2" "$(grep -c -x -F "$FL_RC_START" "$rc")"

# legacy blocks from older setups are reported
printf '# >>> frappe-bench helpers >>>\nbenchup() { :; }\n# <<< frappe-bench helpers <\n' >>"$rc"
assert_eq "frappe-bench helpers" "$(fl_rc_legacy_blocks "$rc")"
# the installer's PATH block is not a legacy block
printf '# >>> benchbar-path >>>\nexport PATH=x\n# <<< benchbar-path <<<\n' >>"$rc"
assert_eq "frappe-bench helpers" "$(fl_rc_legacy_blocks "$rc")" "(benchbar-path is not reported)"

# a frappe-mac block from before 0.3.0 is ours: outdated, and replaced in
# place with benchbar markers
printf 'export A=1\n# >>> frappe-mac >>>\nbenchup() { old; }\n# <<< frappe-mac <<<\nexport Z=9\n' >"$rc"
assert_eq "legacy" "$(fl_rc_block_state "$rc")"
assert_eq "outdated" "$(fl_rc_block_status "$rc" "$c1")"
assert_eq "" "$(fl_rc_legacy_blocks "$rc")" "(not reported as a foreign block)"
fl_rc_block_write "$rc" "$c1"
assert_eq "present" "$(fl_rc_block_state "$rc")"
assert_eq "current" "$(fl_rc_block_status "$rc" "$c1")"
assert_eq "0" "$(grep -c -F 'frappe-mac >>>' "$rc")"
assert_eq "export A=1" "$(head -n 1 "$rc")"
assert_eq "$FL_RC_START" "$(sed -n 2p "$rc")" "(new block where the old one was)"
assert_eq "export Z=9" "$(tail -n 1 "$rc")"
! grep -q 'old; }' "$rc" || fail "old block content must be gone"
# a stray frappe-mac block next to a benchbar block is reported
printf '# >>> frappe-mac >>>\nx\n# <<< frappe-mac <<<\n' >>"$rc"
assert_eq "frappe-mac" "$(fl_rc_legacy_blocks "$rc")"
# remove takes a legacy block too
printf 'export A=1\n# >>> frappe-mac >>>\nx\n# <<< frappe-mac <<<\n' >"$rc"
fl_rc_block_remove "$rc"
assert_eq "missing" "$(fl_rc_block_state "$rc")"

# remove
printf 'export A=1\n' >"$rc"
fl_rc_block_write "$rc" "$c1"
fl_rc_block_remove "$rc"
assert_eq "missing" "$(fl_rc_block_state "$rc")"
grep -q '^export A=1$' "$rc" || fail "user content must survive removal"

# dry-run writes nothing
printf 'export A=1\n' >"$rc"
FL_DRY_RUN=1 fl_rc_block_write "$rc" "$c1" >/dev/null
assert_eq "missing" "$(fl_rc_block_state "$rc")"

# ---- per shell (CORE-15): the file and the syntax follow the login shell
H="$TMP_DIR/home15"; mkdir -p "$H"
rcf() { HOME="$H" FL_RC_FILE='' ZDOTDIR='' XDG_CONFIG_HOME="${XDG:-}" FL_PLATFORM="${PLAT:-macos}" SHELL="$1" fl_rc_file; }
# shellcheck disable=SC2016,SC2329  # the block's own lines, unexpanded; called by fl_rc_helpers_render
fl_profile_path_exports() { printf 'export PATH="/brew/opt/python@3.11/bin:$PATH"\nexport PATH="$HOME/.local/bin:$PATH"\nexport LDFLAGS="-L/brew/lib -L/brew/opt/zlib/lib"\n'; }

# fish: a file of its own in conf.d, in fish syntax; nothing lands in ~/.zshrc
fish="$H/.config/fish/conf.d/benchbar.fish"
assert_eq "$fish" "$(rcf /opt/homebrew/bin/fish)"
assert_eq "$fish" "$(PLAT=linux rcf /usr/bin/fish)" "(fish on Linux too, not ~/.bashrc)"
assert_eq "$TMP_DIR/xdg/fish/conf.d/benchbar.fish" "$(XDG="$TMP_DIR/xdg" rcf /usr/local/bin/fish)"
fb="$(SHELL=/usr/local/bin/fish fl_rc_helpers_render v15-lts "/x/my cli/benchbar")"
# shellcheck disable=SC2016
{
  assert_contains "$fb" 'set -gx PATH "/brew/opt/python@3.11/bin" $PATH'
  assert_contains "$fb" 'set -gx PATH "$HOME/.local/bin" $PATH'
  assert_contains "$fb" 'set -gx LDFLAGS "-L/brew/lib -L/brew/opt/zlib/lib"'
  assert_contains "$fb" 'function benchup; command $BENCHBAR up $argv; end'
  assert_contains "$fb" 'function benchcd; cd (command $BENCHBAR path); end'
}
assert_not_contains "$fb" "benchup()" "(no POSIX function in a fish file)"
assert_not_contains "$fb" "export " "(no POSIX export in a fish file)"
got=""
fl_rc_block_write "$fish" "$fb" >/dev/null
assert_eq "current" "$(fl_rc_block_status "$fish" "$fb")" "(the block is written where fish reads it, folders made)"
fl_rc_recorded_cli_v got "$fish"
assert_eq "/x/my cli/benchbar" "$got" "(the CLI a fish block names is read back)"
[[ ! -e "$H/.zshrc" ]] || fail "a fish user gets no stray ~/.zshrc"
fl_rc_block_extract "$fish" >"$TMP_DIR/block.fish"
if command -v fish >/dev/null 2>&1; then fish -n "$TMP_DIR/block.fish" || fail "the fish block must parse"; fi
# zsh and bash keep the POSIX block, byte for byte
pb="$(SHELL=/bin/zsh fl_rc_helpers_render v15-lts /x/benchbar)"
assert_eq "$(fl_template_render shell-helpers "PROFILE_EXPORTS=$(fl_profile_path_exports)" "BENCHBAR=/x/benchbar")" "$pb"
fl_rc_recorded_cli_v got "$rc"; assert_eq "" "$got"

# nushell and the other shells that read neither file: no file at all
for sh in /opt/homebrew/bin/nu /usr/bin/xonsh /usr/bin/elvish /bin/tcsh /usr/local/bin/pwsh; do
  assert_eq "" "$(rcf "$sh")" "(no rc file for $sh)"
  assert_eq "other" "$(SHELL="$sh" fl_rc_shell)"
done
assert_contains "$(SHELL=/opt/homebrew/bin/nu FL_RC_FILE='' fl_rc_source_hint)" "nu reads no helper block"
assert_eq "source $fish" "$(HOME="$H" FL_RC_FILE='' XDG_CONFIG_HOME='' SHELL=/usr/bin/fish fl_rc_source_hint)"
# an unknown or missing SHELL is the platform's default, as before
assert_eq "$H/.zshrc" "$(rcf /bin/ksh)"
assert_eq "$H/.bashrc" "$(PLAT=linux rcf /bin/dash)"

# bash on a Mac: Terminal starts a login shell, which reads the first of
# .bash_profile, .bash_login and .profile and never ~/.bashrc by itself
assert_eq "$H/.bash_profile" "$(rcf /bin/bash)" "(no bash file yet)"
printf 'export FROM_BASHRC=1\n' >"$H/.bashrc"
assert_eq "$H/.bash_profile" "$(rcf /bin/bash)" "(a ~/.bashrc no login file reads is not where the block goes)"
printf 'export X=1\n' >"$H/.profile"
assert_eq "$H/.profile" "$(rcf /bin/bash)" "(the login file that exists, so no new .bash_profile hides it)"
printf '[ -f ~/.bashrc ] && . ~/.bashrc\n' >"$H/.bash_profile"
assert_eq "$H/.bashrc" "$(rcf /bin/bash)" "(a login file that reads ~/.bashrc: the block there reaches every bash)"
printf 'export Y=1\n' >"$H/.bash_profile"
assert_eq "$H/.bash_profile" "$(rcf /bin/bash)"
assert_eq "$H/.bashrc" "$(PLAT=linux rcf /bin/bash)" "(Linux terminals start a shell that is no login shell)"

# a symlink cycle ends in a refusal, not a hang
ln -s "$TMP_DIR/loop-b" "$TMP_DIR/loop-a"; ln -s "$TMP_DIR/loop-a" "$TMP_DIR/loop-b"
set +e; out="$(fl_rc_block_write "$TMP_DIR/loop-a" "$c1" 2>&1)"; code=$?; set -e
assert_eq "1" "$code" "(a symlink cycle is a failure: $out)"
assert_contains "$out" "symlinks that never end"
[[ -L "$TMP_DIR/loop-a" && -L "$TMP_DIR/loop-b" ]] || fail "the links of the cycle stay as they were"

# a read only rc file is the person's choice: refused, not replaced (root writes anyway)
if [[ "$(id -u)" != "0" ]]; then
  ro="$TMP_DIR/ro-rc"; printf 'export RO=1\n' >"$ro"; chmod 444 "$ro"
  set +e; out="$(fl_rc_block_write "$ro" "$c1" 2>&1)"; code=$?; set -e
  assert_eq "1" "$code" "(a read only rc file is refused: $out)"
  assert_contains "$out" "read only"
  assert_eq "export RO=1" "$(cat "$ro")" "(a read only rc file is as it was)"
  assert_eq "444" "$(mode "$ro")"
fi

# ---- through the CLI: service, doctor and repair for a fish user and a
# nushell user (FL_RC_FILE, the harness's fixed file, is cleared)
BENCH="$HOME/work/rc/frappe-bench"
make_fake_bench "$BENCH" macdev
printf '127.0.0.1 macdev\n' >>"$FL_HOSTS_FILE"
run_fm register "$BENCH"; assert_eq "0" "$CODE" "$OUT"
helpers_check() { printf '%s' "$OUT" | jget - "[c['$1'] for c in d['checks'] if c['id'] == 'helpers'][0]"; }
cli_fish="$HOME/.config/fish/conf.d/benchbar.fish"
FL_RC_FILE='' XDG_CONFIG_HOME='' SHELL=/usr/local/bin/fish run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "(service as a fish user: $OUT)"
grep -q '^function benchup; ' "$cli_fish" || fail "the service step writes the fish block to conf.d"
[[ ! -e "$HOME/.zshrc" ]] || ! grep -q -F "$FL_RC_START" "$HOME/.zshrc" || fail "a fish user gets no block in ~/.zshrc"
FL_RC_FILE='' XDG_CONFIG_HOME='' SHELL=/usr/local/bin/fish run_fm doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(helpers_check status)" "(doctor as a fish user: $(helpers_check message))"
assert_contains "$(helpers_check message)" "$cli_fish"
FL_RC_FILE='' SHELL=/opt/homebrew/bin/nu run_fm doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(helpers_check status)" "(doctor as a nushell user: $(helpers_check message))"
assert_contains "$(helpers_check message)" "no helper block: nu cannot read one"
FL_RC_FILE='' SHELL=/opt/homebrew/bin/nu run_fm repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "(repair as a nushell user: $OUT)"
[[ ! -e "$HOME/.zshrc" ]] || ! grep -q -F "$FL_RC_START" "$HOME/.zshrc" || fail "a nushell user gets no block in ~/.zshrc"

printf 'test-shellrc: ok\n'
