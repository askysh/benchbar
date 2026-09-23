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
fl_doctor_run() {
  local id groups="$*" g
  fl_doctor_reset
  for id in $FL_CHECK_ORDER; do
    g="$(fl_check_group "$id")"
    if [[ -n "$groups" ]]; then
      case " $groups " in *" $g "*) ;; *) continue ;; esac
    fi
    CHK_STATUS=""; CHK_MSG=""; CHK_FIX=""; CHK_ACTION=""
    "chk_${id}" || true
    FL_D_IDS+=("$id"); FL_D_STATUS+=("$CHK_STATUS"); FL_D_MSG+=("$CHK_MSG"); FL_D_FIX+=("$CHK_FIX"); FL_D_ACTION+=("$CHK_ACTION")
    fl_log "check ${id}: ${CHK_STATUS} ${CHK_MSG}"
  done
}

fl_doctor_count() {
  local want="$1" n=0 s
  for s in ${FL_D_STATUS[@]+"${FL_D_STATUS[@]}"}; do [[ "$s" == "$want" ]] && n=$((n + 1)); done
  printf '%d' "$n"
}

# fl_doctor_print [compact]: compact mode hides [OK] lines and empty groups.
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
      fail) fl_fail "${label}: ${FL_D_MSG[$i]}"; [[ -n "${FL_D_FIX[$i]}" ]] && fl_fix "${FL_D_FIX[$i]}" ;;
    esac
    i=$((i + 1))
  done
  printf '\n  %s%d ok, %d warn, %d fail%s\n' "$FL_BOLD" "$(fl_doctor_count ok)" "$(fl_doctor_count warn)" "$(fl_doctor_count fail)" "$FL_RESET"
}

fl_json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r\t'
}

# Schema 1 (docs/json-schema.md). "level" and "fix_command" are the contract
# names; "status" and "fix" are the frappe-mac 0.2.0 names, kept for older readers.
fl_doctor_print_json() {
  local i=0 sep=""
  printf '{"schema_version":%d,"cli_version":"%s","bench":"%s","name":"%s","site":"%s","profile":"%s","checks":[' \
    "${FL_SCHEMA_VERSION:-1}" "${FL_VERSION:-0}" "$(fl_json_escape "$FL_BENCH_DIR")" "$(fl_json_escape "$FL_BENCH_NAME")" \
    "$(fl_json_escape "$FL_SITE")" "$(fl_json_escape "$FL_PROFILE")"
  while [[ "$i" -lt "${#FL_D_IDS[@]}" ]]; do
    printf '%s{"id":"%s","group":"%s","label":"%s","level":"%s","message":"%s","fix_command":%s,"action":%s,"status":"%s","fix":"%s"}' \
      "$sep" "${FL_D_IDS[$i]}" "$(fl_check_group "${FL_D_IDS[$i]}")" "$(fl_json_escape "$(fl_check_label "${FL_D_IDS[$i]}")")" \
      "${FL_D_STATUS[$i]}" "$(fl_json_escape "${FL_D_MSG[$i]}")" "$(fl_json_str "${FL_D_FIX[$i]}")" "$(fl_json_str "${FL_D_ACTION[$i]}")" \
      "${FL_D_STATUS[$i]}" "$(fl_json_escape "${FL_D_FIX[$i]}")"
    sep=","
    i=$((i + 1))
  done
  printf '],"summary":{"ok":%d,"warn":%d,"fail":%d}}\n' "$(fl_doctor_count ok)" "$(fl_doctor_count warn)" "$(fl_doctor_count fail)"
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
