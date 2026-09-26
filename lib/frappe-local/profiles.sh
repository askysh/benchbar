#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# profiles.sh: team profiles, an organisation's bench recipe kept outside
# BenchBar.
#
#   benchbar profile list [--json]
#   benchbar profile show NAME
#   benchbar profile create NAME --from-bench PATH [--dir DIR]
#   benchbar install --profile NAME
#
# A built in profile (config/release-profiles.tsv) wins; otherwise NAME is
# ~/.config/benchbar/profiles/NAME.toml, then NAME.toml in each folder of
# BENCHBAR_PROFILE_PATH (colon separated, for a clone of a team's config
# repo). A team profile names a built in "base" for Python, Node and
# MariaDB, and the apps with their repos and branches. The format is the
# strict TOML subset of toml.sh:
#
#   base = "v15-lts"
#   frappe_branch = "version-15"     # optional
#   bundle = "minimal"               # or [[apps]] entries
#   site = "acme.localhost"          # optional default site name
#   scheduler = false                # optional
#   [[apps]]
#   name = "acme"
#   repo = "git@github.com:acme/acme.git"
#   branch = "main"
#   commit = "0123abc"               # optional pin

FL_TEAM_PROFILE=""
FL_TEAM_PROFILE_FILE=""
FL_TEAM_BASE=""
FL_TEAM_BUNDLE=""
FL_TEAM_SITE=""
FL_TEAM_SCHEDULER=""
FL_TEAM_DESCRIPTION=""
FL_TEAM_FRAPPE_BRANCH=""
FL_TEAM_APPS=()
FL_TEAM_ERROR=""

FL_TEAM_KEYS="top.schema=i top.base=s top.description=s top.frappe_branch=s top.bundle=s top.site=s top.scheduler=b apps.name=s apps.repo=s apps.branch=s apps.commit=s"
FL_TEAM_REQUIRED="top.base apps.name apps.repo apps.branch"

fl_team_profile_user_dir() { printf '%s/.config/benchbar/profiles' "$HOME"; }

fl_builtin_profile_exists() {
  awk -F '\t' -v p="$1" 'NR > 1 && $1 == p {found = 1} END {exit !found}' "$(fl_config_file release-profiles.tsv)"
}

fl_team_profile_valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; }

# Every folder a team profile may live in, in lookup order, with its kind.
fl_team_profile_dirs() {
  local d rest
  printf 'user\t%s\n' "$(fl_team_profile_user_dir)"
  rest="${BENCHBAR_PROFILE_PATH:-}"
  while [[ -n "$rest" ]]; do
    d="${rest%%:*}"
    [[ "$rest" == *:* ]] && rest="${rest#*:}" || rest=""
    [[ -n "$d" ]] && printf 'path\t%s\n' "${d%/}"
  done
  return 0
}

# fl_team_profile_file NAME: the first NAME.toml on the lookup path
fl_team_profile_file() {
  local kind d
  fl_team_profile_valid_name "$1" || return 1
  while IFS=$'\t' read -r kind d; do
    [[ -f "${d}/$1.toml" ]] && { printf '%s' "${d}/$1.toml"; return 0; }
  done < <(fl_team_profile_dirs)
  return 1
}

# fl_team_profile_read FILE: parses FILE into the FL_TEAM_* globals (not
# the profile itself). Returns 1 with FL_TEAM_ERROR set.
fl_team_profile_read() {
  local file="$1" out err sec idx key val cur=0 name="" repo="" branch="" commit=""
  FL_TEAM_BASE=""; FL_TEAM_BUNDLE=""; FL_TEAM_SITE=""; FL_TEAM_SCHEDULER=""; FL_TEAM_DESCRIPTION=""; FL_TEAM_FRAPPE_BRANCH=""
  FL_TEAM_APPS=(); FL_TEAM_ERROR=""
  err="$(mktemp "${TMPDIR:-/tmp}/benchbar-toml.XXXXXX")"
  if ! out="$(fl_toml_parse "$file" "$FL_TEAM_KEYS" "" "apps" "$FL_TEAM_REQUIRED" 2>"$err")"; then
    FL_TEAM_ERROR="$(head -n1 "$err")"; rm -f "$err"
    return 1
  fi
  rm -f "$err"
  while IFS=$'\t' read -r sec idx key val; do
    [[ -n "$sec" ]] || continue
    if [[ "$sec" == "apps" ]]; then
      if [[ "$idx" != "$cur" ]]; then
        [[ "$cur" != "0" ]] && FL_TEAM_APPS+=("${name}|${branch}|${repo}|${commit}")
        cur="$idx"; name=""; repo=""; branch=""; commit=""
      fi
      case "$key" in name) name="$val" ;; repo) repo="$val" ;; branch) branch="$val" ;; commit) commit="$val" ;; esac
      continue
    fi
    case "$key" in
      schema) [[ "$val" == "1" ]] || { FL_TEAM_ERROR="$(basename "$file"): not supported: schema ${val} (this benchbar reads schema 1)"; return 1; } ;;
      base) FL_TEAM_BASE="$val" ;;
      description) FL_TEAM_DESCRIPTION="$val" ;;
      frappe_branch) FL_TEAM_FRAPPE_BRANCH="$val" ;;
      bundle) FL_TEAM_BUNDLE="$val" ;;
      site) FL_TEAM_SITE="$val" ;;
      scheduler) FL_TEAM_SCHEDULER="$val" ;;
    esac
  done <<<"$out"
  [[ "$cur" != "0" ]] && FL_TEAM_APPS+=("${name}|${branch}|${repo}|${commit}")
  fl_builtin_profile_exists "$FL_TEAM_BASE" || { FL_TEAM_ERROR="$(basename "$file"): base \"${FL_TEAM_BASE}\" is not a built in profile ($(awk -F '\t' 'NR > 1 {printf "%s ", $1}' "$(fl_config_file release-profiles.tsv)"| sed 's/ $//'))"; return 1; }
  if [[ -n "$FL_TEAM_BUNDLE" && "${#FL_TEAM_APPS[@]}" -gt 0 ]]; then FL_TEAM_ERROR="$(basename "$file"): bundle and [[apps]] together; use one"; return 1; fi
  if [[ -n "$FL_TEAM_BUNDLE" && -z "$(fl_bundle_apps "$FL_TEAM_BUNDLE")" ]]; then FL_TEAM_ERROR="$(basename "$file"): unknown bundle ${FL_TEAM_BUNDLE}"; return 1; fi
  return 0
}

# fl_team_profile_load NAME: loads the base profile, then the team's
# overrides. 1 when there is no such team profile; dies on an invalid one.
fl_team_profile_load() {
  local name="$1" file
  fl_builtin_profile_exists "$name" && return 1
  file="$(fl_team_profile_file "$name")" || return 1
  fl_team_profile_read "$file" || fl_die "Team profile ${name} (${file}) is invalid: ${FL_TEAM_ERROR}" "Fix the file; benchbar profile show ${name} checks it."
  fl_load_profile "$FL_TEAM_BASE"
  [[ -n "$FL_TEAM_FRAPPE_BRANCH" ]] && FL_FRAPPE_BRANCH="$FL_TEAM_FRAPPE_BRANCH"
  FL_TEAM_PROFILE="$name"; FL_TEAM_PROFILE_FILE="$file"
  FL_PROFILE_LABEL="Team profile ${name} (on ${FL_TEAM_BASE})"
  return 0
}

# fl_team_app_policy APP: "branch|repo|priority|notes" from the loaded team
# profile, like fl_lookup_app_policy
fl_team_app_policy() {
  local spec n b r c
  [[ -n "$FL_TEAM_PROFILE" ]] || return 1
  for spec in ${FL_TEAM_APPS[@]+"${FL_TEAM_APPS[@]}"}; do
    IFS='|' read -r n b r c <<<"$spec"
    [[ "$n" == "$1" ]] && { printf '%s|%s|%s|%s\n' "$b" "$r" 5 "team profile ${FL_TEAM_PROFILE}"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------- commands

# Each team profile file once, in lookup order: KIND<TAB>NAME<TAB>FILE
fl_team_profile_files() {
  local kind d f
  while IFS=$'\t' read -r kind d; do
    for f in "$d"/*.toml; do
      [[ -f "$f" ]] || continue
      printf '%s\t%s\t%s\n' "$kind" "$(basename "$f" .toml)" "$f"
    done
  done < <(fl_team_profile_dirs)
}

fl_cmd_profile_list() {
  local json="$1" sep="" rows=() kind name file status err seen=" " p label base
  if [[ "$json" == "1" ]]; then
    printf '{"schema_version":%d,"cli_version":"%s","profiles":[' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}"
    while IFS=$'\t' read -r p label; do
      printf '%s{"name":%s,"kind":"builtin","source":"builtin","file":%s,"base":null,"label":%s,"frappe_branch":%s,"valid":true,"error":null}' \
        "$sep" "$(fl_json_str "$p")" "$(fl_json_str "$(fl_config_file release-profiles.tsv)")" "$(fl_json_str "$label")" \
        "$(fl_json_str "$(awk -F '\t' -v p="$p" 'NR > 1 && $1 == p {print $3}' "$(fl_config_file release-profiles.tsv)")")"
      sep=","
    done < <(awk -F '\t' 'NR > 1 {printf "%s\t%s\n", $1, $2}' "$(fl_config_file release-profiles.tsv)")
  else
    rows+=("Profile|Source|Base|Status")
    while IFS=$'\t' read -r p label; do rows+=("${p}|built in|-|${label}"); done < <(awk -F '\t' 'NR > 1 {printf "%s\t%s\n", $1, $2}' "$(fl_config_file release-profiles.tsv)")
  fi
  while IFS=$'\t' read -r kind name file; do
    [[ -n "$name" ]] || continue
    err=""
    if fl_builtin_profile_exists "$name"; then err="shadows the built in profile ${name}; rename the file"
    elif ! fl_team_profile_valid_name "$name"; then err="the name must be lower case letters, digits, '.', '_' or '-'"
    elif [[ "$seen" == *" ${name} "* ]]; then err="hidden by an earlier ${name}.toml on the lookup path"
    elif ! fl_team_profile_read "$file"; then err="$FL_TEAM_ERROR"
    fi
    fl_team_profile_valid_name "$name" && seen="${seen}${name} "
    base="$FL_TEAM_BASE"; [[ -n "$err" ]] && base=""
    if [[ "$json" == "1" ]]; then
      printf '%s{"name":%s,"kind":"team","source":"%s","file":%s,"base":%s,"label":%s,"frappe_branch":%s,"valid":%s,"error":%s}' \
        "$sep" "$(fl_json_str "$name")" "$kind" "$(fl_json_str "$file")" "$(fl_json_str "$base")" \
        "$(fl_json_str "$([[ -z "$err" ]] && printf '%s' "$FL_TEAM_DESCRIPTION")")" \
        "$(fl_json_str "$([[ -z "$err" ]] && printf '%s' "$FL_TEAM_FRAPPE_BRANCH")")" \
        "$(fl_json_bool "$([[ -z "$err" ]] && printf 1 || printf 0)")" "$(fl_json_str "$err")"
      sep=","
    else
      status="ok"; [[ -n "$err" ]] && status="invalid: ${err}"
      rows+=("${name}|${file}|${base:--}|${status}")
    fi
  done < <(fl_team_profile_files)
  if [[ "$json" == "1" ]]; then printf ']}\n'; return 0; fi
  fl_table "${rows[@]}"
  printf '\n'
  fl_info "team profiles: $(fl_team_profile_user_dir)/NAME.toml${BENCHBAR_PROFILE_PATH:+, then BENCHBAR_PROFILE_PATH=${BENCHBAR_PROFILE_PATH}}"
}

fl_cmd_profile_show() {
  local name="$1" file spec n b r c rows=()
  [[ -n "$name" ]] || fl_die "Usage: benchbar profile show NAME"
  if fl_builtin_profile_exists "$name"; then
    fl_load_profile "$name"
    fl_table "Field|Value" "profile|${name} (built in)" "label|${FL_PROFILE_LABEL}" "frappe|${FL_FRAPPE_BRANCH}" "erpnext|${FL_ERPNEXT_BRANCH}" \
      "python|${FL_PYTHON_FORMULA}" "node|${FL_NODE_FORMULA}" "mariadb|${FL_MARIADB_FORMULA}" "status|${FL_PROFILE_STATUS}"
    return 0
  fi
  file="$(fl_team_profile_file "$name")" || fl_die "No profile '${name}'." "Built in profiles: benchbar profile list. Team profiles live in $(fl_team_profile_user_dir)/${name}.toml or a BENCHBAR_PROFILE_PATH folder."
  fl_team_profile_read "$file" || fl_die "Team profile ${name} is invalid: ${FL_TEAM_ERROR}" "File: ${file}"
  fl_load_profile "$FL_TEAM_BASE"
  [[ -n "$FL_TEAM_FRAPPE_BRANCH" ]] && FL_FRAPPE_BRANCH="$FL_TEAM_FRAPPE_BRANCH"
  rows+=("Field|Value" "profile|${name} (team)" "file|${file}" "base|${FL_TEAM_BASE}")
  [[ -n "$FL_TEAM_DESCRIPTION" ]] && rows+=("description|${FL_TEAM_DESCRIPTION}")
  rows+=("frappe|${FL_FRAPPE_BRANCH}" "python|${FL_PYTHON_FORMULA}" "node|${FL_NODE_FORMULA}" "mariadb|${FL_MARIADB_FORMULA}")
  [[ -n "$FL_TEAM_BUNDLE" ]] && rows+=("bundle|${FL_TEAM_BUNDLE}: $(fl_bundle_apps "$FL_TEAM_BUNDLE")")
  [[ -n "$FL_TEAM_SITE" ]] && rows+=("site|${FL_TEAM_SITE}")
  [[ -n "$FL_TEAM_SCHEDULER" ]] && rows+=("scheduler|${FL_TEAM_SCHEDULER}")
  fl_table "${rows[@]}"
  if [[ "${#FL_TEAM_APPS[@]}" -gt 0 ]]; then
    rows=("App|Branch|Commit|Repo")
    for spec in "${FL_TEAM_APPS[@]}"; do IFS='|' read -r n b r c <<<"$spec"; rows+=("${n}|${b}|${c:--}|${r}"); done
    printf '\n'
    fl_table "${rows[@]}"
  fi
}

# fl_team_profile_render NAME BENCH: the TOML for a bench, read only (apps
# with their remote URLs and branches, the base profile from the frappe
# version). No commits (that is the lockfile's job), no site data, no
# credentials.
fl_team_profile_render() {
  local name="$1" base app branch url fb scheduler site
  base="$(fl_profile_detect "$FL_BENCH_DIR")"
  [[ -n "$base" ]] || base="$(fl_bstate_get PROFILE)"
  [[ -n "$base" ]] || base="$(fl_default_profile)"
  fl_load_profile "$base"
  printf '# Team profile %s, written by benchbar profile create from %s.\n' "$name" "$(basename "$FL_BENCH_DIR")"
  printf '# Use it with: benchbar install --profile %s\n' "$name"
  printf 'schema = 1\n'
  printf 'base = "%s"\n' "$base"
  fb="$(fl_app_branch frappe)"
  [[ -n "$fb" && "$fb" != "$FL_FRAPPE_BRANCH" ]] && printf 'frappe_branch = "%s"\n' "$fb"
  site="$(fl_bstate_get SITE_NAME)"
  [[ -n "$site" ]] || site="$(tr -d '[:space:]' <"${FL_BENCH_DIR}/sites/currentsite.txt" 2>/dev/null || true)"
  [[ "$site" =~ ^[a-z0-9][a-z0-9.-]*$ ]] && printf 'site = "%s"\n' "$site"
  scheduler="$(fl_bstate_get SCHEDULER)"
  [[ "$scheduler" == "on" ]] && printf 'scheduler = true\n'
  [[ "$scheduler" == "off" ]] && printf 'scheduler = false\n'
  while IFS= read -r app; do
    [[ -n "$app" && "$app" != "frappe" ]] || continue
    url="$(fl_app_remote_url "$app")"
    branch="$(fl_app_branch "$app")"
    [[ -n "$branch" ]] || branch="$(fl_app_policy_branch "$app")"
    if [[ -z "$url" || -z "$branch" ]]; then
      printf 'skipped apps/%s: %s\n' "$app" "$([[ -z "$url" ]] && printf 'no git remote' || printf 'detached HEAD and no policy branch')" >&2
      continue
    fi
    printf '\n[[apps]]\nname = "%s"\nrepo = "%s"\nbranch = "%s"\n' "$app" "$url" "$branch"
  done < <(fl_apps_txt)
}

# fl_write_reviewed FILE NEW LABEL: shows the diff, asks, backs up the old
# file, writes. "unchanged" when they are equal. Shared with lock write.
fl_write_reviewed() {
  local file="$1" new="$2" label="$3"
  if [[ -f "$file" ]] && cmp -s "$file" "$new"; then
    fl_ok "unchanged: ${file} already says this"
    return 0
  fi
  printf '\n%s%s%s\n' "$FL_BOLD" "$([[ -f "$file" ]] && printf 'Changes to %s' "$file" || printf 'New file %s' "$file")" "$FL_RESET"
  if [[ -f "$file" ]]; then diff -u "$file" "$new" | tail -n +3 | sed 's/^/    /' || true; else sed 's/^/    /' "$new"; fi
  printf '\n'
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then fl_info "dry-run: nothing was written"; return 0; fi
  fl_confirm "Write ${label} to ${file}?" || { fl_warn "Cancelled. Nothing was written."; return 1; }
  if [[ -f "$file" ]]; then fl_backup_file "$file"; fi
  mkdir -p "$(dirname "$file")"
  cp "$new" "$file"
  fl_ok "wrote ${file}${FL_LAST_BACKUP:+ (backup: ${FL_LAST_BACKUP})}"
}

fl_cmd_profile_create() {
  local name="" from="" dir="" tmp err file line code=0
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --from-bench) from="${2:-}"; shift 2 ;;
      --from-bench=*) from="${1#*=}"; shift ;;
      --dir) dir="${2:-}"; shift 2 ;;
      --dir=*) dir="${1#*=}"; shift ;;
      -*) fl_die "Unknown option for profile create: $1" "Use: benchbar profile create NAME --from-bench PATH [--dir DIR]" ;;
      *) [[ -z "$name" ]] && name="$1"; shift ;;
    esac
  done
  [[ -n "$name" && -n "$from" ]] || fl_die "Usage: benchbar profile create NAME --from-bench PATH [--dir DIR]"
  fl_team_profile_valid_name "$name" || fl_die "Invalid profile name: '${name}'." "Use lower case letters, digits, '.', '_' and '-'."
  fl_builtin_profile_exists "$name" && fl_die "${name} is a built in profile; a team profile may not shadow it." "Pick another name, for example ${name}-team."
  fl_bench_detect "$from"
  fl_is_bench_dir "$FL_BENCH_DIR" || fl_die "${FL_BENCH_DIR} is not a bench."
  dir="${dir:-$(fl_team_profile_user_dir)}"
  dir="$(fl_abs_path "$dir")"
  file="${dir}/${name}.toml"
  tmp="$(mktemp "${TMPDIR:-/tmp}/benchbar-profile.XXXXXX")"; err="$(mktemp "${TMPDIR:-/tmp}/benchbar-profile.XXXXXX")"
  fl_team_profile_render "$name" >"$tmp" 2>"$err"
  while IFS= read -r line; do fl_warn "$line"; done <"$err"
  rm -f "$err"
  # what is written must read back
  fl_team_profile_read "$tmp" || { rm -f "$tmp"; fl_die "The profile would not parse: ${FL_TEAM_ERROR}"; }
  fl_info "read ${FL_BENCH_DIR} (read only): base ${FL_TEAM_BASE}, ${#FL_TEAM_APPS[@]} app(s)"
  fl_write_reviewed "$file" "$tmp" "team profile ${name}" || code=1
  rm -f "$tmp"
  [[ "$code" == "0" && "${FL_DRY_RUN:-0}" != "1" ]] && fl_info "use it with: benchbar install --profile ${name}   (share it by committing ${name}.toml to your team's config repo)"
  return "$code"
}

fl_cmd_profile() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    list|"") fl_cmd_profile_list "$OPT_JSON" ;;
    show) fl_cmd_profile_show "${1:-}" ;;
    create) fl_cmd_profile_create "$@" ;;
    *) fl_die "Unknown profile command: ${sub}" "Use: benchbar profile list | show NAME | create NAME --from-bench PATH" ;;
  esac
}
