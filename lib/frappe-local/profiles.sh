#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# profiles.sh: team profiles, an organisation's bench recipe kept outside
# BenchBar.
#
#   benchbar profile list [--json]
#   benchbar profile show NAME
#   benchbar profile create NAME --from-bench PATH [--dir DIR]
#   benchbar profile export | import | subscribe | update | remove | check
#   benchbar install --profile NAME
#
# A built in profile (config/release-profiles.tsv) wins; otherwise NAME is
# ~/.config/benchbar/profiles/NAME.toml (written by hand, create or
# import), then NAME.toml in each subscription (a clone under
# ~/.config/benchbar/sources/, in the order of sources.list), then in each
# folder of BENCHBAR_PROFILE_PATH (colon separated, for a clone of a
# team's config repo). A team profile names a built in "base" for Python, Node and
# MariaDB, and the apps with their repos and branches. The format is the
# strict TOML subset of toml.sh:
#
#   schema = 2                       # optional, 1 when absent
#   base = "v15-lts"
#   frappe_branch = "version-15"     # optional
#   bundle = "minimal"               # or [[apps]] entries, never both
#   site = "acme.localhost"          # optional default site name
#   scheduler = false                # optional
#   source = "https://..."           # schema 2: where import fetched it
#   exported_from = "benchbar 0.6.0, 2026-09-29"   # schema 2
#   [[apps]]
#   name = "acme"
#   repo = "git@github.com:acme/acme.git"
#   branch = "main"
#   commit = "0123abc"               # optional pin
#   access = "private"               # schema 2: public, private, personal, unknown
#   requires = ["acme_base"]         # schema 2: apps this one needs

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
# schema 2 (0.6): where an imported file came from, who exported it, and
# per app (same index as FL_TEAM_APPS) its access and the apps it requires
FL_TEAM_SCHEMA=""
FL_TEAM_SOURCE=""
FL_TEAM_EXPORTED_FROM=""
FL_TEAM_APP_ACCESS=()
FL_TEAM_APP_REQUIRES=()

FL_TEAM_KEYS="top.schema=i top.base=s top.description=s top.frappe_branch=s top.bundle=s top.site=s top.scheduler=b top.source=s top.exported_from=s apps.name=s apps.repo=s apps.branch=s apps.commit=s apps.access=s apps.requires=a"
FL_TEAM_REQUIRED="top.base apps.name apps.repo apps.branch"

fl_team_profile_user_dir() { printf '%s/.config/benchbar/profiles' "$HOME"; }

fl_builtin_profile_exists() {
  awk -F '\t' -v p="$1" 'NR > 1 && $1 == p {found = 1} END {exit !found}' "$(fl_config_file release-profiles.tsv)"
}

fl_team_profile_valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; }

# Every folder a team profile may live in, in lookup order, with its kind.
fl_team_profile_dirs() {
  local d rest sub _url
  printf 'user\t%s\n' "$(fl_team_profile_user_dir)"
  while IFS=$'\t' read -r sub _url; do
    printf 'subscribed\t%s\n' "$(fl_profile_sub_profdir "$(fl_profile_sources_dir)/${sub}")"
  done < <(fl_profile_subscriptions)
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

# the app name rule of toml.sh, for the entries of a requires list
fl_team_profile_valid_app() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

fl_team__app_add() {
  FL_TEAM_APPS+=("${1}|${2}|${3}|${4}")
  FL_TEAM_APP_ACCESS+=("$5")
  FL_TEAM_APP_REQUIRES+=("$6")
}

# fl_team_profile_read FILE: parses FILE into the FL_TEAM_* globals (not
# the profile itself). Returns 1 with FL_TEAM_ERROR set.
fl_team_profile_read() {
  local file="$1" out err sec idx key val cur=0 name="" repo="" branch="" commit="" access="" requires="" v2="" r
  FL_TEAM_BASE=""; FL_TEAM_BUNDLE=""; FL_TEAM_SITE=""; FL_TEAM_SCHEDULER=""; FL_TEAM_DESCRIPTION=""; FL_TEAM_FRAPPE_BRANCH=""
  FL_TEAM_SCHEMA=""; FL_TEAM_SOURCE=""; FL_TEAM_EXPORTED_FROM=""
  FL_TEAM_APPS=(); FL_TEAM_APP_ACCESS=(); FL_TEAM_APP_REQUIRES=(); FL_TEAM_ERROR=""
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
        [[ "$cur" != "0" ]] && fl_team__app_add "$name" "$branch" "$repo" "$commit" "$access" "$requires"
        cur="$idx"; name=""; repo=""; branch=""; commit=""; access=""; requires=""
      fi
      case "$key" in
        name) name="$val" ;; repo) repo="$val" ;; branch) branch="$val" ;; commit) commit="$val" ;;
        access)
          v2="${v2:-access}"
          case "$val" in
            public|private|personal|unknown) access="$val" ;;
            *) FL_TEAM_ERROR="$(basename "$file"): access \"${val}\" (use public, private, personal or unknown)"; return 1 ;;
          esac ;;
        requires)
          v2="${v2:-requires}"
          for r in $val; do
            fl_team_profile_valid_app "$r" || { FL_TEAM_ERROR="$(basename "$file"): requires \"${r}\" is not an app name"; return 1; }
          done
          requires="$val" ;;
      esac
      continue
    fi
    case "$key" in
      schema)
        [[ "$val" == "1" || "$val" == "2" ]] || { FL_TEAM_ERROR="$(basename "$file"): not supported: schema ${val} (this benchbar reads schema 1 and 2)"; return 1; }
        FL_TEAM_SCHEMA="$val" ;;
      source) FL_TEAM_SOURCE="$val"; v2="${v2:-source}" ;;
      exported_from) FL_TEAM_EXPORTED_FROM="$val"; v2="${v2:-exported_from}" ;;
      base) FL_TEAM_BASE="$val" ;;
      description) FL_TEAM_DESCRIPTION="$val" ;;
      frappe_branch) FL_TEAM_FRAPPE_BRANCH="$val" ;;
      bundle) FL_TEAM_BUNDLE="$val" ;;
      site) FL_TEAM_SITE="$val" ;;
      scheduler) FL_TEAM_SCHEDULER="$val" ;;
    esac
  done <<<"$out"
  [[ "$cur" != "0" ]] && fl_team__app_add "$name" "$branch" "$repo" "$commit" "$access" "$requires"
  # one entry per app: install, export and the app would each pick a different one
  r="$(printf '%s\n' ${FL_TEAM_APPS[@]+"${FL_TEAM_APPS[@]}"} | cut -d'|' -f1 | sort | uniq -d | head -n1)"
  [[ -z "$r" ]] || { FL_TEAM_ERROR="$(basename "$file"): app \"${r}\" is listed twice in [[apps]]"; return 1; }
  if [[ -n "$v2" && "$FL_TEAM_SCHEMA" != "2" ]]; then
    FL_TEAM_ERROR="$(basename "$file"): ${v2} needs schema = 2 (source, exported_from, access and requires are schema 2 keys)"
    return 1
  fi
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
  local json="$1" sep="" rows=() kind name file status err seen=$'\n' p label base tsv shadow skind src sub subjson schema warns=() line
  local sname surl sdir behind days fetched
  tsv="$(fl_config_file release-profiles.tsv)"
  if [[ "$json" == "1" ]]; then
    printf '{"schema_version":%d,"cli_version":"%s","profiles":[' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}"
    while IFS=$'\t' read -r p label; do
      printf '%s{"name":%s,"kind":"builtin","source":"builtin","source_url":null,"subscription":null,"shadowed_by":null,"schema":null,"file":%s,"base":null,"label":%s,"frappe_branch":%s,"valid":true,"error":null}' \
        "$sep" "$(fl_json_str "$p")" "$(fl_json_str "$tsv")" "$(fl_json_str "$label")" \
        "$(fl_json_str "$(awk -F '\t' -v p="$p" 'NR > 1 && $1 == p {print $3}' "$tsv")")"
      sep=","
    done < <(awk -F '\t' 'NR > 1 {printf "%s\t%s\n", $1, $2}' "$tsv")
  else
    rows+=("Profile|Source|Base|Status")
    while IFS=$'\t' read -r p label; do rows+=("${p}|built in|-|${label}"); done < <(awk -F '\t' 'NR > 1 {printf "%s\t%s\n", $1, $2}' "$tsv")
  fi
  while IFS=$'\t' read -r kind name file; do
    [[ -n "$name" ]] || continue
    err=""; shadow=""; src=""; subjson="null"; schema=""
    FL_TEAM_BASE=""; FL_TEAM_SOURCE=""; FL_TEAM_SCHEMA=""; FL_TEAM_DESCRIPTION=""; FL_TEAM_FRAPPE_BRANCH=""
    if fl_builtin_profile_exists "$name"; then err="shadows the built in profile ${name}; rename the file"; shadow="$tsv"
    elif ! fl_team_profile_valid_name "$name"; then err="the name must be lower case letters, digits, '.', '_' or '-'"
    elif [[ "$seen" == *$'\n'"${name}"$'\t'* ]]; then
      shadow="${seen#*$'\n'"${name}"$'\t'}"; shadow="${shadow%%$'\n'*}"
      err="hidden by an earlier ${name}.toml on the lookup path"
      warns+=("${name}: ${file} is hidden by ${shadow}")
    elif ! fl_team_profile_read "$file"; then err="$FL_TEAM_ERROR"
    fi
    if fl_team_profile_valid_name "$name" && [[ "$seen" != *$'\n'"${name}"$'\t'* ]]; then seen="${seen}${name}"$'\t'"${file}"$'\n'; fi
    base="$FL_TEAM_BASE"; [[ -n "$err" ]] && base=""
    [[ -z "$err" ]] && schema="${FL_TEAM_SCHEMA:-1}"
    skind="$kind"
    if [[ "$kind" == "user" ]] && fl_profile_file_source "$file" >/dev/null; then skind="imported"; src="$(fl_profile_file_source "$file")"; fi
    status="ok"
    if [[ "$kind" == "subscribed" ]] && sub="$(fl_profile_subscription_of "$file")"; then
      IFS=$'\t' read -r sname surl sdir <<<"$sub"
      src="$surl"
      read -r behind days <<<"$(fl_profile_sub_behind "$sdir")"
      fetched="$(fl_profile_sub_stamp "$sdir" fetched)"
      [[ -n "$fetched" ]] && fetched="$(fl_iso_from_epoch "$fetched")"
      subjson="$(printf '{"repo":%s,"dir":%s,"behind":%s,"days":%s,"fetched_at":%s}' "$(fl_json_str "$surl")" "$(fl_json_str "$sdir")" \
        "$(fl_json_num "$behind")" "$(fl_json_num "$days")" "$(fl_json_str "$fetched")")"
      [[ "${behind:-0}" =~ ^[1-9] ]] && status="ok, ${behind} commit(s) behind: benchbar profile update ${name}"
    fi
    if [[ "$json" == "1" ]]; then
      printf '%s{"name":%s,"kind":"team","source":"%s","source_url":%s,"subscription":%s,"shadowed_by":%s,"schema":%s,"file":%s,"base":%s,"label":%s,"frappe_branch":%s,"valid":%s,"error":%s}' \
        "$sep" "$(fl_json_str "$name")" "$skind" "$(fl_json_str "$src")" "$subjson" "$(fl_json_str "$shadow")" "$(fl_json_num "$schema")" \
        "$(fl_json_str "$file")" "$(fl_json_str "$base")" \
        "$(fl_json_str "$([[ -z "$err" ]] && printf '%s' "$FL_TEAM_DESCRIPTION")")" \
        "$(fl_json_str "$([[ -z "$err" ]] && printf '%s' "$FL_TEAM_FRAPPE_BRANCH")")" \
        "$(fl_json_bool "$([[ -z "$err" ]] && printf 1 || printf 0)")" "$(fl_json_str "$err")"
      sep=","
    else
      [[ -n "$err" ]] && status="invalid: ${err}"
      rows+=("${name}|${skind}: ${file}|${base:--}|${status}")
    fi
  done < <(fl_team_profile_files)
  if [[ "$json" == "1" ]]; then printf ']}\n'; return 0; fi
  fl_table "${rows[@]}"
  printf '\n'
  for line in ${warns[@]+"${warns[@]}"}; do fl_warn "shadowed: ${line}"; done
  fl_info "team profiles: $(fl_team_profile_user_dir)/NAME.toml, then subscriptions ($(fl_profile_sources_list))${BENCHBAR_PROFILE_PATH:+, then BENCHBAR_PROFILE_PATH=${BENCHBAR_PROFILE_PATH}}"
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

# ---------------------------------------------------------------- sharing
#
# export writes a copy for others (real host names, default branches,
# access and requires per app), import fetches one file (https or a local
# path, 64 KB at most), subscribe clones a team's config repo into
# ~/.config/benchbar/sources/ and reads only its *.toml files, update
# fetches again and asks, remove moves aside, check asks git whether each
# repo can be read with your own credentials. Nothing here runs code from
# a profile or a subscription, and nothing updates on its own.

FL_PROFILE_MAX_BYTES=65536
FL_PROFILE_NET_SECS="${FL_PROFILE_NET_SECS:-10}"
FL_PROFILE_ERR=""
FL_REACH=""
FL_REACH_REASON=""
CK_APPS=(); CK_REPOS=(); CK_REACH=(); CK_REASON=(); CK_SKIPPED=(); CK_SKIP_WHY=()

fl_profile_config_dir() { printf '%s/.config/benchbar' "$HOME"; }
fl_profile_sources_dir() { printf '%s/sources' "$(fl_profile_config_dir)"; }
fl_profile_sources_list() { printf '%s/sources.list' "$(fl_profile_config_dir)"; }
fl_profile_removed_dir() { printf '%s/removed' "$(fl_profile_config_dir)"; }

# The subscriptions in subscribe order: DIRNAME<TAB>URL
fl_profile_subscriptions() {
  local f
  f="$(fl_profile_sources_list)"
  [[ -f "$f" ]] || return 0
  awk -F '\t' 'NF >= 2 && $1 != "" && $1 !~ /^#/ {print $1 "\t" $2}' "$f"
}

# Where a subscription's profiles are: its profiles/ folder, else its root
fl_profile_sub_profdir() { if [[ -d "$1/profiles" ]]; then printf '%s/profiles' "$1"; else printf '%s' "$1"; fi; }

# fl_profile_subscription_of FILE: DIRNAME<TAB>URL<TAB>DIR of the
# subscription FILE is in; 1 when it is in none
fl_profile_subscription_of() {
  local sub url dir
  while IFS=$'\t' read -r sub url; do
    dir="$(fl_profile_sources_dir)/${sub}"
    [[ "$(dirname "$1")" == "$(fl_profile_sub_profdir "$dir")" ]] && { printf '%s\t%s\t%s\n' "$sub" "$url" "$dir"; return 0; }
  done < <(fl_profile_subscriptions)
  return 1
}

# fl_profile_subscription_named NAME: the subscription whose folder name or
# URL is NAME, like fl_profile_subscription_of
fl_profile_subscription_named() {
  local sub url
  while IFS=$'\t' read -r sub url; do
    [[ "$1" == "$sub" || "$1" == "$url" ]] && { printf '%s\t%s\t%s\n' "$sub" "$url" "$(fl_profile_sources_dir)/${sub}"; return 0; }
  done < <(fl_profile_subscriptions)
  return 1
}

# The profile names of a subscription folder, space separated
fl_profile_sub_names() {
  local f out=""
  for f in "$(fl_profile_sub_profdir "$1")"/*.toml; do
    [[ -f "$f" ]] && out="${out}${out:+ }$(basename "$f" .toml)"
  done
  printf '%s' "$out"
}

# fl_profile_file_source FILE: the source = "..." an import wrote; 1 when none
fl_profile_file_source() {
  local v
  v="$(awk '/^[ \t]*\[/ {exit} /^[ \t]*source[ \t]*=[ \t]*"/ {sub(/^[ \t]*source[ \t]*=[ \t]*"/, ""); sub(/".*$/, ""); print; exit}' "$1" 2>/dev/null || true)"
  [[ -n "$v" ]] || return 1
  printf '%s' "$v"
}

# git in a subscription clone; a clone never runs hooks
fl_profile_git() { local d="$1"; shift; git -C "$d" -c core.hooksPath=/dev/null "$@"; }
# git with your own keys and tokens, but never a prompt
fl_profile_git_net() { env GIT_TERMINAL_PROMPT=0 GIT_LFS_SKIP_SMUDGE=1 GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=${FL_PROFILE_NET_SECS}" git -c core.hooksPath=/dev/null "$@"; }
# git as a stranger: no config, no credential helper, no prompt
fl_profile_git_anon() { env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true SSH_ASKPASS=true GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c credential.helper= "$@"; }

fl_profile_offline_mode() { [[ "${BENCHBAR_OFFLINE:-0}" == "1" || "${OFFLINE:-0}" == "1" ]]; }
fl_profile_offline_msg() { printf '%s' "$1" | grep -qiE 'could not resolve|network is unreachable|timed out|failed to connect|no route to host'; }

# fl_profile_timed SECS OUT COMMAND...: stdout to OUT, the first line of
# stderr in FL_PROFILE_ERR; exit 124 after SECS
fl_profile_timed() {
  local secs="$1" out="$2" err pid ticks=0 code=0
  shift 2
  err="$(mktemp "${TMPDIR:-/tmp}/benchbar-net.XXXXXX")"
  "$@" </dev/null >"$out" 2>"$err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$ticks" -ge $((secs * 10)) ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$err"
      FL_PROFILE_ERR="timed out after ${secs}s"
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid" || code=$?
  FL_PROFILE_ERR="$(grep -v '^[[:space:]]*$' "$err" | head -n1 | sed -E 's/^(fatal|remote|error): *//' || true)"
  rm -f "$err"
  return "$code"
}

# ---- JSON helpers: a string with its newlines kept, a list of strings
fl_profile_json_text() {
  if [[ -z "$1" ]]; then printf 'null'; return 0; fi
  printf '%s' "$1" | awk 'BEGIN { ORS = "" } { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/[\001-\037]/, ""); lines[NR] = $0 }
    END { printf "\""; for (i = 1; i <= NR; i++) printf "%s%s", (i > 1 ? "\\n" : ""), lines[i]; printf "\"" }'
}
fl_profile_json_list() {
  local sep="" w
  printf '['
  for w in "$@"; do printf '%s%s' "$sep" "$(fl_json_str "$w")"; sep=","; done
  printf ']'
}

# ---- URLs

# https://host/path for any git URL a stranger could read over https
fl_profile_https_form() {
  local u re_scp='^([A-Za-z0-9._-]+@)?([A-Za-z0-9][A-Za-z0-9._-]*):([^/].*)$' re_ssh='^ssh://([^@/]+@)?([^/:]+)(:[0-9]+)?/(.+)$'
  u="$(fl_url_strip_userinfo "$1")"
  case "$u" in
    https://*) printf '%s' "$u" ;;
    http://*) printf 'https://%s' "${u#http://}" ;;
    ssh://*) [[ "$u" =~ $re_ssh ]] && printf 'https://%s/%s' "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]}" ;;
    *://*|/*) ;;
    *) [[ "$u" =~ $re_scp ]] && printf 'https://%s/%s' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" ;;
  esac
  return 0
}

# fl_profile_ssh_resolve HOST: "HOSTNAME PORT" from ssh -G (the ~/.ssh/config
# alias a teammate does not have); HOST itself when there is none
fl_profile_ssh_resolve() {
  local out hn="" hp=""
  if [[ "$1" != -* ]]; then
    out="$(ssh -G "$1" 2>/dev/null || true)"
    hn="$(printf '%s\n' "$out" | awk '$1 == "hostname" {print $2; exit}')"
    hp="$(printf '%s\n' "$out" | awk '$1 == "port" {print $2; exit}')"
  fi
  printf '%s %s\n' "${hn:-$1}" "${hp:-22}"
}

# fl_profile_export_url URL: the URL a teammate can use: no user info, no
# SSH alias (git@github-work:acme/x.git becomes git@github.com:acme/x.git)
fl_profile_export_url() {
  local u user host port path hn hp re_scp='^([A-Za-z0-9._-]+@)?([A-Za-z0-9][A-Za-z0-9._-]*):([^/].*)$' re_ssh='^ssh://([^@/]+@)?([^/:]+)(:[0-9]+)?/(.+)$'
  u="$(fl_url_strip_userinfo "$1")"
  case "$u" in
    ssh://*)
      [[ "$u" =~ $re_ssh ]] || { printf '%s' "$u"; return 0; }
      user="${BASH_REMATCH[1]}"; host="${BASH_REMATCH[2]}"; port="${BASH_REMATCH[3]}"; path="${BASH_REMATCH[4]}"
      read -r hn hp <<<"$(fl_profile_ssh_resolve "$host")"
      [[ -z "$port" && "$hp" != "22" ]] && port=":${hp}"
      printf 'ssh://%s%s%s/%s' "$user" "$hn" "$port" "$path" ;;
    *://*|/*) printf '%s' "$u" ;;
    *)
      [[ "$u" =~ $re_scp ]] || { printf '%s' "$u"; return 0; }
      user="${BASH_REMATCH[1]}"; host="${BASH_REMATCH[2]}"; path="${BASH_REMATCH[3]}"
      read -r hn hp <<<"$(fl_profile_ssh_resolve "$host")"
      if [[ "$hp" != "22" ]]; then printf 'ssh://%s%s:%s/%s' "$user" "$hn" "$hp" "$path"; else printf '%s%s:%s' "$user" "$hn" "$path"; fi ;;
  esac
}

# ---- asking git

# fl_profile_reach REPO BRANCH: FL_REACH is true, false or null (offline)
# and FL_REACH_REASON says why not
fl_profile_reach() {
  local out code=0
  FL_REACH=""; FL_REACH_REASON=""
  if fl_profile_offline_mode; then FL_REACH=null; FL_REACH_REASON="offline mode"; return 0; fi
  out="$(mktemp "${TMPDIR:-/tmp}/benchbar-net.XXXXXX")"
  fl_profile_timed "$FL_PROFILE_NET_SECS" "$out" fl_profile_git_net ls-remote --exit-code --heads --tags -- "$1" "$2" || code=$?
  rm -f "$out"
  case "$code" in
    0) FL_REACH=true ;;
    2) FL_REACH=false; FL_REACH_REASON="the repo has no branch or tag ${2}" ;;
    124) FL_REACH=null; FL_REACH_REASON="${FL_PROFILE_ERR} (offline?)" ;;
    *)
      if fl_profile_offline_msg "$FL_PROFILE_ERR"; then FL_REACH=null; else FL_REACH=false; fi
      FL_REACH_REASON="${FL_PROFILE_ERR:-git ls-remote exited with ${code}}" ;;
  esac
}

# fl_profile_default_branch URL: the branch HEAD points at, or nothing
fl_profile_default_branch() {
  local out
  fl_profile_offline_mode && return 0
  out="$(mktemp "${TMPDIR:-/tmp}/benchbar-net.XXXXXX")"
  if fl_profile_timed "$FL_PROFILE_NET_SECS" "$out" fl_profile_git_net ls-remote --symref -- "$1" HEAD; then
    awk '$1 == "ref:" && $3 == "HEAD" {sub(/^refs\/heads\//, "", $2); print $2; exit}' "$out"
  fi
  rm -f "$out"
  return 0
}

fl_profile_branch_exists() {
  local out code=0
  fl_profile_offline_mode && return 1
  out="$(mktemp "${TMPDIR:-/tmp}/benchbar-net.XXXXXX")"
  fl_profile_timed "$FL_PROFILE_NET_SECS" "$out" fl_profile_git_net ls-remote --exit-code --heads -- "$1" "$2" || code=$?
  rm -f "$out"
  return "$code"
}

# fl_profile_access URL: public when a stranger can read it over https,
# personal when it is private and its GitHub owner is a user (not an
# organisation), private otherwise, unknown when offline or not https
fl_profile_access() {
  local https out code=0 type re='^https://github\.com/([^/]+)/'
  https="$(fl_profile_https_form "$1")"
  if [[ -z "$https" ]] || fl_profile_offline_mode; then printf 'unknown'; return 0; fi
  out="$(mktemp "${TMPDIR:-/tmp}/benchbar-net.XXXXXX")"
  fl_profile_timed "$FL_PROFILE_NET_SECS" "$out" fl_profile_git_anon ls-remote -- "$https" HEAD || code=$?
  rm -f "$out"
  if [[ "$code" == "0" ]]; then printf 'public'; return 0; fi
  if [[ "$code" == "124" ]] || fl_profile_offline_msg "$FL_PROFILE_ERR"; then printf 'unknown'; return 0; fi
  if [[ "$https" =~ $re ]]; then
    type="$(curl -fsSL --max-time "$FL_PROFILE_NET_SECS" -H 'Accept: application/vnd.github+json' "https://api.github.com/users/${BASH_REMATCH[1]}" 2>/dev/null \
      | sed -n 's/.*"type"[[:space:]]*:[[:space:]]*"\([A-Za-z]*\)".*/\1/p' | head -n1 || true)"
    [[ "$type" == "User" ]] && { printf 'personal'; return 0; }
  fi
  printf 'private'
}

# ---- check

# fl_profile_check_loaded: asks git about every app of the profile
# fl_team_profile_read just read. Per app CK_APPS, CK_REPOS, CK_REACH,
# CK_REASON; CK_SKIPPED are the apps install leaves out (unreachable ones
# and every app that requires one), CK_SKIP_WHY says why, same index.
fl_profile_check_loaded() {
  local spec n b r c i skip=" " changed req why
  CK_APPS=(); CK_REPOS=(); CK_REACH=(); CK_REASON=(); CK_SKIPPED=(); CK_SKIP_WHY=()
  for spec in ${FL_TEAM_APPS[@]+"${FL_TEAM_APPS[@]}"}; do
    IFS='|' read -r n b r c <<<"$spec"
    fl_profile_reach "$r" "$b"
    CK_APPS+=("$n"); CK_REPOS+=("$r"); CK_REACH+=("$FL_REACH"); CK_REASON+=("$FL_REACH_REASON")
    [[ "$FL_REACH" == "false" ]] && skip="${skip}${n} "
  done
  changed=1
  while [[ "$changed" == "1" ]]; do
    changed=0; i=0
    for n in ${CK_APPS[@]+"${CK_APPS[@]}"}; do
      if [[ "$skip" != *" ${n} "* ]]; then
        for req in ${FL_TEAM_APP_REQUIRES[$i]:-}; do
          if [[ "$skip" == *" ${req} "* ]]; then skip="${skip}${n} "; changed=1; break; fi
        done
      fi
      i=$((i + 1))
    done
  done
  i=0
  for n in ${CK_APPS[@]+"${CK_APPS[@]}"}; do
    if [[ "$skip" == *" ${n} "* ]]; then
      if [[ "${CK_REACH[$i]}" == "false" ]]; then why="unreachable: ${CK_REASON[$i]}"
      else
        why=""
        for req in ${FL_TEAM_APP_REQUIRES[$i]:-}; do [[ "$skip" == *" ${req} "* ]] && { why="needs ${req}"; break; }; done
      fi
      CK_SKIPPED+=("$n"); CK_SKIP_WHY+=("$why")
    fi
    i=$((i + 1))
  done
}

fl_profile_check_repos_json() {
  local i=0 sep=""
  printf '['
  while [[ "$i" -lt "${#CK_APPS[@]}" ]]; do
    printf '%s{"app":%s,"repo":%s,"reachable":%s,"reason":%s}' "$sep" "$(fl_json_str "${CK_APPS[$i]}")" "$(fl_json_str "${CK_REPOS[$i]}")" \
      "${CK_REACH[$i]}" "$(fl_json_str "${CK_REASON[$i]}")"
    sep=","; i=$((i + 1))
  done
  printf ']'
}

fl_profile_check_print() {
  local i=0 rows=("App|Reachable|Repo|Why") word
  while [[ "$i" -lt "${#CK_APPS[@]}" ]]; do
    word="not known"
    [[ "${CK_REACH[$i]}" == "true" ]] && word="yes"
    [[ "${CK_REACH[$i]}" == "false" ]] && word="no"
    rows+=("${CK_APPS[$i]}|${word}|${CK_REPOS[$i]}|${CK_REASON[$i]:--}")
    i=$((i + 1))
  done
  [[ "${#CK_APPS[@]}" -gt 0 ]] && fl_table "${rows[@]}"
  i=0
  while [[ "$i" -lt "${#CK_SKIPPED[@]}" ]]; do
    fl_warn "install --profile leaves out ${CK_SKIPPED[$i]} (${CK_SKIP_WHY[$i]})"
    i=$((i + 1))
  done
  return 0
}

# fl_profile_json_begin: with --json, the human lines go to stderr and the
# JSON document to fd 3 (stdout); without, fd 3 is stdout too
fl_profile_json_begin() {
  if [[ "${OPT_JSON:-0}" == "1" ]]; then exec 3>&1 1>&2; else exec 3>&1; fi
}

# fl_profile_need NAME: reads the team profile NAME (FL_PROFILE_FILE);
# dies with the reason otherwise
FL_PROFILE_FILE=""
fl_profile_need() {
  fl_team_profile_valid_name "$1" || fl_die "Invalid profile name: '${1}'." "Use lower case letters, digits, '.', '_' and '-'."
  fl_builtin_profile_exists "$1" && fl_die "${1} is a built in profile." "Only team profiles are shared: benchbar profile list shows them."
  FL_PROFILE_FILE="$(fl_team_profile_file "$1")" || fl_die "No team profile '${1}'." "benchbar profile list shows the team profiles."
  fl_team_profile_read "$FL_PROFILE_FILE" || fl_die "Team profile ${1} (${FL_PROFILE_FILE}) is invalid: ${FL_TEAM_ERROR}"
}

fl_cmd_profile_check() {
  local name="${1:-}"
  [[ -n "$name" ]] || fl_die "Usage: benchbar profile check NAME [--json]"
  fl_profile_json_begin
  fl_profile_need "$name"
  fl_profile_check_loaded
  if [[ "${OPT_JSON:-0}" == "1" ]]; then
    printf '{"schema_version":%d,"cli_version":"%s","name":%s,"repos":%s,"skipped_apps":%s}\n' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" \
      "$(fl_json_str "$name")" "$(fl_profile_check_repos_json)" "$(fl_profile_json_list ${CK_SKIPPED[@]+"${CK_SKIPPED[@]}"})" >&3
    return 0
  fi
  [[ "${#CK_APPS[@]}" -gt 0 ]] || { fl_ok "${name} lists no repos of its own (its apps come from a bundle)"; return 0; }
  fl_profile_check_print
  [[ "${#CK_SKIPPED[@]}" -eq 0 ]] && fl_ok "every repo of ${name} can be read with your credentials"
  return 0
}

# install --profile: leaves out what check says cannot be read.
# FL_PROFILE_SKIP is " app app " and FL_PROFILE_SKIP_NOTES "app (why)".
FL_PROFILE_SKIP=" "
FL_PROFILE_SKIP_NOTES=()
fl_profile_install_skips() {
  local i=0
  FL_PROFILE_SKIP=" "; FL_PROFILE_SKIP_NOTES=()
  [[ -n "$FL_TEAM_PROFILE" && "${#FL_TEAM_APPS[@]}" -gt 0 ]] || return 0
  fl_profile_check_loaded
  while [[ "$i" -lt "${#CK_SKIPPED[@]}" ]]; do
    FL_PROFILE_SKIP="${FL_PROFILE_SKIP}${CK_SKIPPED[$i]} "
    FL_PROFILE_SKIP_NOTES+=("${CK_SKIPPED[$i]} (${CK_SKIP_WHY[$i]})")
    i=$((i + 1))
  done
}

# ---- export

EX_NAME=(); EX_REPO=(); EX_XREPO=(); EX_CUR=(); EX_XBR=(); EX_DEF=(); EX_VER=(); EX_ACC=(); EX_REQ=(); EX_KEEP=(); EX_COMMIT=(); EX_WARN=()
EX_BLOCKED=()   # "app<TAB>required_by required_by"

# fl_profile_export_plan OVERRIDES DROPS: fills the EX_* arrays for the
# loaded profile. OVERRIDES is "app=branch ...", DROPS " app app ".
fl_profile_export_plan() {
  local overrides="$1" drops="$2" spec n b r c i=0 xr def xb ver req policy o ov bench="" d j by
  EX_NAME=(); EX_REPO=(); EX_XREPO=(); EX_CUR=(); EX_XBR=(); EX_DEF=(); EX_VER=(); EX_ACC=(); EX_REQ=(); EX_KEEP=(); EX_COMMIT=(); EX_WARN=(); EX_BLOCKED=()
  # requires from the bench's hooks.py when the file does not say (read only)
  fl_bench_detect "${OPT_BENCH_DIR:-}" >/dev/null 2>&1 || true
  [[ -n "${FL_BENCH_DIR:-}" ]] && fl_is_bench_dir "$FL_BENCH_DIR" && bench="$FL_BENCH_DIR"
  for spec in ${FL_TEAM_APPS[@]+"${FL_TEAM_APPS[@]}"}; do
    IFS='|' read -r n b r c <<<"$spec"
    req="${FL_TEAM_APP_REQUIRES[$i]:-}"
    if [[ -z "$req" && -n "$bench" && -d "${bench}/apps/${n}" ]]; then req="$(fl_app_required_apps "$n" | tr '\n' ' ')"; req="${req% }"; fi
    xr="$(fl_profile_export_url "$r")"
    [[ "$xr" != "$r" ]] && EX_WARN+=("${n}: ${r} is written as ${xr}")
    # ask git with the URL as it is on this Mac (an SSH alias carries the key
    # for that account), write the portable one
    def="$(fl_profile_default_branch "$r")"
    [[ -z "$def" && "$xr" != "$r" ]] && def="$(fl_profile_default_branch "$xr")"
    o=""
    for ov in $overrides; do [[ "${ov%%=*}" == "$n" ]] && o="${ov#*=}"; done
    policy="$(fl_lookup_app_policy "$n" "$FL_TEAM_BASE" 2>/dev/null || true)"; policy="${policy%%|*}"
    if [[ -n "$o" ]]; then
      xb="$o"; ver=false; { fl_profile_branch_exists "$r" "$o" || fl_profile_branch_exists "$xr" "$o"; } && ver=true
      [[ "$ver" == "true" ]] || EX_WARN+=("${n}: branch ${o} was not found in ${xr}")
    elif [[ "$b" == "${FL_FRAPPE_BRANCH:-}" || ( -n "$policy" && "$b" == "$policy" ) ]]; then
      # an app on the base's release branch (erpnext, hrms or india_compliance on
      # version-15) keeps it: its default branch is develop, which needs another frappe
      xb="$b"; ver=false; { fl_profile_branch_exists "$r" "$b" || fl_profile_branch_exists "$xr" "$b"; } && ver=true
      [[ -n "$def" && "$def" != "$b" ]] && EX_WARN+=("${n}: keeps ${b}, the ${FL_TEAM_BASE} release branch (its default branch is ${def})")
    elif [[ -n "$def" ]]; then
      xb="$def"; ver=true
    else
      xb="$b"; ver=false
      EX_WARN+=("${n}: could not read the default branch of ${xr}${FL_PROFILE_ERR:+ (${FL_PROFILE_ERR})}; keeping ${b}")
    fi
    EX_NAME+=("$n"); EX_REPO+=("$r"); EX_XREPO+=("$xr"); EX_CUR+=("$b"); EX_XBR+=("$xb"); EX_DEF+=("$def"); EX_VER+=("$ver")
    EX_ACC+=("$(fl_profile_access "$xr")"); EX_REQ+=("$req")
    if [[ "$xb" == "$b" ]]; then EX_COMMIT+=("$c"); else EX_COMMIT+=(""); fi
    if [[ "$drops" == *" ${n} "* ]]; then EX_KEEP+=(false); else EX_KEEP+=(true); fi
    case "${EX_ACC[$i]}" in
      personal) EX_WARN+=("${n}: ${xr} is in a personal GitHub account; teammates need to be added to it") ;;
      unknown) EX_WARN+=("${n}: could not tell whether ${xr} is public (offline, or not a GitHub style URL)") ;;
    esac
    i=$((i + 1))
  done
  for d in $drops; do
    by=""; j=0
    while [[ "$j" -lt "${#EX_NAME[@]}" ]]; do
      [[ "${EX_KEEP[$j]}" == "true" && " ${EX_REQ[$j]} " == *" ${d} "* ]] && by="${by}${by:+ }${EX_NAME[$j]}"
      j=$((j + 1))
    done
    if [[ -n "$by" ]]; then EX_BLOCKED+=("${d}"$'\t'"${by}"); EX_WARN+=("${d} cannot be dropped: ${by// /, } requires it"); fi
  done
  return 0
}

fl_profile_export_render() {
  local name="$1" i=0 req r sep
  printf '# Team profile %s, exported by benchbar %s on %s.\n' "$name" "${FL_VERSION:-0}" "$(date +%Y-%m-%d)"
  printf '# Add it with: benchbar profile import FILE_OR_HTTPS_URL\n'
  printf 'schema = 2\n'
  printf 'base = "%s"\n' "$FL_TEAM_BASE"
  [[ -n "$FL_TEAM_DESCRIPTION" ]] && printf 'description = "%s"\n' "$FL_TEAM_DESCRIPTION"
  [[ -n "$FL_TEAM_FRAPPE_BRANCH" ]] && printf 'frappe_branch = "%s"\n' "$FL_TEAM_FRAPPE_BRANCH"
  [[ -n "$FL_TEAM_BUNDLE" ]] && printf 'bundle = "%s"\n' "$FL_TEAM_BUNDLE"
  [[ -n "$FL_TEAM_SITE" ]] && printf 'site = "%s"\n' "$FL_TEAM_SITE"
  [[ -n "$FL_TEAM_SCHEDULER" ]] && printf 'scheduler = %s\n' "$FL_TEAM_SCHEDULER"
  printf 'exported_from = "benchbar %s, %s"\n' "${FL_VERSION:-0}" "$(date +%Y-%m-%d)"
  while [[ "$i" -lt "${#EX_NAME[@]}" ]]; do
    if [[ "${EX_KEEP[$i]}" == "true" ]]; then
      printf '\n[[apps]]\nname = "%s"\nrepo = "%s"\nbranch = "%s"\n' "${EX_NAME[$i]}" "${EX_XREPO[$i]}" "${EX_XBR[$i]}"
      [[ -n "${EX_COMMIT[$i]}" ]] && printf 'commit = "%s"\n' "${EX_COMMIT[$i]}"
      printf 'access = "%s"\n' "${EX_ACC[$i]}"
      req="${EX_REQ[$i]}"
      if [[ -n "$req" ]]; then
        printf 'requires = ['; sep=""
        for r in $req; do printf '%s"%s"' "$sep" "$r"; sep=", "; done
        printf ']\n'
      fi
    fi
    i=$((i + 1))
  done
}

# fl_profile_export_digest FILE: sha256 of what the plan read and showed,
# before any choice: the file, and each app's repo, exported URL, branches,
# access and requires. export --expect refuses a plan that moved on.
fl_profile_export_digest() {
  local i=0
  {
    fl_profile_file_digest "$1"
    while [[ "$i" -lt "${#EX_NAME[@]}" ]]; do
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${EX_NAME[$i]}" "${EX_REPO[$i]}" "${EX_XREPO[$i]}" "${EX_CUR[$i]}" "${EX_DEF[$i]}" "${EX_ACC[$i]}" "${EX_REQ[$i]}"
      i=$((i + 1))
    done
  } | shasum -a 256 | awk '{print $1}'
}

fl_profile_export_plan_json() {
  local name="$1" file="$2" i=0 sep="" w
  printf '{"schema_version":%d,"cli_version":"%s","name":%s,"base":%s,"apps":[' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$name")" "$(fl_json_str "$FL_TEAM_BASE")"
  while [[ "$i" -lt "${#EX_NAME[@]}" ]]; do
    # shellcheck disable=SC2086  # requires is a word list
    printf '%s{"name":%s,"repo":%s,"exported_repo":%s,"current_branch":%s,"exported_branch":%s,"default_branch":%s,"branch_verified":%s,"access":"%s","requires":%s,"keep":%s}' \
      "$sep" "$(fl_json_str "${EX_NAME[$i]}")" "$(fl_json_str "${EX_REPO[$i]}")" "$(fl_json_str "${EX_XREPO[$i]}")" "$(fl_json_str "${EX_CUR[$i]}")" \
      "$(fl_json_str "${EX_XBR[$i]}")" "$(fl_json_str "${EX_DEF[$i]}")" "${EX_VER[$i]}" "${EX_ACC[$i]}" "$(fl_profile_json_list ${EX_REQ[$i]})" "${EX_KEEP[$i]}"
    sep=","; i=$((i + 1))
  done
  printf '],"warnings":['
  sep=""
  for w in ${EX_WARN[@]+"${EX_WARN[@]}"}; do printf '%s%s' "$sep" "$(fl_json_str "$w")"; sep=","; done
  printf '],"digest":"%s"}\n' "$(fl_profile_export_digest "$file")"
}

fl_profile_export_print() {
  local i=0 rows=("App|Access|Branch|Requires|Keep") w
  while [[ "$i" -lt "${#EX_NAME[@]}" ]]; do
    rows+=("${EX_NAME[$i]}|${EX_ACC[$i]}|${EX_CUR[$i]} -> ${EX_XBR[$i]}$([[ "${EX_VER[$i]}" == "true" ]] || printf ' (not verified)')|${EX_REQ[$i]:--}|$([[ "${EX_KEEP[$i]}" == "true" ]] && printf yes || printf 'no (--drop)')")
    i=$((i + 1))
  done
  [[ "${#EX_NAME[@]}" -gt 0 ]] && fl_table "${rows[@]}"
  for w in ${EX_WARN[@]+"${EX_WARN[@]}"}; do fl_warn "$w"; done
  return 0
}

fl_cmd_profile_export() {
  local name="" out="" plan=0 overrides="" drops=" " a file tmp dropped=() i=0 kept=0 sep line code=0 expect=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --plan) plan=1; shift ;;
      --out) out="${2:-}"; shift 2 ;;
      --out=*) out="${1#*=}"; shift ;;
      --branch) overrides="${overrides} ${2:-=}"; shift 2 ;;
      --branch=*) overrides="${overrides} ${1#*=}"; shift ;;
      --drop) drops="${drops}${2:-} "; shift 2 ;;
      --drop=*) drops="${drops}${1#*=} "; shift ;;
      --expect) expect="${2:-}"; shift 2 || shift ;;
      --expect=*) expect="${1#*=}"; shift ;;
      -*) fl_die "Unknown option for profile export: $1" "Use: benchbar profile export NAME [--plan] [--out FILE] [--branch APP=BR]... [--drop APP]... [--expect DIGEST]" ;;
      *) [[ -z "$name" ]] && name="$1"; shift ;;
    esac
  done
  [[ -n "$name" ]] || fl_die "Usage: benchbar profile export NAME [--plan] [--out FILE] [--branch APP=BR]... [--drop APP]..."
  fl_profile_json_begin
  fl_profile_need "$name"
  file="$FL_PROFILE_FILE"
  fl_load_profile "$FL_TEAM_BASE"
  for a in $overrides; do
    [[ "$a" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*=[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || fl_die "--branch needs APP=BRANCH, got '${a}'."
    [[ " $(fl_profile_app_names) " == *" ${a%%=*} "* ]] || fl_die "--branch ${a}: ${name} has no app ${a%%=*}."
  done
  for a in $drops; do [[ " $(fl_profile_app_names) " == *" ${a} "* ]] || fl_die "--drop ${a}: ${name} has no app ${a}."; done
  fl_info "reading ${file} and asking git about ${#FL_TEAM_APPS[@]} repo(s) (read only)"
  fl_profile_export_plan "$overrides" "$drops"
  if [[ "$plan" == "1" ]]; then
    if [[ "${OPT_JSON:-0}" == "1" ]]; then fl_profile_export_plan_json "$name" "$file" >&3; else fl_profile_export_print; fi
    return 0
  fi
  if [[ -n "$expect" && "$expect" != "$(fl_profile_export_digest "$file")" ]]; then
    fl_die "The export plan changed since it was reviewed (the file, a default branch, access or requires). Nothing was written." \
      "Review it again: benchbar profile export ${name} --plan"
  fi
  if [[ "${#EX_BLOCKED[@]}" -gt 0 ]]; then
    fl_profile_export_print
    if [[ "${OPT_JSON:-0}" == "1" ]]; then
      {
        printf '{"schema_version":%d,"cli_version":"%s","error":%s,"blocked":[' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "an app you drop is required by an app you keep")"
        sep=""
        for line in "${EX_BLOCKED[@]}"; do
          # shellcheck disable=SC2086  # required_by is a word list
          printf '%s{"app":%s,"required_by":%s}' "$sep" "$(fl_json_str "${line%%$'\t'*}")" "$(fl_profile_json_list ${line#*$'\t'})"; sep=","
        done
        printf ']}\n'
      } >&3
    fi
    fl_die "Refused: an app you drop is required by an app you keep." "Keep it, or drop the apps that require it too."
  fi
  while [[ "$i" -lt "${#EX_NAME[@]}" ]]; do
    if [[ "${EX_KEEP[$i]}" == "true" ]]; then kept=$((kept + 1)); else dropped+=("${EX_NAME[$i]}"); fi
    i=$((i + 1))
  done
  out="$(fl_abs_path "${out:-${PWD}/${name}.toml}")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/benchbar-profile.XXXXXX")"
  fl_profile_export_render "$name" >"$tmp"
  fl_team_profile_read "$tmp" || { rm -f "$tmp"; fl_die "The exported profile would not parse: ${FL_TEAM_ERROR}"; }
  fl_profile_export_print
  fl_write_reviewed "$out" "$tmp" "the exported profile ${name}" || code=1
  rm -f "$tmp"
  [[ "$code" == "0" ]] || exit 1
  if [[ "${OPT_JSON:-0}" == "1" ]]; then
    printf '{"schema_version":%d,"cli_version":"%s","path":%s,"apps":%d,"dropped":%s}\n' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$out")" "$kept" \
      "$(fl_profile_json_list ${dropped[@]+"${dropped[@]}"})" >&3
  elif [[ "${FL_DRY_RUN:-0}" != "1" ]]; then
    fl_info "share it: commit ${out##*/} to your team's config repo (teammates: benchbar profile subscribe URL), or send the file (benchbar profile import FILE)"
  fi
}

fl_profile_app_names() {
  local spec out=""
  for spec in ${FL_TEAM_APPS[@]+"${FL_TEAM_APPS[@]}"}; do out="${out}${out:+ }${spec%%|*}"; done
  printf '%s' "$out"
}

# ---- import

# fl_profile_fetch_url URL: a GitHub page as its raw file (blob, gist)
fl_profile_fetch_url() {
  local u="${1%%#*}" blob='^https://github\.com/([^/]+)/([^/]+)/blob/(.+)$' gist='^https://gist\.github\.com/([^/]+)/([0-9a-fA-F]+)/?$'
  if [[ "$u" =~ $blob ]]; then printf 'https://raw.githubusercontent.com/%s/%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  elif [[ "$u" =~ $gist ]]; then printf 'https://gist.githubusercontent.com/%s/%s/raw' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else printf '%s' "$u"
  fi
}

# fl_profile_fetch SRC OUT: an https URL or a local file into OUT, 64 KB
# at most; 1 with FL_PROFILE_ERR set
fl_profile_fetch() {
  local src="$1" out="$2" url code=0 size
  FL_PROFILE_ERR=""
  case "$src" in
    https://*)
      [[ "$src" =~ ^https://[^/]*@ ]] && { FL_PROFILE_ERR="the URL carries a user name or token; use a URL without one"; return 1; }
      fl_profile_offline_mode && { FL_PROFILE_ERR="offline mode"; return 1; }
      url="$(fl_profile_fetch_url "$src")"
      curl -fsSL --proto '=https' --proto-redir '=https' --max-time 30 --max-filesize "$FL_PROFILE_MAX_BYTES" -o "$out" "$url" 2>/dev/null || code=$?
      [[ "$code" == "0" ]] || { FL_PROFILE_ERR="could not download ${url} (curl exit ${code})"; return 1; } ;;
    http://*) FL_PROFILE_ERR="only https URLs are fetched: ${src}"; return 1 ;;
    *://*) FL_PROFILE_ERR="only https URLs or a local file: ${src}"; return 1 ;;
    *)
      [[ -f "$src" ]] || { FL_PROFILE_ERR="no such file: ${src}"; return 1; }
      cp "$src" "$out" ;;
  esac
  size="$(wc -c <"$out" | tr -d ' ')"
  [[ "$size" -le "$FL_PROFILE_MAX_BYTES" ]] || { FL_PROFILE_ERR="larger than 64 KB (${size} bytes): not a profile"; return 1; }
  return 0
}

# fl_profile_with_source IN SOURCE OUT: IN with schema = 2 and source =
# SOURCE at the top (replacing its own)
fl_profile_with_source() {
  awk -v src="$2" '
    function head() { print "schema = 2"; print "source = \"" src "\""; done = 1 }
    !done && /^[ \t]*(#.*)?$/ { print; next }
    !done { head() }
    /^[ \t]*\[/ { intable = 1 }
    !intable && /^[ \t]*(schema|source)[ \t]*=/ { next }
    { print }
    END { if (!done) head() }' "$1" >"$3"
}

# fl_profile_prepare SRC NAME OUT: fetches SRC, adds its source, parses it
# into the FL_TEAM_* globals. Dies with the reason.
fl_profile_prepare() {
  local src="$1" out="$3" raw record
  case "$src" in
    https://*) record="$src" ;;
    *://*) record="$src" ;;
    *) record="$(fl_abs_path "$src")" ;;
  esac
  [[ "$record" != *\"* && "$record" != *\\* ]] || fl_die "The source may not hold a quote or a backslash: ${src}"
  raw="$(mktemp "${TMPDIR:-/tmp}/benchbar-profile.XXXXXX")"
  fl_profile_fetch "$record" "$raw" || { rm -f "$raw"; fl_die "Cannot import ${src}: ${FL_PROFILE_ERR}"; }
  fl_profile_with_source "$raw" "$record" "$out"
  rm -f "$raw"
  fl_team_profile_read "$out" || fl_die "${src} is not a valid team profile: ${FL_TEAM_ERROR}" "Nothing was written."
  FL_PROFILE_RECORD="$record"
}
FL_PROFILE_RECORD=""

fl_profile_import_apps_json() {
  local i=0 sep="" spec n b r c
  printf '['
  for spec in ${FL_TEAM_APPS[@]+"${FL_TEAM_APPS[@]}"}; do
    IFS='|' read -r n b r c <<<"$spec"
    # shellcheck disable=SC2086  # requires is a word list
    printf '%s{"name":%s,"repo":%s,"branch":%s,"access":%s,"requires":%s}' "$sep" "$(fl_json_str "$n")" "$(fl_json_str "$r")" "$(fl_json_str "$b")" \
      "$(fl_json_str "${FL_TEAM_APP_ACCESS[$i]:-}")" "$(fl_profile_json_list ${FL_TEAM_APP_REQUIRES[$i]:-})"
    sep=","; i=$((i + 1))
  done
  printf ']'
}

fl_cmd_profile_import() {
  local src="" name="" plan=0 expect="" tmp target exists=false diff="" other code=0 base re='^[^?#]*/([^/?#]+)\.toml([?#].*)?$'
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --as) name="${2:-}"; shift 2 ;;
      --as=*) name="${1#*=}"; shift ;;
      --plan) plan=1; shift ;;
      --expect) expect="${2:-}"; shift 2 || shift ;;
      --expect=*) expect="${1#*=}"; shift ;;
      -*) fl_die "Unknown option for profile import: $1" "Use: benchbar profile import FILE|URL [--as NAME] [--plan] [--expect DIGEST]" ;;
      *) [[ -z "$src" ]] && src="$1"; shift ;;
    esac
  done
  [[ -n "$src" ]] || fl_die "Usage: benchbar profile import FILE|URL [--as NAME] [--plan]"
  if [[ -z "$name" ]]; then
    base="${src##*/}"
    if [[ "$src" =~ $re ]]; then name="${BASH_REMATCH[1]}"; elif [[ "$src" != *://* && "$base" == *.toml ]]; then name="${base%.toml}"; fi
    [[ -n "$name" ]] || fl_die "Cannot tell the profile name from ${src}." "Pass one: --as NAME"
  fi
  fl_profile_json_begin
  fl_team_profile_valid_name "$name" || fl_die "Invalid profile name: '${name}'." "Pass another one with --as NAME (lower case letters, digits, '.', '_' and '-')."
  fl_builtin_profile_exists "$name" && fl_die "${name} is a built in profile; a team profile may not shadow it." "Pass another name: --as ${name}-team"
  tmp="$(mktemp "${TMPDIR:-/tmp}/benchbar-profile.XXXXXX")"
  fl_profile_prepare "$src" "$name" "$tmp"
  target="$(fl_team_profile_user_dir)/${name}.toml"
  if [[ -f "$target" ]]; then
    exists=true
    cmp -s "$target" "$tmp" || diff="$(diff -u "$target" "$tmp" | tail -n +3 || true)"
  fi
  other="$(fl_team_profile_file "$name" || true)"
  if [[ "$plan" == "1" ]]; then
    fl_profile_check_loaded
    if [[ "${OPT_JSON:-0}" == "1" ]]; then
      printf '{"schema_version":%d,"cli_version":"%s","name":%s,"source":%s,"exists":%s,"diff":%s,"base":%s,"apps":%s,"check":{"repos":%s},"skipped_apps":%s,"digest":"%s"}\n' \
        "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$name")" "$(fl_json_str "$FL_PROFILE_RECORD")" "$exists" "$(fl_profile_json_text "$diff")" \
        "$(fl_json_str "$FL_TEAM_BASE")" "$(fl_profile_import_apps_json)" "$(fl_profile_check_repos_json)" "$(fl_profile_json_list ${CK_SKIPPED[@]+"${CK_SKIPPED[@]}"})" \
        "$(fl_profile_file_digest "$tmp")" >&3
    else
      fl_info "${src}: team profile ${name}, base ${FL_TEAM_BASE}, ${#FL_TEAM_APPS[@]} app(s)$([[ "$exists" == true ]] && printf ', replaces %s' "$target")"
      [[ -n "$diff" ]] && printf '%s\n' "$diff" | sed 's/^/    /'
      fl_profile_check_print
    fi
    rm -f "$tmp"
    return 0
  fi
  if [[ -n "$expect" && "$expect" != "$(fl_profile_file_digest "$tmp")" ]]; then
    rm -f "$tmp"
    fl_die "${src} changed since it was reviewed. Nothing was imported." "Review it again: benchbar profile import ${src} --as ${name} --plan"
  fi
  fl_info "${src}: team profile ${name}, base ${FL_TEAM_BASE}, ${#FL_TEAM_APPS[@]} app(s)"
  fl_write_reviewed "$target" "$tmp" "team profile ${name}" || code=1
  rm -f "$tmp"
  [[ "$code" == "0" ]] || exit 1
  if [[ "${OPT_JSON:-0}" == "1" ]]; then
    printf '{"schema_version":%d,"cli_version":"%s","name":%s,"path":%s,"source":%s}\n' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" \
      "$(fl_json_str "$name")" "$(fl_json_str "$target")" "$(fl_json_str "$FL_PROFILE_RECORD")" >&3
    return 0
  fi
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && return 0
  [[ -n "$other" && "$other" != "$target" ]] && fl_warn "${target} now hides ${other} (the same name further down the lookup path)"
  fl_profile_check_loaded
  fl_profile_check_print
  fl_info "use it with: benchbar install --profile ${name}; later: benchbar profile update ${name}"
}

# ---- subscribe

# fl_profile_sub_dirname URL: owner-repo, the folder under sources/
fl_profile_sub_dirname() {
  local p repo rest owner
  p="${1%/}"; p="${p%.git}"
  repo="${p##*/}"; rest="${p%/*}"
  [[ "$rest" == "$p" ]] && rest="${p%:*}"
  owner="${rest##*/}"; owner="${owner##*:}"
  printf '%s-%s' "$owner" "$repo" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^[.-]+//'
}

fl_profile_sub_stamp() { local f="${1}/.git/benchbar-${2}"; [[ -f "$f" ]] && tr -d '[:space:]' <"$f"; return 0; }
fl_profile_sub_stamp_set() { [[ -d "${1}/.git" ]] && date +%s >"${1}/.git/benchbar-${2}"; return 0; }

# fl_profile_sub_fetch DIR: git fetch, 10 seconds at most; stamps the try
# and, when it worked, the fetch
fl_profile_sub_fetch() {
  local out code=0
  fl_profile_sub_stamp_set "$1" tried
  fl_profile_offline_mode && { FL_PROFILE_ERR="offline mode"; return 1; }
  out="$(mktemp "${TMPDIR:-/tmp}/benchbar-net.XXXXXX")"
  fl_profile_timed "$FL_PROFILE_NET_SECS" "$out" fl_profile_git_net -C "$1" fetch --quiet --no-tags || code=$?
  rm -f "$out"
  [[ "$code" == "0" ]] && fl_profile_sub_stamp_set "$1" fetched
  return "$code"
}

# fl_profile_sub_behind DIR: "BEHIND DAYS" from the last fetch (no
# network): commits the clone lacks, and the age in days of the oldest
fl_profile_sub_behind() {
  local n oldest
  fl_profile_git "$1" rev-parse -q --verify '@{upstream}' >/dev/null 2>&1 || return 0
  n="$(fl_profile_git "$1" rev-list --count 'HEAD..@{upstream}' 2>/dev/null || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || return 0
  if [[ "$n" == "0" ]]; then printf '0 0\n'; return 0; fi
  oldest="$(fl_profile_git "$1" log --format=%ct 'HEAD..@{upstream}' 2>/dev/null | tail -n1 || true)"
  [[ "$oldest" =~ ^[0-9]+$ ]] || { printf '%s\n' "$n"; return 0; }
  printf '%s %s\n' "$n" "$(( ($(date +%s) - oldest) / 86400 ))"
}

fl_cmd_profile_subscribe() {
  local url="" plan=0 name dir tmp names="" n f valid=() code=0 sub
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --plan) plan=1; shift ;;
      -*) fl_die "Unknown option for profile subscribe: $1" "Use: benchbar profile subscribe GIT_URL [--plan] [--yes]" ;;
      *) [[ -z "$url" ]] && url="$1"; shift ;;
    esac
  done
  [[ -n "$url" ]] || fl_die "Usage: benchbar profile subscribe GIT_URL [--plan] [--yes]"
  fl_profile_json_begin
  case "$url" in
    https://*|ssh://*|file://*) ;;
    http://*) fl_die "Only https, ssh or file URLs: ${url}" ;;
    *://*|-*|*[[:space:]]*) fl_die "Not a git URL: ${url}" "Use https://host/team/config.git or git@host:team/config.git" ;;
    *) [[ "$url" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9][A-Za-z0-9._-]*:.+ ]] || fl_die "Not a git URL: ${url}" "Use https://host/team/config.git or git@host:team/config.git" ;;
  esac
  [[ "$url" =~ ^https://[^/]*@ ]] && fl_die "The URL carries a user name or token." "Subscribe with the plain URL; git uses your credential helper or SSH key."
  name="$(fl_profile_sub_dirname "$url")"
  [[ -n "$name" ]] || fl_die "Cannot name a folder for ${url}."
  dir="$(fl_profile_sources_dir)/${name}"
  if sub="$(fl_profile_subscription_named "$url")"; then
    dir="${sub##*$'\t'}"
    fl_ok "unchanged: already subscribed to ${url} (${dir}); benchbar profile update --all fetches it again"
    # shellcheck disable=SC2046  # the names are words
    fl_profile_sub_json "$url" "$dir" $(fl_profile_sub_names "$dir")
    return 0
  fi
  [[ -e "$dir" ]] && fl_die "${dir} exists but is not in $(fl_profile_sources_list)." "Move it aside, then subscribe again."
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/benchbar-sub.XXXXXX")"
  fl_info "cloning ${url} (only its *.toml files are read, nothing in it runs)"
  fl_profile_timed 120 "$tmp.out" fl_profile_git_net clone --quiet --no-tags --single-branch -- "$url" "$tmp/clone" || code=$?
  rm -f "$tmp.out"
  if [[ "$code" != "0" ]]; then
    rm -rf "${tmp:?}"
    fl_die "Cannot clone ${url}: ${FL_PROFILE_ERR:-git exited with ${code}}" "Check the URL and that git can read it: git ls-remote ${url}"
  fi
  for f in "$(fl_profile_sub_profdir "$tmp/clone")"/*.toml; do
    [[ -f "$f" ]] || continue
    n="$(basename "$f" .toml)"
    if ! fl_team_profile_valid_name "$n"; then fl_warn "${n}.toml: not a valid profile name, ignored"; continue; fi
    if fl_builtin_profile_exists "$n"; then fl_warn "${n}.toml: shadows a built in profile, ignored"; continue; fi
    if ! fl_team_profile_read "$f"; then fl_warn "${n}.toml is invalid: ${FL_TEAM_ERROR}"; continue; fi
    valid+=("$n"); names="${names}${names:+, }${n}"
  done
  if [[ "${#valid[@]}" -eq 0 ]]; then
    rm -rf "${tmp:?}"
    fl_die "${url} holds no valid team profile (*.toml at its root, or in profiles/)." "Nothing was subscribed."
  fi
  if [[ "$plan" == "1" || "${FL_DRY_RUN:-0}" == "1" ]]; then
    rm -rf "${tmp:?}"
    fl_info "${url} has ${#valid[@]} profile(s): ${names}; subscribing clones it into ${dir}"
    fl_profile_sub_json "$url" "$dir" "${valid[@]}"
    return 0
  fi
  if ! fl_confirm "Subscribe to ${url}? Its profiles (${names}) join the lookup path; nothing updates without you."; then
    rm -rf "${tmp:?}"
    fl_warn "Cancelled. Nothing was subscribed."
    exit 1
  fi
  mkdir -p "$(fl_profile_sources_dir)"
  mv "$tmp/clone" "$dir"
  rm -rf "${tmp:?}"
  printf '%s\t%s\n' "$name" "$url" >>"$(fl_profile_sources_list)"
  fl_profile_sub_stamp_set "$dir" tried; fl_profile_sub_stamp_set "$dir" fetched
  fl_log "subscribed: ${url} -> ${dir}"
  fl_ok "subscribed to ${url}: ${names}"
  for n in "${valid[@]}"; do
    f="$(fl_team_profile_file "$n" || true)"
    [[ "$f" != "$(fl_profile_sub_profdir "$dir")/${n}.toml" ]] && fl_warn "${n}: ${f} comes first on the lookup path and hides this one"
  done
  [[ "${OPT_JSON:-0}" == "1" ]] || fl_info "use one with: benchbar install --profile ${valid[0]}; later: benchbar profile update --all"
  fl_profile_sub_json "$url" "$dir" "${valid[@]}"
}

# fl_profile_sub_json URL DIR NAME...: the subscribe document, with --json
fl_profile_sub_json() {
  [[ "${OPT_JSON:-0}" == "1" ]] || return 0
  local url="$1" dir="$2"
  shift 2
  printf '{"schema_version":%d,"cli_version":"%s","repo":%s,"dir":%s,"profiles":%s}\n' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" \
    "$(fl_json_str "$url")" "$(fl_json_str "$dir")" "$(fl_profile_json_list "$@")" >&3
}

# ---- update

UP_KIND=(); UP_NAME=(); UP_PATH=(); UP_BEHIND=(); UP_DIFF=(); UP_NEW=()

# fl_profile_update_add KIND NAME PATH: fetches again and fills UP_* (the
# new file of an import, the new commits of a subscription); never applies
fl_profile_update_add() {
  local kind="$1" name="$2" path="$3" src tmp="" raw diff="" behind="" _days to=""
  if [[ "$kind" == "imported" ]]; then
    src="$(fl_profile_file_source "$path")"
    tmp="$(mktemp "${TMPDIR:-/tmp}/benchbar-profile.XXXXXX")"
    raw="$(mktemp "${TMPDIR:-/tmp}/benchbar-profile.XXXXXX")"
    if ! fl_profile_fetch "$src" "$raw"; then
      fl_warn "${name}: cannot fetch ${src}: ${FL_PROFILE_ERR}"; rm -f "$raw" "$tmp"; tmp=""
    else
      fl_profile_with_source "$raw" "$src" "$tmp"; rm -f "$raw"
      if ! fl_team_profile_read "$tmp"; then
        fl_warn "${name}: ${src} no longer parses (${FL_TEAM_ERROR}); keeping ${path}"; rm -f "$tmp"; tmp=""
      elif ! cmp -s "$path" "$tmp"; then
        diff="$(diff -u "$path" "$tmp" | tail -n +3 || true)"
      fi
    fi
  else
    fl_profile_sub_fetch "$path" || fl_warn "${name}: cannot fetch: ${FL_PROFILE_ERR}; showing the last fetch"
    read -r behind _days <<<"$(fl_profile_sub_behind "$path")"
    to="$(fl_profile_git "$path" rev-parse -q --verify '@{upstream}' 2>/dev/null || true)"
    [[ "${behind:-0}" =~ ^[1-9] ]] && diff="$(fl_profile_git "$path" diff "HEAD..${to}" -- '*.toml' 2>/dev/null || true)"
  fi
  UP_KIND+=("$kind"); UP_NAME+=("$name"); UP_PATH+=("$path"); UP_BEHIND+=("$behind"); UP_DIFF+=("$diff"); UP_NEW+=("$tmp"); UP_TO+=("$to")
}

# fl_profile_file_digest FILE: sha256 of what would be written, so an apply
# can refuse content that changed after the plan showed it
fl_profile_file_digest() { shasum -a 256 "$1" | awk '{print $1}'; }

# fl_profile_update_digest: one digest over every update's reviewed state:
# the fetched file of an import, the upstream commit of a subscription
fl_profile_update_digest() {
  local i=0
  while [[ "$i" -lt "${#UP_NAME[@]}" ]]; do
    printf '%s\t%s\t%s\n' "${UP_KIND[$i]}" "${UP_NAME[$i]}" \
      "$(if [[ -n "${UP_NEW[$i]}" ]]; then fl_profile_file_digest "${UP_NEW[$i]}"; else printf '%s' "${UP_TO[$i]:--}"; fi)"
    i=$((i + 1))
  done | shasum -a 256 | awk '{print $1}'
}

fl_profile_update_json() {
  local applied="$1" i=0 sep=""
  printf '{"schema_version":%d,"cli_version":"%s","updates":[' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}"
  while [[ "$i" -lt "${#UP_NAME[@]}" ]]; do
    printf '%s{"name":%s,"kind":"%s","behind":%s,"diff":%s}' "$sep" "$(fl_json_str "${UP_NAME[$i]}")" "${UP_KIND[$i]}" \
      "$(fl_json_num "${UP_BEHIND[$i]}")" "$(fl_profile_json_text "${UP_DIFF[$i]}")"
    sep=","; i=$((i + 1))
  done
  printf '],"digest":"%s"' "$(fl_profile_update_digest)"
  [[ -n "$applied" ]] && printf ',"applied":%s' "$applied"
  printf '}\n'
}

fl_cmd_profile_update() {
  local target="" all=0 plan=0 f n sub sname surl sdir i=0 applied=true code=0 udir expect="" to=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --all) all=1; shift ;;
      --plan) plan=1; shift ;;
      --expect) expect="${2:-}"; shift 2 || shift ;;
      --expect=*) expect="${1#*=}"; shift ;;
      -*) fl_die "Unknown option for profile update: $1" "Use: benchbar profile update NAME|--all [--plan] [--expect DIGEST]" ;;
      *) [[ -z "$target" ]] && target="$1"; shift ;;
    esac
  done
  [[ -n "$target" || "$all" == "1" ]] || fl_die "Usage: benchbar profile update NAME|--all [--plan]"
  fl_profile_json_begin
  UP_KIND=(); UP_NAME=(); UP_PATH=(); UP_BEHIND=(); UP_DIFF=(); UP_NEW=(); UP_TO=()
  udir="$(fl_team_profile_user_dir)"
  if [[ "$all" == "1" ]]; then
    for f in "$udir"/*.toml; do
      if [[ -f "$f" ]] && fl_profile_file_source "$f" >/dev/null; then fl_profile_update_add imported "$(basename "$f" .toml)" "$f"; fi
    done
    while IFS=$'\t' read -r sname surl; do
      fl_profile_update_add subscribed "$sname" "$(fl_profile_sources_dir)/${sname}"
    done < <(fl_profile_subscriptions)
  elif sub="$(fl_profile_subscription_named "$target")"; then
    IFS=$'\t' read -r sname surl sdir <<<"$sub"
    fl_profile_update_add subscribed "$target" "$sdir"
  else
    fl_team_profile_valid_name "$target" || fl_die "Invalid profile name: '${target}'."
    f="$(fl_team_profile_file "$target")" || fl_die "No team profile '${target}'." "benchbar profile list shows the team profiles."
    if [[ "$(dirname "$f")" == "$udir" ]] && fl_profile_file_source "$f" >/dev/null; then
      fl_profile_update_add imported "$target" "$f"
    elif sub="$(fl_profile_subscription_of "$f")"; then
      IFS=$'\t' read -r sname surl sdir <<<"$sub"
      fl_profile_update_add subscribed "$target" "$sdir"
    else
      fl_die "${target} (${f}) was not imported or subscribed: there is nothing to update it from." "Edit the file itself, or import it: benchbar profile import URL --as ${target}"
    fi
  fi
  if [[ "$plan" == "1" ]]; then
    while [[ "$i" -lt "${#UP_NAME[@]}" ]]; do
      if [[ -n "${UP_DIFF[$i]}" ]]; then
        fl_info "${UP_NAME[$i]} (${UP_KIND[$i]}): $([[ -n "${UP_BEHIND[$i]}" ]] && printf '%s commit(s) behind, ' "${UP_BEHIND[$i]}")changes:"
        printf '%s\n' "${UP_DIFF[$i]}" | sed 's/^/    /'
      else
        fl_ok "${UP_NAME[$i]} (${UP_KIND[$i]}): up to date"
      fi
      i=$((i + 1))
    done
    if [[ "${OPT_JSON:-0}" == "1" ]]; then fl_profile_update_json "" >&3; fi
    i=0; while [[ "$i" -lt "${#UP_NAME[@]}" ]]; do [[ -n "${UP_NEW[$i]}" ]] && rm -f "${UP_NEW[$i]}"; i=$((i + 1)); done
    return 0
  fi
  if [[ -n "$expect" && "$expect" != "$(fl_profile_update_digest)" ]]; then
    i=0; while [[ "$i" -lt "${#UP_NAME[@]}" ]]; do [[ -n "${UP_NEW[$i]}" ]] && rm -f "${UP_NEW[$i]}"; i=$((i + 1)); done
    fl_die "The update changed since it was reviewed (the source has newer content). Nothing was changed." \
      "Review it again: benchbar profile update ${target:---all} --plan"
  fi
  while [[ "$i" -lt "${#UP_NAME[@]}" ]]; do
    n="${UP_NAME[$i]}"
    if [[ "${UP_KIND[$i]}" == "imported" ]]; then
      if [[ -n "${UP_NEW[$i]}" ]]; then
        fl_write_reviewed "${UP_PATH[$i]}" "${UP_NEW[$i]}" "team profile ${n}" || { applied=false; code=1; }
        rm -f "${UP_NEW[$i]}"
      fi
    elif [[ -n "${UP_DIFF[$i]}" ]]; then
      printf '\n%s%s: %s new commit(s)%s\n' "$FL_BOLD" "$n" "${UP_BEHIND[$i]}" "$FL_RESET"
      printf '%s\n' "${UP_DIFF[$i]}" | sed 's/^/    /'
      if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
        fl_info "dry-run: nothing was changed"
      elif fl_confirm "Fast forward ${UP_PATH[$i]} to these commits?"; then
        to="${UP_TO[$i]}"; [[ -n "$to" ]] || to='@{upstream}'
        if fl_profile_git "${UP_PATH[$i]}" merge --ff-only --quiet "$to" >/dev/null 2>&1; then
          fl_ok "${n}: updated (${UP_PATH[$i]})"
        else
          fl_fail "${n}: not a fast forward; ${UP_PATH[$i]} has changes of its own"
          fl_fix "benchbar profile remove ${n}, then subscribe again"
          applied=false; code=1
        fi
      else
        fl_warn "Cancelled. ${n} was not updated."; applied=false; code=1
      fi
    else
      fl_ok "${n} (${UP_KIND[$i]}): up to date"
    fi
    i=$((i + 1))
  done
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && applied=false
  if [[ "${OPT_JSON:-0}" == "1" ]]; then fl_profile_update_json "$applied" >&3; fi
  [[ "$code" == "0" ]] || exit 1
}

# ---- remove

fl_cmd_profile_remove() {
  local name="" f sub sname="" surl sdir what="" dest moved udir list
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -*) fl_die "Unknown option for profile remove: $1" "Use: benchbar profile remove NAME" ;;
      *) [[ -z "$name" ]] && name="$1"; shift ;;
    esac
  done
  [[ -n "$name" ]] || fl_die "Usage: benchbar profile remove NAME"
  fl_profile_json_begin
  udir="$(fl_team_profile_user_dir)"
  dest="$(fl_profile_removed_dir)/$(date +%Y%m%d-%H%M%S)"
  if sub="$(fl_profile_subscription_named "$name")"; then
    IFS=$'\t' read -r sname surl sdir <<<"$sub"
  else
    fl_team_profile_valid_name "$name" || fl_die "Invalid profile name: '${name}'."
    f="$(fl_team_profile_file "$name")" || fl_die "No team profile '${name}'." "benchbar profile list shows the team profiles."
    if [[ "$(dirname "$f")" == "$udir" ]] && fl_profile_file_source "$f" >/dev/null; then
      what="$f"
    elif sub="$(fl_profile_subscription_of "$f")"; then
      IFS=$'\t' read -r sname surl sdir <<<"$sub"
    elif [[ "$(dirname "$f")" == "$udir" ]]; then
      fl_die "${f} is your own file, not an import." "benchbar removes only what import or subscribe added; move the file aside yourself."
    else
      fl_die "${f} comes from BENCHBAR_PROFILE_PATH." "Take its folder out of BENCHBAR_PROFILE_PATH instead."
    fi
  fi
  if [[ -n "$sname" ]]; then
    what="$sdir"
    fl_info "unsubscribe from ${surl}: ${sdir} goes, and with it $(fl_profile_sub_names "$sdir" | sed 's/ /, /g')"
  fi
  moved="${dest}/$(basename "$what")"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would move ${what} to ${moved}"
    return 0
  fi
  fl_confirm "Move ${what} aside to ${dest}/?" || { fl_warn "Cancelled. Nothing was moved."; exit 1; }
  mkdir -p "$dest"
  mv "$what" "$moved"
  if [[ -n "$sname" ]]; then
    list="$(fl_profile_sources_list)"
    awk -F '\t' -v n="$sname" '$1 != n' "$list" >"${list}.new"
    mv "${list}.new" "$list"
  fi
  fl_log "profile remove: ${what} -> ${moved}"
  fl_ok "moved ${what} to ${moved}"
  if [[ "${OPT_JSON:-0}" == "1" ]]; then
    printf '{"schema_version":%d,"cli_version":"%s","name":%s,"moved_to":%s}\n' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" \
      "$(fl_json_str "$name")" "$(fl_json_str "$moved")" >&3
  fi
}

# ---- doctor

# profile_outdated: the bench's team profile comes from a subscription
# that is behind, as of the clone's last fetch. Doctor stays read only: it
# fetches only with --fetch (FL_FETCH=1), never in a dry run or offline.
chk_profile_outdated() {
  local team file sub _sname surl sdir fetched behind="" days="" note=""
  team="$(fl_bstate_get TEAM_PROFILE 2>/dev/null || true)"
  [[ -n "$team" ]] || { chk__set ok "the bench follows no team profile"; return 0; }
  file="$(fl_team_profile_file "$team" 2>/dev/null || true)"
  [[ -n "$file" ]] || { chk__set ok "team profile ${team} is not on the lookup path"; return 0; }
  sub="$(fl_profile_subscription_of "$file" || true)"
  [[ -n "$sub" ]] || { chk__set ok "team profile ${team} is not from a subscription"; return 0; }
  IFS=$'\t' read -r _sname surl sdir <<<"$sub"
  if [[ "${FL_FETCH:-0}" == "1" && "${FL_DRY_RUN:-0}" != "1" ]] && ! fl_profile_offline_mode; then
    fl_profile_sub_fetch "$sdir" >/dev/null 2>&1 || true
  fi
  fetched="$(fl_profile_sub_stamp "$sdir" fetched)"
  if [[ ! "$fetched" =~ ^[0-9]+$ ]]; then
    note=" (as of your last git fetch; run benchbar doctor --fetch to check the remote)"
  elif [[ $(($(date +%s) - fetched)) -ge 86400 ]]; then
    note=" (as of a fetch $(fl_age_words "$fetched"); run benchbar doctor --fetch to check the remote)"
  fi
  read -r behind days <<<"$(fl_profile_sub_behind "$sdir")"
  if [[ "${behind:-0}" =~ ^[1-9] ]]; then
    chk__set warn "team profile ${team} is ${behind} commit(s)${days:+, ${days} day(s),} behind ${surl}${note}" "benchbar profile update ${team}"
  else
    chk__set ok "team profile ${team} is up to date with ${surl}${note}"
  fi
}

fl_cmd_profile() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    list|"") fl_cmd_profile_list "$OPT_JSON" ;;
    show) fl_cmd_profile_show "${1:-}" ;;
    create) fl_cmd_profile_create "$@" ;;
    export) fl_cmd_profile_export "$@" ;;
    import) fl_cmd_profile_import "$@" ;;
    subscribe) fl_cmd_profile_subscribe "$@" ;;
    update) fl_cmd_profile_update "$@" ;;
    remove) fl_cmd_profile_remove "$@" ;;
    check) fl_cmd_profile_check "${1:-}" ;;
    *) fl_die "Unknown profile command: ${sub}" "Use: benchbar profile list | show | create | export | import | subscribe | update | remove | check" ;;
  esac
}
