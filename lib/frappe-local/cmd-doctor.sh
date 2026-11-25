#!/usr/bin/env bash
#
# cmd-doctor.sh: the bodies of "benchbar doctor" and "benchbar doctor --prerequisites".
# Moved out of the entry point as they were (CORE-18, issue 151): the entry point
# parses the command line and dispatches, a command's body lives in lib/frappe-local.
# The checks themselves are in checks.sh and doctor.sh. A lean start does not load this file.

# doctor --prerequisites: what a Mac needs before an install. No bench is
# needed (and none is looked for): --bench-dir names the folder a new bench
# would go to, ~/frappe-bench without it. Read only.
cmd_doctor_prerequisites() {
  FL_BENCH_DIR="$(fl_abs_path "${OPT_BENCH_DIR:-$HOME/frappe-bench}")"
  fl_prereq_run
  if [[ "$OPT_JSON" == "1" ]]; then
    fl_prereq_print_json
  else
    fl_prereq_print
    printf '\n  %s%d ok, %d warn, %d fail%s\n' "$FL_BOLD" "$(fl_prereq_count ok)" "$(fl_prereq_count warn)" "$(fl_prereq_count fail)" "$FL_RESET"
  fi
  [[ "$(fl_prereq_count fail)" == "0" ]]
}

cmd_doctor() {
  local fails labs_on
  if [[ "$OPT_PREREQ" == "1" ]]; then cmd_doctor_prerequisites; return; fi
  # --ack and --unack under --json: the document on fd 3, every line of text on stderr
  if [[ -n "$OPT_ACK$OPT_UNACK" && "$OPT_JSON" == "1" ]]; then fl_json_doc_begin; fi
  # --fix-hints: only the fix commands on stdout (fd 3), everything else,
  # a missing bench included, on stderr
  if [[ "$OPT_FIX_HINTS" == "1" ]]; then exec 3>&1 1>&2; FL_PLAIN=1; fl_ui_init; fi
  fl_context_init "$OPT_BENCH_DIR" "$OPT_SITE" "$OPT_PROFILE"
  fl_require_bench
  # doctor --unack CHECK: no report needed; under --json one small document
  if [[ -n "$OPT_UNACK" ]]; then fl_doctor_unack "$OPT_UNACK"; fl_doctor_ack_doc unack "$OPT_UNACK"; return 0; fi
  [[ "$OPT_QUICK" != "1" || -n "$OPT_ACK" ]] || FL_DOCTOR_QUICK=1
  # the prerequisites ride in doctor --json only (see below): they run beside the checks
  if [[ "$OPT_JSON" == "1" && "$OPT_FIX_HINTS" != "1" && -z "$OPT_ACK" ]]; then FL_DOCTOR_PREREQ=1; fi
  fl_doctor_run
  # doctor --ack CHECK: records the warning it is about, then stops
  if [[ -n "$OPT_ACK" ]]; then fl_doctor_ack "$OPT_ACK"; fl_doctor_ack_doc ack "$OPT_ACK"; return 0; fi
  fl_doctor_apply_acks
  # the prerequisites ride in doctor --json only: a plain doctor keeps its
  # promise of a fix line after every WARN and FAIL, and of exit 1 on a FAIL
  [[ "$OPT_JSON" != "1" || "$OPT_FIX_HINTS" == "1" || "$FL_P_RAN" == "1" ]] || fl_prereq_run
  if [[ "$OPT_FIX_HINTS" == "1" ]]; then
    fl_doctor_print_fix_hints >&3
  elif [[ "$OPT_JSON" == "1" ]]; then
    fl_doctor_print_json
  else
    fl_header "benchbar doctor" "read-only" "$(fl_profile_display)" "$FL_BENCH_DIR" "$FL_SITE"
    fl_doctor_print
    fl_lab_enabled_v labs_on
    fl_info "labs: ${labs_on:-none}"
    if [[ -n "$(fl_doctor_actions)" ]]; then
      printf '\n'
      fl_info "run '${FL_SELF} repair' to apply the fixes marked above (dry-run: add --dry-run)"
    fi
  fi
  fails="$(fl_doctor_count fail)"
  [[ "$fails" == "0" ]]
}
