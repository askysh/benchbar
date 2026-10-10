#!/usr/bin/env bash
#
# doctor.sh: run checks, keep results, print them as text or JSON.
# Results live in parallel arrays (bash 3.2 has no associative arrays).

FL_D_IDS=()
FL_D_STATUS=()
FL_D_MSG=()
FL_D_FIX=()
FL_D_ACTION=()

fl_doctor_reset() { FL_D_IDS=(); FL_D_STATUS=(); FL_D_MSG=(); FL_D_FIX=(); FL_D_ACTION=(); }

# fl_doctor_run [GROUP...]: runs every check (or only the given groups).
CHK_MORE=()
fl_doctor_run() {
  local id groups="$*" g row
  fl_doctor_reset
  # a plan may add checks (port_block while ports move)
  for id in ${FL_PLAN_CHECKS:-} $FL_CHECK_ORDER; do
    g="$(fl_check_group "$id")"
    if [[ -n "$groups" ]]; then
      case " $groups " in *" $g "*) ;; *) continue ;; esac
    fi
    CHK_STATUS=""; CHK_MSG=""; CHK_FIX=""; CHK_ACTION=""; CHK_MORE=()
    "chk_${id}" || true
    # a check may report one row per finding instead (CHK_MORE, \037
    # separated status, message, fix, action), all under its id
    if [[ -n "$CHK_STATUS" || "${#CHK_MORE[@]}" == "0" ]]; then
      FL_D_IDS+=("$id"); FL_D_STATUS+=("$CHK_STATUS"); FL_D_MSG+=("$CHK_MSG"); FL_D_FIX+=("$CHK_FIX"); FL_D_ACTION+=("$CHK_ACTION")
      fl_log "check ${id}: ${CHK_STATUS} ${CHK_MSG}"
    fi
    for row in ${CHK_MORE[@]+"${CHK_MORE[@]}"}; do
      IFS=$'\037' read -r CHK_STATUS CHK_MSG CHK_FIX CHK_ACTION <<<"$row"
      FL_D_IDS+=("$id"); FL_D_STATUS+=("$CHK_STATUS"); FL_D_MSG+=("$CHK_MSG"); FL_D_FIX+=("$CHK_FIX"); FL_D_ACTION+=("$CHK_ACTION")
      fl_log "check ${id}: ${CHK_STATUS} ${CHK_MSG}"
    done
  done
}

fl_doctor_count() {
  local want="$1" n=0 s
  for s in ${FL_D_STATUS[@]+"${FL_D_STATUS[@]}"}; do [[ "$s" == "$want" ]] && n=$((n + 1)); done
  printf '%d' "$n"
}

# fl_doctor_print [compact]: compact mode hides [OK] lines and empty groups.
# A [FAIL] gets a "see:" line with its section of the doctor guide, after
# the fix line (the [OK], [WARN], [FAIL] and fix: lines stay as they were
# for parsers; --json never has it).
fl_doctor_print() {
  local compact="${1:-}" i=0 group last_group="" label
  while [[ "$i" -lt "${#FL_D_IDS[@]}" ]]; do
    group="$(fl_check_group "${FL_D_IDS[$i]}")"
    if [[ "$compact" == "compact" && "${FL_D_STATUS[$i]}" == "ok" ]]; then i=$((i + 1)); continue; fi
    if [[ "$group" != "$last_group" ]]; then
      printf '\n%s%s%s\n' "$FL_BOLD" "$(printf '%s' "$group" | tr '[:lower:]' '[:upper:]')" "$FL_RESET"
      last_group="$group"
    fi
    label="$(fl_check_label "${FL_D_IDS[$i]}")"
    case "${FL_D_STATUS[$i]}" in
      ok) fl_ok "${label}: ${FL_D_MSG[$i]}" ;;
      warn) fl_warn "${label}: ${FL_D_MSG[$i]}"; [[ -n "${FL_D_FIX[$i]}" ]] && fl_fix "${FL_D_FIX[$i]}" ;;
      fail) fl_fail "${label}: ${FL_D_MSG[$i]}"; [[ -n "${FL_D_FIX[$i]}" ]] && fl_fix "${FL_D_FIX[$i]}"
            fl_see "$(fl_docs_check_url "${FL_D_IDS[$i]}")" ;;
    esac
    i=$((i + 1))
  done
  printf '\n  %s%d ok, %d warn, %d fail%s\n' "$FL_BOLD" "$(fl_doctor_count ok)" "$(fl_doctor_count warn)" "$(fl_doctor_count fail)" "$FL_RESET"
}

# ---------------------------------------------------------------- prerequisites
#
# What a Mac needs before an install, without a bench (doctor --prerequisites,
# the BenchBar app's Check Your Mac page; docs/json-schema.md). The same list
# is the first group of a plain doctor and the "prerequisites" array of
# doctor --json; it is not counted in summary or in the exit code there.
# Parallel arrays like the checks above. FL_BENCH_DIR names the folder a
# new bench would go to; it does not have to exist.

FL_P_IDS=()
FL_P_LEVEL=()
FL_P_MSG=()
FL_P_FIX=()
FL_P_EXTRA=()
FL_P_RAN=0
# where Homebrew lives when it is not on PATH yet, and how to install it
FL_BREW_ALT_BIN="${FL_BREW_ALT_BIN:-/opt/homebrew/bin/brew}"
# shellcheck disable=SC2016  # the command is for a person to run
FL_BREW_INSTALL_CMD='/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
# free space (GB) from which the disk check is ok and from which it only warns
FL_PREREQ_DISK_OK_GB="${FL_PREREQ_DISK_OK_GB:-20}"
FL_PREREQ_DISK_WARN_GB="${FL_PREREQ_DISK_WARN_GB:-10}"

fl_prereq_label() {
  case "$1" in
    apple_silicon) printf 'Apple Silicon' ;;
    macos_version) printf 'macOS version' ;;
    command_line_tools) printf 'Command Line Tools' ;;
    homebrew) printf 'Homebrew' ;;
    disk_free) printf 'Free disk space' ;;
    bench_folder) printf 'Bench folder' ;;
    cleanmymac) printf 'CleanMyMac' ;;
    mole) printf 'Mole' ;;
    default_ports) printf 'Default ports' ;;
    *) printf '%s' "$1" ;;
  esac
}

# fl_prereq_add ID LEVEL MESSAGE [FIX [EXTRA_JSON]]
fl_prereq_add() {
  FL_P_IDS+=("$1"); FL_P_LEVEL+=("$2"); FL_P_MSG+=("$3"); FL_P_FIX+=("${4:-}"); FL_P_EXTRA+=("${5:-}")
  fl_log "prerequisite ${1}: ${2} ${3}"
}

fl_prereq_count() {
  local want="$1" n=0 l
  for l in ${FL_P_LEVEL[@]+"${FL_P_LEVEL[@]}"}; do [[ "$l" == "$want" ]] && n=$((n + 1)); done
  printf '%d' "$n"
}

# fl_prereq_run: fills FL_P_*. The target folder is FL_BENCH_DIR.
fl_prereq_run() {
  local arch os major clt kb gb level dir p offset conflicts brew_bin
  FL_P_IDS=(); FL_P_LEVEL=(); FL_P_MSG=(); FL_P_FIX=(); FL_P_EXTRA=(); FL_P_RAN=1

  # the Mac only checks stay out on Linux instead of reporting what cannot exist
  if ! fl_is_linux; then
    arch="${FL_ARCH:-$(uname -m)}"
    if [[ "$arch" == "arm64" ]]; then fl_prereq_add apple_silicon ok "arm64"
    else fl_prereq_add apple_silicon fail "this Mac is ${arch}; BenchBar and its Homebrew setup are for Apple Silicon"; fi

    os="$(sw_vers -productVersion 2>/dev/null || true)"; major="${os%%.*}"
    if [[ ! "$major" =~ ^[0-9]+$ ]]; then fl_prereq_add macos_version fail "could not read the macOS version"
    elif [[ "$major" -ge 14 ]]; then fl_prereq_add macos_version ok "macOS ${os}"
    else fl_prereq_add macos_version fail "macOS ${os}; macOS 14 or later is needed (System Settings, General, Software Update)"; fi

    clt="$(xcode-select -p 2>/dev/null || true)"
    if [[ -n "$clt" && -d "$clt" ]]; then fl_prereq_add command_line_tools ok "$clt"
    else fl_prereq_add command_line_tools fail "the Xcode Command Line Tools are not installed" "xcode-select --install"; fi

    brew_bin="$(command -v brew 2>/dev/null || true)"
    [[ -n "$brew_bin" ]] || { [[ -x "$FL_BREW_ALT_BIN" ]] && brew_bin="$FL_BREW_ALT_BIN"; }
    if [[ -n "$brew_bin" ]]; then fl_prereq_add homebrew ok "brew at ${brew_bin}"
    else fl_prereq_add homebrew fail "brew was not found" "$FL_BREW_INSTALL_CMD"; fi

  fi

  kb="$(df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  if [[ "$kb" =~ ^[0-9]+$ ]]; then
    gb=$((kb / 1024 / 1024))
    level=ok
    [[ "$gb" -ge "$FL_PREREQ_DISK_OK_GB" ]] || level=warn
    [[ "$gb" -ge "$FL_PREREQ_DISK_WARN_GB" ]] || level=fail
    fl_prereq_add disk_free "$level" "${gb} GB free" "" ",\"free_gb\":${gb}"
  else
    fl_prereq_add disk_free warn "could not read the free disk space" "" ",\"free_gb\":null"
  fi

  # the folder: a path benchbar can carry, and not in a place iCloud syncs
  dir="$FL_BENCH_DIR"
  if ! fl_bench_path_ok "$dir"; then
    fl_prereq_add bench_folder fail "${dir} contains ${FL_TEXT_PROBLEM}, which benchbar cannot carry as plain text; choose another folder, for example ~/frappe-bench"
  else
    level=ok; p=""
    case "$dir" in
      "$HOME/Library/Mobile Documents"|"$HOME/Library/Mobile Documents/"*|"$HOME/Library/CloudStorage/iCloud"*) level=fail; p="iCloud Drive" ;;
      "$HOME/Desktop"|"$HOME/Desktop/"*) level=warn; p="Desktop" ;;
      "$HOME/Documents"|"$HOME/Documents/"*) level=warn; p="Documents" ;;
    esac
    case "$level" in
      ok) fl_prereq_add bench_folder ok "$dir" ;;
      warn) fl_prereq_add bench_folder warn "${dir} is in ${p}, which iCloud can sync and evict from; choose a folder outside it, for example ~/frappe-bench" ;;
      *) fl_prereq_add bench_folder fail "${dir} is in ${p}, whose files are evicted to the cloud and break a bench; choose a folder outside it, for example ~/frappe-bench" ;;
    esac
  fi

  if ! fl_is_linux; then
    # CleanMyMac and Mole: doctor's own checks, for this folder
    CHK_STATUS=""; CHK_MSG=""; CHK_FIX=""; chk_cleanmymac
    fl_prereq_add cleanmymac "$CHK_STATUS" "$CHK_MSG" "$CHK_FIX"
    CHK_STATUS=""; CHK_MSG=""; CHK_FIX=""; chk_mole
    fl_prereq_add mole "$CHK_STATUS" "$CHK_MSG" "$CHK_FIX"
  fi

  # the default block 0: ports 8000, 9000, 11000 and 13000
  conflicts="$(fl_port_block_conflicts 0)"
  if [[ -z "$conflicts" ]]; then
    fl_prereq_add default_ports ok "ports 8000, 9000, 11000 and 13000 are free" "" ",\"port_offset\":0"
  elif offset="$(fl_port_next_free_offset)"; then
    fl_prereq_add default_ports warn "$(printf '%s' "$conflicts" | tr '\n' ';' | sed 's/;$//; s/;/; /g'); a new bench gets port block ${offset}" "" ",\"port_offset\":${offset}"
  else
    fl_prereq_add default_ports warn "$(printf '%s' "$conflicts" | tr '\n' ';' | sed 's/;$//; s/;/; /g'); no port block up to ${FL_PORT_MAX_OFFSET} is free" "" ",\"port_offset\":null"
  fi
}

# fl_prereq_print: the group, in the shape of doctor's own
fl_prereq_print() {
  local i=0
  printf '\n%sPREREQUISITES%s\n' "$FL_BOLD" "$FL_RESET"
  while [[ "$i" -lt "${#FL_P_IDS[@]}" ]]; do
    case "${FL_P_LEVEL[$i]}" in
      ok) fl_ok "$(fl_prereq_label "${FL_P_IDS[$i]}"): ${FL_P_MSG[$i]}" ;;
      warn) fl_warn "$(fl_prereq_label "${FL_P_IDS[$i]}"): ${FL_P_MSG[$i]}"; [[ -z "${FL_P_FIX[$i]}" ]] || fl_fix "${FL_P_FIX[$i]}" ;;
      *) fl_fail "$(fl_prereq_label "${FL_P_IDS[$i]}"): ${FL_P_MSG[$i]}"; [[ -z "${FL_P_FIX[$i]}" ]] || fl_fix "${FL_P_FIX[$i]}" ;;
    esac
    i=$((i + 1))
  done
}

# fl_prereq_json_v VAR: the array of checks, [{...},...]
fl_prereq_json_v() {
  local __out="[" __sep="" __i=0 __m __f
  while [[ "$__i" -lt "${#FL_P_IDS[@]}" ]]; do
    fl_json_str_v __m "${FL_P_MSG[$__i]}"; fl_json_str_v __f "${FL_P_FIX[$__i]}"
    __out="${__out}${__sep}{\"id\":\"${FL_P_IDS[$__i]}\",\"label\":$(fl_json_str "$(fl_prereq_label "${FL_P_IDS[$__i]}")"),\"level\":\"${FL_P_LEVEL[$__i]}\",\"message\":${__m},\"fix_command\":${__f}${FL_P_EXTRA[$__i]}}"
    __sep=","; __i=$((__i + 1))
  done
  printf -v "$1" '%s]' "$__out"
}

# doctor --prerequisites --json: its own document
fl_prereq_print_json() {
  local arr
  fl_prereq_json_v arr
  printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"prerequisites":%s,"summary":{"ok":%d,"warn":%d,"fail":%d}}\n' \
    "${FL_SCHEMA_VERSION:-1}" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$arr" \
    "$(fl_prereq_count ok)" "$(fl_prereq_count warn)" "$(fl_prereq_count fail)"
}

# Schema 1 (docs/json-schema.md). "level" and "fix_command" are the contract
# names; "status" and "fix" are the frappe-mac 0.2.0 names, kept for older readers.
fl_doctor_print_json() {
  local i=0 sep=""
  printf '{"schema_version":%d,"cli_version":"%s","bench":"%s","name":"%s","site":"%s","profile":"%s","profile_source":"%s","checks":[' \
    "${FL_SCHEMA_VERSION:-1}" "${FL_VERSION:-0}" "$(fl_json_escape "$FL_BENCH_DIR")" "$(fl_json_escape "$FL_BENCH_NAME")" \
    "$(fl_json_escape "$FL_SITE")" "$(fl_json_escape "$FL_PROFILE")" "$(fl_doctor_profile_source)"
  while [[ "$i" -lt "${#FL_D_IDS[@]}" ]]; do
    printf '%s{"id":"%s","group":"%s","label":"%s","level":"%s","message":"%s","fix_command":%s,"action":%s,"status":"%s","fix":"%s"}' \
      "$sep" "${FL_D_IDS[$i]}" "$(fl_check_group "${FL_D_IDS[$i]}")" "$(fl_json_escape "$(fl_check_label "${FL_D_IDS[$i]}")")" \
      "${FL_D_STATUS[$i]}" "$(fl_json_escape "${FL_D_MSG[$i]}")" "$(fl_json_str "${FL_D_FIX[$i]}")" "$(fl_json_str "${FL_D_ACTION[$i]}")" \
      "${FL_D_STATUS[$i]}" "$(fl_json_escape "${FL_D_FIX[$i]}")"
    sep=","
    i=$((i + 1))
  done
  # the prerequisites of this Mac, next to the checks and not counted in the summary
  if [[ "$FL_P_RAN" == "1" ]]; then
    local prereq
    fl_prereq_json_v prereq
    printf '],"prerequisites":%s,"summary":{"ok":%d,"warn":%d,"fail":%d}}\n' "$prereq" "$(fl_doctor_count ok)" "$(fl_doctor_count warn)" "$(fl_doctor_count fail)"
  else
    printf '],"summary":{"ok":%d,"warn":%d,"fail":%d}}\n' "$(fl_doctor_count ok)" "$(fl_doctor_count warn)" "$(fl_doctor_count fail)"
  fi
}

# doctor --fix-hints: the fix command of every failing and warning check,
# failures first, one per line, each once. For agents and scripts.
fl_doctor_print_fix_hints() {
  local want i
  for want in fail warn; do
    i=0
    while [[ "$i" -lt "${#FL_D_IDS[@]}" ]]; do
      if [[ "${FL_D_STATUS[$i]}" == "$want" && -n "${FL_D_FIX[$i]}" ]]; then printf '%s\n' "${FL_D_FIX[$i]}"; fi
      i=$((i + 1))
    done
  done | awk '!seen[$0]++'
}

# fl_profile_display: the profile for a header, with its source when it is
# only the default ("v15-lts (default: no profile matches this bench)")
# fl_doctor_profile_source: where the profile came from, for doctor --json
# (flag, team, stored, detected or default; default means no profile matched)
fl_doctor_profile_source() {
  printf '%s' "${FL_PROFILE_SOURCE:-default}"
}

fl_profile_display() {
  # a fresh install has no bench to match yet: its default is the choice, not a guess
  if fl_profile_is_guess; then printf '%s (default: no profile matches this bench)' "$FL_PROFILE"; else printf '%s' "$FL_PROFILE"; fi
}

# Prints the distinct repair actions of flagged checks, in dependency order.
fl_doctor_actions() {
  local a i flagged=""
  i=0
  while [[ "$i" -lt "${#FL_D_IDS[@]}" ]]; do
    if [[ "${FL_D_STATUS[$i]}" != "ok" && -n "${FL_D_ACTION[$i]}" ]]; then
      flagged="${flagged} ${FL_D_ACTION[$i]}"
    fi
    i=$((i + 1))
  done
  for a in $FL_ACTION_ORDER; do
    case " $flagged " in *" $a "*) printf '%s\n' "$a" ;; esac
  done
}

fl_doctor_checks_for_action() {
  local action="$1" i=0
  while [[ "$i" -lt "${#FL_D_IDS[@]}" ]]; do
    [[ "${FL_D_ACTION[$i]}" == "$action" && "${FL_D_STATUS[$i]}" != "ok" ]] && printf '%s\n' "$(fl_check_label "${FL_D_IDS[$i]}")"
    i=$((i + 1))
  done
}
