#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# report.sh: "benchbar report", a redacted diagnostics bundle for bug reports.
#
#   benchbar report                 writes ~/Desktop/benchbar-report-<stamp>.zip
#   benchbar report --print         prints the same contents to the terminal
#   benchbar report --out DIR       writes the zip into DIR instead
#
# Contents: doctor and status as JSON, versions of everything involved,
# the launchd agent (launchctl print and the plist), Procfile.lean,
# state.json, the last 200 lines of bench.log and worker.error.log, and the
# key names (never the values) of the site config files.
#
# Redaction, applied to every file before it is packed:
#   - site_config.json and common_site_config.json are never copied; only
#     their key names are listed
#   - any value whose key matches password, secret, token, key, api or auth
#     is replaced by ***
#   - $HOME becomes ~, the username <user>, and every name of this Mac
#     (hostname, Bonjour name, computer name) <host>
#   - REDACTIONS.txt inside the bundle lists what was replaced

FL_REPORT_TAIL_LINES="${FL_REPORT_TAIL_LINES:-200}"
FL_REPORT_KEY_RE='[A-Za-z0-9_.-]*[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd][A-Za-z0-9_.-]*|[A-Za-z0-9_.-]*[Ss][Ee][Cc][Rr][Ee][Tt][A-Za-z0-9_.-]*|[A-Za-z0-9_.-]*[Tt][Oo][Kk][Ee][Nn][A-Za-z0-9_.-]*|[A-Za-z0-9_.-]*[Kk][Ee][Yy][A-Za-z0-9_.-]*|[A-Za-z0-9_.-]*[Aa][Pp][Ii][A-Za-z0-9_.-]*|[A-Za-z0-9_.-]*[Aa][Uu][Tt][Hh][A-Za-z0-9_.-]*'
FL_REPORT_DIR=""
FL_REPORT_REDACTIONS=""

fl_report_default_out() { printf '%s/Desktop' "$HOME"; }

# fl_report_note FILE TEXT: appends a "not available" style note to FILE
fl_report_note() { printf '%s\n' "$2" >>"${FL_REPORT_DIR}/$1"; }

# fl_report_cmd FILE LABEL COMMAND...: runs COMMAND and stores its output
# (stdout and stderr) under a heading. A missing command is recorded, never fatal.
fl_report_cmd() {
  local file="$1" label="$2"
  shift 2
  {
    printf '## %s\n' "$label"
    if command -v "$1" >/dev/null 2>&1 || [[ -x "$1" ]]; then
      "$@" 2>&1 || printf '(exit code %s)\n' "$?"
    else
      printf '(not installed: %s)\n' "$1"
    fi
    printf '\n'
  } >>"${FL_REPORT_DIR}/${file}" 2>&1
}

# fl_report_copy SRC DEST_NAME: copies a file into the bundle, or notes its absence
fl_report_copy() {
  local src="$1" name="$2"
  if [[ -f "$src" ]]; then
    cp "$src" "${FL_REPORT_DIR}/${name}"
  else
    printf '(missing: %s)\n' "$src" >"${FL_REPORT_DIR}/${name}"
  fi
}

# fl_report_tail SRC DEST_NAME: the last FL_REPORT_TAIL_LINES lines of a log
fl_report_tail() {
  local src="$1" name="$2"
  if [[ -f "$src" ]]; then
    { printf '## last %s lines of %s\n' "$FL_REPORT_TAIL_LINES" "$src"; tail -n "$FL_REPORT_TAIL_LINES" "$src"; } >"${FL_REPORT_DIR}/${name}"
  else
    printf '(missing: %s)\n' "$src" >"${FL_REPORT_DIR}/${name}"
  fi
}

# Prints the top level key names of a flat JSON object, one per line.
fl_json_key_names() {
  sed -n 's/^[[:space:]]*"\([^"]*\)"[[:space:]]*:.*/\1/p' "$1" | sort -u
}

fl_app_version() {
  # fl_app_version APP: __version__ of apps/APP/APP/__init__.py, or "not installed"
  local init="${FL_BENCH_DIR}/apps/$1/$1/__init__.py" v
  [[ -f "$init" ]] || { printf 'not installed'; return 0; }
  v="$(sed -n 's/^__version__[[:space:]]*=[[:space:]]*["'"'"']\([^"'"'"']*\)["'"'"'].*/\1/p' "$init" | head -n1)"
  printf '%s' "${v:-unknown}"
}

# Version of the installed BenchBar app, read from its Info.plist without plutil.
fl_app_bundle_version() {
  local dir dirs="$FL_APP_DIRS" plist
  while [[ -n "$dirs" ]]; do
    dir="${dirs%%:*}"
    [[ "$dirs" == *:* ]] && dirs="${dirs#*:}" || dirs=""
    plist="${dir}/BenchBar.app/Contents/Info.plist"
    if [[ -f "$plist" ]]; then
      awk '/<key>CFBundleShortVersionString<\/key>/ { l = $0; if (l !~ /<string>/) getline l; sub(/.*<string>/, "", l); sub(/<\/string>.*/, "", l); print l " (" FILENAME ")"; exit }' "$plist"
      return 0
    fi
  done
  printf 'not installed'
}

fl_report_versions() {
  local f="versions.txt" py mariadb_bin node_bin
  py="$(fl_python_bin)"; mariadb_bin="$(fl_mariadb_bin)"; node_bin="$(fl_node_bin)"
  {
    printf 'benchbar CLI: %s (%s)\n' "${FL_VERSION:-0}" "${SCRIPT_DIR}/benchbar"
    printf 'BenchBar app: %s\n' "$(fl_app_bundle_version)"
    printf 'profile: %s\n' "$FL_PROFILE"
    printf 'bench: %s\n' "$FL_BENCH_DIR"
    printf 'site: %s\n' "$FL_SITE"
    printf 'frappe: %s\n' "$(fl_app_version frappe)"
    printf 'erpnext: %s\n' "$(fl_app_version erpnext)"
    printf 'date: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"${FL_REPORT_DIR}/${f}"
  fl_report_cmd "$f" "macOS" sw_vers
  fl_report_cmd "$f" "chip" uname -m
  fl_report_cmd "$f" "chip name" sysctl -n machdep.cpu.brand_string
  fl_report_cmd "$f" "Homebrew" brew --version
  fl_report_cmd "$f" "python (${py})" "$py" --version
  fl_report_cmd "$f" "node (${node_bin})" "$node_bin" --version
  fl_report_cmd "$f" "mariadb (${mariadb_bin})" "$mariadb_bin" --version
  fl_report_cmd "$f" "redis" redis-server --version
  fl_report_cmd "$f" "wkhtmltopdf" wkhtmltopdf --version
  fl_report_cmd "$f" "bench" bench --version
  fl_report_cmd "$f" "honcho" printf '%s\n' "${FL_HONCHO:-not found}"
}

fl_report_collect() {
  local plist target common site_cfg
  plist="$(fl_agent_plist_path)"
  target="$(fl_agent_target)"
  common="${FL_BENCH_DIR}/sites/common_site_config.json"

  fl_report_versions

  if fl_is_bench_dir "$FL_BENCH_DIR"; then
    fl_doctor_run
    fl_doctor_print_json >"${FL_REPORT_DIR}/doctor.json"
    fl_status_compute
    fl_status_print_json >"${FL_REPORT_DIR}/status.json"
  else
    printf '{"error":"no bench at %s"}\n' "$(fl_json_escape "$FL_BENCH_DIR")" >"${FL_REPORT_DIR}/doctor.json"
    printf '{"error":"no bench at %s"}\n' "$(fl_json_escape "$FL_BENCH_DIR")" >"${FL_REPORT_DIR}/status.json"
  fi

  : >"${FL_REPORT_DIR}/launchctl.txt"
  fl_report_cmd launchctl.txt "launchctl print ${target}" launchctl print "$target"
  fl_report_copy "$plist" agent.plist
  fl_report_copy "$(fl_procfile_path)" Procfile.lean
  fl_report_copy "$(fl_state_json_path)" state.json
  fl_report_tail "$(fl_bench_log_path)" bench.log.tail
  fl_report_tail "${FL_BENCH_DIR}/logs/worker.error.log" worker.error.log.tail

  # site configs: key names only, never a value
  {
    printf '# key names only; values are never included in a report\n'
    if [[ -f "$common" ]]; then
      printf '\n## sites/common_site_config.json\n'
      fl_json_key_names "$common"
    else
      printf '\n(missing: %s)\n' "$common"
    fi
    for site_cfg in "${FL_BENCH_DIR}"/sites/*/site_config.json; do
      [[ -f "$site_cfg" ]] || continue
      printf '\n## sites/%s/site_config.json\n' "$(basename "$(dirname "$site_cfg")")"
      fl_json_key_names "$site_cfg"
    done
  } >"${FL_REPORT_DIR}/site-config-keys.txt"
}

# The names this Mac goes by: what "hostname" prints (without .local), and
# the Bonjour and computer names from scutil. "hostname" can be a name the
# router handed out (Mac.lan) while the logs carry the Bonjour name, so all
# of them are replaced. One per line, longest first, nothing shorter than
# three characters, never localhost.
fl_report_host_names() {
  {
    hostname 2>/dev/null || true
    if command -v scutil >/dev/null 2>&1; then
      scutil --get LocalHostName 2>/dev/null || true
      scutil --get ComputerName 2>/dev/null || true
    fi
  } | sed -e 's/\.local$//' | awk 'length($0) >= 3 && $0 != "localhost" && !seen[$0]++ { print length($0) "\t" $0 }' | sort -rn | cut -f2-
}

# fl_report_sed_escape TEXT: TEXT as a literal sed pattern (delimiter #)
fl_report_sed_escape() { printf '%s' "$1" | sed -e 's/[][\.*^$#]/\\&/g'; }

# fl_report_redact_file FILE: masks secret values and personal paths in place.
# Appends one line per kind of replacement to FL_REPORT_REDACTIONS.
fl_report_redact_file() {
  local file="$1" name user host hosts tmp before after n
  name="$(basename "$file")"
  user="$(id -un 2>/dev/null || printf '%s' "${USER:-user}")"
  hosts="$(fl_report_host_names)"
  tmp="${file}.redact"
  # a Python repr value: 'quoted', "quoted" (escapes allowed inside) or a number
  local sq="'" dq='"' pyval
  pyval="(${sq}([^${sq}\\\\]|\\\\.)*${sq}|${dq}([^${dq}\\\\]|\\\\.)*${dq}|[0-9][0-9.]*)"

  # 1. values of keys that look like credentials, in JSON ("key": "value" or "key": 123),
  #    Python repr mappings ('key': 'value'),
  #    INI (key = value), shell (key=value), URL query (?key=value&...) and
  #    header (Key: value) forms. The
  #    last one masks a quoted value whole (escaped quotes inside it included),
  #    otherwise to the end of the line
  #    or to the next quote or comma when the key sits inside a one line
  #    JSON document.
  before="$(wc -l <"$file" | tr -d ' ')"
  sed -E \
    -e 's/("('"$FL_REPORT_KEY_RE"')"[[:space:]]*:[[:space:]]*)"([^"\\]|\\.)*"/\1"***"/g' \
    -e 's/("('"$FL_REPORT_KEY_RE"')"[[:space:]]*:[[:space:]]*)[0-9][0-9.]*/\1"***"/g' \
    -e "s/(${sq}(${FL_REPORT_KEY_RE})${sq}[[:space:]]*:[[:space:]]*)${pyval}/\\1${sq}***${sq}/g" \
    -e 's/(^|[[:space:],;&?])(('"$FL_REPORT_KEY_RE"')[[:space:]]*[=:][[:space:]]*)("([^"\\]|\\.)*"|'"'"'([^'"'"'\\]|\\.)*'"'"'|[^",;&}]*)/\1\2***/g' \
    "$file" >"$tmp"
  n="$(diff "$file" "$tmp" 2>/dev/null | grep -c '^>' || true)"
  [[ "${n:-0}" -gt 0 ]] && FL_REPORT_REDACTIONS="${FL_REPORT_REDACTIONS}${name}: masked credential-like values on ${n} line(s)"$'\n'
  mv "$tmp" "$file"

  # 2. home folder, the names of this Mac, username (the names first: a
  #    computer name like "Bob's MacBook" contains the username)
  n="$(grep -c -F -e "$HOME" "$file" 2>/dev/null || true)"
  if [[ "${n:-0}" -gt 0 ]]; then
    sed -e "s#$(fl_report_sed_escape "$HOME")#~#g" "$file" >"$tmp" && mv "$tmp" "$file"
    FL_REPORT_REDACTIONS="${FL_REPORT_REDACTIONS}${name}: replaced the home folder with ~ on ${n} line(s)"$'\n'
  fi
  while IFS= read -r host; do
    [[ -n "$host" ]] || continue
    n="$(grep -c -F -e "$host" "$file" 2>/dev/null || true)"
    if [[ "${n:-0}" -gt 0 ]]; then
      sed -e "s#$(fl_report_sed_escape "$host")#<host>#g" "$file" >"$tmp" && mv "$tmp" "$file"
      FL_REPORT_REDACTIONS="${FL_REPORT_REDACTIONS}${name}: replaced a name of this Mac with <host> on ${n} line(s)"$'\n'
    fi
  done <<<"$hosts"
  if [[ -n "$user" && "${#user}" -ge 3 ]]; then
    n="$(grep -c -F -e "$user" "$file" 2>/dev/null || true)"
    if [[ "${n:-0}" -gt 0 ]]; then
      sed -e "s#$(fl_report_sed_escape "$user")#<user>#g" "$file" >"$tmp" && mv "$tmp" "$file"
      FL_REPORT_REDACTIONS="${FL_REPORT_REDACTIONS}${name}: replaced the username with <user> on ${n} line(s)"$'\n'
    fi
  fi
  after="$(wc -l <"$file" | tr -d ' ')"
  [[ "$before" == "$after" ]] || FL_REPORT_REDACTIONS="${FL_REPORT_REDACTIONS}${name}: line count changed (${before} to ${after}), check the file"$'\n'
}

fl_report_redact_all() {
  local f
  FL_REPORT_REDACTIONS=""
  for f in "${FL_REPORT_DIR}"/*; do
    [[ -f "$f" ]] || continue
    fl_report_redact_file "$f"
  done
  {
    printf 'benchbar report %s, redactions applied before packing\n\n' "${FL_VERSION:-0}"
    printf 'Rules:\n'
    printf -- '- site_config.json and common_site_config.json are not included; site-config-keys.txt lists their key names only\n'
    printf -- '- values of keys matching password, secret, token, key, api or auth are replaced by ***\n'
    printf -- '- the home folder is written as ~, the username as <user>, the hostname, Bonjour name and computer name as <host>\n\n'
    printf 'Applied:\n'
    if [[ -n "$FL_REPORT_REDACTIONS" ]]; then printf '%s' "$FL_REPORT_REDACTIONS"; else printf '(nothing matched)\n'; fi
  } >"${FL_REPORT_DIR}/REDACTIONS.txt"
}

fl_report_print() {
  local f
  for f in versions.txt doctor.json status.json launchctl.txt agent.plist Procfile.lean state.json bench.log.tail worker.error.log.tail site-config-keys.txt REDACTIONS.txt; do
    [[ -f "${FL_REPORT_DIR}/${f}" ]] || continue
    printf '\n%s===== %s =====%s\n' "$FL_BOLD" "$f" "$FL_RESET"
    cat "${FL_REPORT_DIR}/${f}"
  done
}

# fl_cmd_report [--print] [--out DIR]
fl_cmd_report() {
  local print=0 out="" arg want_out=0 stamp zip
  for arg in "$@"; do
    if [[ "$want_out" == "1" ]]; then out="$arg"; want_out=0; continue; fi
    case "$arg" in
      --print) print=1 ;;
      --out) want_out=1 ;;
      --out=*) out="${arg#*=}" ;;
      *) fl_die "Unknown report option: ${arg}" "Usage: benchbar report [--print] [--out DIR]" ;;
    esac
  done
  [[ -n "$out" ]] || out="${BENCHBAR_REPORT_DIR:-$(fl_report_default_out)}"
  out="$(fl_abs_path "$out")"

  FL_REPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/benchbar-report.XXXXXX")"
  fl_report_collect
  fl_report_redact_all

  if [[ "$print" == "1" ]]; then
    fl_report_print
    rm -rf "$FL_REPORT_DIR"
    return 0
  fi

  fl_require_cmd zip "zip ships with macOS; check your PATH"
  stamp="$(date +%Y%m%d-%H%M%S)"
  zip="${out}/benchbar-report-${stamp}.zip"
  mkdir -p "$out"
  (cd "$FL_REPORT_DIR" && zip -q -r "$zip" .) || { rm -rf "$FL_REPORT_DIR"; fl_die "could not write ${zip}"; }
  rm -rf "$FL_REPORT_DIR"
  fl_ok "report written: ${zip}"
  fl_info "it contains doctor and status JSON, versions, the agent, Procfile.lean, state.json and log tails"
  fl_info "secrets are masked and site configs are reduced to key names; see REDACTIONS.txt inside"
  fl_info "attach it to your issue at https://github.com/askysh/benchbar/issues"
  printf '%s\n' "$zip"
}
