#!/usr/bin/env bash
# Read-only, recursive discovery. Registration only remembers paths in CLI state;
# service setup remains the explicit `adopt` command.

FL_SCAN_BENCHES=()
FL_SCAN_WARNINGS=()
# Benches sit a few folders below a project folder; deeper trees are not walked.
FL_SCAN_MAX_DEPTH="${FL_SCAN_MAX_DEPTH:-6}"

fl_scan_walk() {
  local dir="$1" depth="${2:-0}" child name found=0
  if [[ ! -r "$dir" || ! -x "$dir" ]]; then
    FL_SCAN_WARNINGS+=("Cannot read folder: ${dir}")
    return 0
  fi
  case "$dir" in
    *$'\n'*|*$'\r'*) FL_SCAN_WARNINGS+=("Skipped a folder with a newline in its name."); return 0 ;;
  esac
  if fl_is_bench_dir "$dir"; then
    FL_SCAN_BENCHES+=("$dir")
    return 0
  fi
  if [[ "$depth" -ge "$FL_SCAN_MAX_DEPTH" ]]; then
    FL_SCAN_WARNINGS+=("Stopped at ${FL_SCAN_MAX_DEPTH} folders deep: ${dir}")
    return 0
  fi
  # Globs omit hidden directories. Never follow directory symlinks or descend
  # into a bench once found (apps may themselves contain example benches).
  # macOS media folders never hold benches and are huge or privacy
  # protected, so a scan of ~ or / does not walk them; nor the system
  # folders at / (Volumes, System, dev and the like).
  for child in "$dir"/*; do
    [[ -e "$child" || -L "$child" ]] && found=1
    [[ -d "$child" && ! -L "$child" ]] || continue
    name="${child##*/}"
    case "$name" in
      node_modules|env|venv|__pycache__|build|dist|vendor|tests|test|fixtures) continue ;;
      Library|Applications|Pictures|Music|Movies) continue ;;
    esac
    # system folders of the disk itself: only at /, so ~/dev is still scanned
    if [[ "$dir" == "/" || -z "$dir" ]]; then
      case "$name" in Volumes|System|private|cores|dev|usr|bin|sbin|opt) continue ;; esac
    fi
    fl_scan_walk "$child" $((depth + 1))
  done
  # A folder macOS privacy settings block passes -r and -x but lists as empty.
  if [[ "$found" == "0" ]] && ! ls "$dir" >/dev/null 2>&1; then
    FL_SCAN_WARNINGS+=("Cannot read folder: ${dir}")
  fi
  return 0
}

fl_cmd_scan() {
  local root="${1:-}" d sep="" warning
  [[ -n "$root" ]] || fl_die "Usage: benchbar scan PATH [--json]"
  root="$(fl_abs_path "$root")"
  [[ -d "$root" && -r "$root" && -x "$root" ]] || fl_die "${root} is not a readable folder."
  FL_SCAN_BENCHES=(); FL_SCAN_WARNINGS=()
  fl_scan_walk "$root"
  if [[ "$OPT_JSON" == "1" ]]; then
    fl_known_benches_prime
    printf '{"schema_version":%s,"cli_version":"%s","root":%s,"benches":[' \
      "$FL_SCHEMA_VERSION" "$FL_VERSION" "$(fl_json_str "$root")"
    for d in ${FL_SCAN_BENCHES[@]+"${FL_SCAN_BENCHES[@]}"}; do
      fl_bench_load "$d"
      printf '%s' "$sep"; fl_list_entry_json 0; sep=","
    done
    printf '],"warnings":['; sep=""
    for warning in ${FL_SCAN_WARNINGS[@]+"${FL_SCAN_WARNINGS[@]}"}; do
      printf '%s%s' "$sep" "$(fl_json_str "$warning")"; sep=","
    done
    printf ']}\n'
  else
    for d in ${FL_SCAN_BENCHES[@]+"${FL_SCAN_BENCHES[@]}"}; do printf '%s\n' "$d"; done
    for warning in ${FL_SCAN_WARNINGS[@]+"${FL_SCAN_WARNINGS[@]}"}; do fl_warn "$warning"; done
    fl_info "${#FL_SCAN_BENCHES[@]} bench(es) found. Add selected paths with: benchbar register PATH ..."
  fi
}

fl_registered_benches() {
  local d
  [[ -f "${FL_STATE_DIR}/registered-benches.txt" ]] || return 0
  while IFS= read -r d || [[ -n "$d" ]]; do printf '%s\n' "$d"; done <"${FL_STATE_DIR}/registered-benches.txt"
}

fl_cmd_register() {
  local d file="${FL_STATE_DIR}/registered-benches.txt" tmp paths=()
  [[ "$#" -gt 0 ]] || fl_die "Usage: benchbar register PATH ... [--json]"
  # Validate the entire selection before changing anything. Canonical paths
  # also collapse aliases and repeated scans of overlapping folders.
  for d in "$@"; do
    d="$(fl_abs_path "$d")"
    case "$d" in *$'\n'*|*$'\r'*) fl_die "Bench paths cannot contain newlines." ;; esac
    fl_is_bench_dir "$d" || fl_die "${d} is not a bench."
    paths+=("$d")
  done
  if [[ "${FL_DRY_RUN:-0}" != "1" ]]; then
    mkdir -p "$FL_STATE_DIR"
    tmp="$(mktemp "${FL_STATE_DIR}/registered.XXXXXX")"
    { fl_registered_benches; printf '%s\n' "${paths[@]}"; } | awk 'NF && !seen[$0]++' >"$tmp"
    if [[ -f "$file" ]] && cmp -s "$tmp" "$file"; then rm -f "$tmp"; else mv "$tmp" "$file"; fi
  fi
  if [[ "$OPT_JSON" == "1" ]]; then fl_cmd_list 1
  elif [[ "${FL_DRY_RUN:-0}" == "1" ]]; then fl_info "dry-run: would remember ${#paths[@]} selected path(s); no services are changed."
  else fl_info "Remembered ${#paths[@]} selected path(s); service setup: benchbar adopt PATH."
  fi
}
