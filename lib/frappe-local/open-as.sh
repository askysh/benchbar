#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# open-as.sh: a site in the browser, signed in as any of its users.
#
#   benchbar open [--site S] [--as USER] [--path P] [--no-browser] [--print-url] [--json]
#   benchbar users [--site S] [--search Q] [--limit N] [--json]
#   benchbar site open-as on|off|status [NAME] [--json]
#
# --as and users work only on a site the person turned Open as on for
# (site open-as on, kept in benchbar's state for the bench, never in
# sites/). Plain open needs no opt-in.
#
# open --as starts a Frappe session for USER the way `bench browse --user`
# does, then opens /login?redirect-to=PATH&sid=SID&t=MS: frappe sets the
# cookie and answers 301 to PATH, so the session id leaves the address bar.
# Browsers cache a 301, so t= makes every link a new one.
#
# The session id is a credential. It travels from the bench's Python to
# this process on a pipe and leaves only on the opener's command line or,
# with --print-url, on stdout. Neither command opens a run log (they are
# not in the dispatcher's fl_log_init list) and --json leaves the url out
# unless --print-url asks for it. Text that holds it is split with
# parameter expansion, never a here-string: bash 3.2 writes a here-string
# to a file in /var/tmp.

# The steps of frappe's LoginManager.post_login (auth.py) without
# set_user_info: that one only sets the response cookies, which the
# browser's own /login?sid= request sets, and computes the default page by
# importing every app (six of the seven seconds of a login on a bench with
# Insights). on_login hooks, the IP and hour restrictions and the session
# itself run as in a real login.
FL_PY_OPEN_AS='import sys
site, user = sys.argv[2], sys.argv[3]
def say(tag, *fields):
    clean = [str(f or "").replace("\t", " ").replace("\r", " ").replace("\n", " ") for f in fields]
    print("\n" + tag + " " + "\t".join(clean), flush=True)
import frappe
from frappe.auth import CookieManager, LoginManager, validate_ip_address
frappe.init(site=site)
frappe.connect()
try:
    if not frappe.conf.developer_mode:
        say("BENCHBAR-ERROR", site + " is not in developer mode, so benchbar will not sign in as another user.")
        sys.exit(1)
    row = frappe.db.get_value("User", user, ["name", "enabled", "first_name", "last_name", "user_type"], as_dict=True)
    if not row:
        say("BENCHBAR-ERROR", "No user " + repr(user) + " on " + site + ".")
        sys.exit(1)
    if not row.enabled:
        say("BENCHBAR-ERROR", row.name + " is disabled on " + site + ".")
        sys.exit(1)
    frappe.utils.set_request(path="/")
    frappe.local.cookie_manager = CookieManager()
    login = LoginManager()
    login.user = row.name
    try:
        login.run_trigger("on_login")
        validate_ip_address(row.name)
        login.validate_hour()
        login.get_user_info()
        login.full_name = " ".join(filter(None, [row.first_name, row.last_name]))
        login.make_session()
        login.setup_boot_cache()
    except frappe.AuthenticationError as e:
        say("BENCHBAR-ERROR", "Frappe refused the login: " + (str(e) or "not allowed"))
        sys.exit(1)
    frappe.db.commit()
    say("BENCHBAR-RESULT", row.name, login.full_name or row.name, row.user_type, frappe.session.sid)
finally:
    frappe.destroy()'

# Enabled users for a picker: System Users first, then by last login.
# Each user's roles come rarest first (held by the fewest users), so the
# five shown say what sets the user apart: "Network Executive" before
# "Employee". The automatic roles (All, Guest, Desk User) say nothing about
# a user and are left out of roles and role_count. MODE json prints one JSON
# line; MODE table prints "more" (0 or 1) and then one row per user.
FL_PY_USERS='import sys, json
site, query, limit, mode = sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
import frappe
frappe.init(site=site)
frappe.connect()
try:
    or_filters = None
    if query:
        like = "%" + query + "%"
        or_filters = [["name", "like", like], ["full_name", "like", like]]
    rows = frappe.get_all("User", filters={"enabled": 1, "name": ["!=", "Guest"]}, or_filters=or_filters,
        fields=["name", "full_name", "user_type", "last_login"], order_by="user_type asc, last_login desc, name asc",
        limit_page_length=limit + 1)
    more = len(rows) > limit
    rows = rows[:limit]
    roles = {}
    if rows:
        holders = {r.role: r.n for r in frappe.get_all("Has Role", filters={"parenttype": "User"},
            fields=["role", "count(distinct parent) as n"], group_by="role")}
        for r in frappe.get_all("Has Role", filters={"parenttype": "User", "parent": ["in", [u.name for u in rows]],
                "role": ["not in", ["All", "Guest", "Desk User"]]}, fields=["parent", "role"]):
            roles.setdefault(r.parent, []).append(r.role)
        for held in roles.values():
            held.sort(key=lambda role: (holders.get(role, 0), role))
    users = [{"name": u.name, "full_name": u.full_name or u.name, "user_type": u.user_type,
        "roles": roles.get(u.name, [])[:5], "role_count": len(roles.get(u.name, [])),
        "last_login": str(u.last_login) if u.last_login else None} for u in rows]
    if mode == "json":
        print("\nBENCHBAR-RESULT " + json.dumps({"users": users, "truncated": more}), flush=True)
    else:
        print("\nBENCHBAR-RESULT " + ("1" if more else "0"), flush=True)
        for u in users:
            print("\nBENCHBAR-RESULT " + "\t".join(" ".join(str(v).split()) for v in
                (u["name"], u["full_name"], u["user_type"], ", ".join(u["roles"])
                 + (" +" + str(u["role_count"] - 5) if u["role_count"] > 5 else ""))), flush=True)
finally:
    frappe.destroy()'

# fl_bench_python_v VAR SNIPPET MARKER ARGS...: runs SNIPPET in the bench's
# Python inside sites/ (where bench runs frappe) and puts its
# "BENCHBAR-RESULT " lines into VAR, one per line. A "BENCHBAR-ERROR " line
# stops the command with its text; any other failure with the last line
# the program wrote (a traceback ends with the error).
fl_bench_python_v() {
  local __var="$1" __snippet="$2" __out __code=0 __line __rest __result="" __error="" __last=""
  shift 2
  [[ -x "${FL_BENCH_DIR}/env/bin/python" ]] || fl_die "The bench has no env/bin/python." "Run: benchbar repair"
  __out="$(fl__in_dir "${FL_BENCH_DIR}/sites" "${FL_BENCH_DIR}/env/bin/python" -c "$__snippet" "$@" 2>&1)" || __code=$?
  __rest="$__out"
  while [[ -n "$__rest" ]]; do
    __line="${__rest%%$'\n'*}"
    if [[ "$__rest" == *$'\n'* ]]; then __rest="${__rest#*$'\n'}"; else __rest=""; fi
    case "$__line" in
      "BENCHBAR-RESULT "*) __result="${__result:+${__result}$'\n'}${__line#BENCHBAR-RESULT }" ;;
      "BENCHBAR-ERROR "*) __error="${__line#BENCHBAR-ERROR }" ;;
      *[![:space:]]*) __last="$__line" ;;
    esac
  done
  [[ -z "$__error" ]] || fl_die "$__error"
  [[ "$__code" == "0" ]] || fl_die "The bench's Python stopped: ${__last:-exit ${__code}}" "Check the bench with: benchbar doctor"
  printf -v "$__var" '%s' "$__result"
}

# fl_urlencode_v VAR TEXT: every byte but the unreserved ones of RFC 3986 as %XX
fl_urlencode_v() {
  local LC_ALL=C __in="$2" __out="" __c __i
  for ((__i = 0; __i < ${#__in}; __i++)); do
    __c="${__in:__i:1}"
    case "$__c" in
      [a-zA-Z0-9.~_-]) __out="${__out}${__c}" ;;
      # bash 3.2 sign extends a byte above 127 ('\xc3' is -61), so mask it
      *) printf -v __c '%d' "'$__c"; printf -v __c '%%%02X' $((__c & 255)); __out="${__out}${__c}" ;;
    esac
  done
  printf -v "$1" '%s' "$__out"
}

# fl_path_without_sid_v VAR PATH: PATH without any sid= query parameter, so
# a page copied from the address bar never brings an old session along
fl_path_without_sid_v() {
  local __p="$2" __frag="" __query="" __kept="" __part
  if [[ "$__p" == *"#"* ]]; then __frag="#${__p#*#}"; __p="${__p%%#*}"; fi
  if [[ "$__p" == *"?"* ]]; then __query="${__p#*\?}"; __p="${__p%%\?*}"; fi
  while [[ -n "$__query" ]]; do
    __part="${__query%%&*}"
    if [[ "$__query" == *"&"* ]]; then __query="${__query#*&}"; else __query=""; fi
    [[ -z "$__part" || "$__part" == sid || "$__part" == sid=* ]] || __kept="${__kept:+${__kept}&}${__part}"
  done
  printf -v "$1" '%s' "${__p}${__kept:+?${__kept}}${__frag}"
}

# fl_open_as_require_reachable SITE: the bench answers and the browser can
# find SITE by name (a hosts line, or a *.localhost name, which resolves
# without one). In WSL the browser is Windows', which reads its own hosts
# file and not the distro's, so only localhost names are sure to reach it.
fl_open_as_require_reachable() {
  if [[ -z "$(fl_port_listener_pid "$FL_WEB_PORT")" || -z "$(fl_port_listener_pid "$FL_REDIS_CACHE_PORT")" ]]; then
    fl_die "The bench is not running." "Start it first: benchup"
  fi
  if [[ "$1" != localhost && "$1" != *.localhost ]] && ! fl_hosts_has_name "$1"; then
    fl_die "$1 has no hosts line, so the browser cannot reach it." "Add it: benchbar site hosts"
  fi
}

# fl_open_as_require_enabled SITE: the person turned Open as on for SITE
fl_open_as_require_enabled() {
  fl_open_as_enabled "$1" && return 0
  fl_die "Open as is off for $1: nobody has turned password-less sign in on for this site." \
    "If you want it, run in a terminal: benchbar site open-as on $1"
}

# fl_open_as_require_served SITE: the bench's web process answers as SITE.
# `bench serve` without --site serves the default_site of
# common_site_config.json for every Host, so a session made on any other
# site is unknown to the site the browser reaches, which then shows the
# login page.
fl_open_as_require_served() {
  local served
  fl_site_config_value_v served default_site
  [[ -z "$served" || "$served" == "$1" ]] && return 0
  fl_die "Port ${FL_WEB_PORT} serves only ${served}, the bench's default site, so a sign-in on $1 would land logged out." \
    "Open as works on ${served}. To use $1: benchbar site default $1, then benchrestart"
}

fl_cmd_open() {
  local user="" path="" browser=1 print_url=0 site="$FL_SITE" fields name="" full_name="" user_type="" sid="" url base enc opened=false j
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --as) [[ -n "${2:-}" ]] || fl_die "--as needs a user." "Example: benchbar open --as someone@example.com"; user="$2"; shift 2 ;;
      --as=*) user="${1#*=}"; shift ;;
      --path) [[ "$#" -ge 2 ]] || fl_die "--path needs a page." "Example: --path /app/todo"; path="$2"; shift 2 ;;
      --path=*) path="${1#*=}"; shift ;;
      --no-browser) browser=0; shift ;;
      --print-url) print_url=1; browser=0; shift ;;
      *) fl_die "Unknown argument for open: $1" "Use: benchbar open [--site NAME] [--as USER] [--path /app/...] [--no-browser] [--print-url] [--json]" ;;
    esac
  done
  fl_require_bench
  [[ -n "$site" ]] || fl_die "This bench has no default site." "Pass --site NAME (benchbar site list shows them)"
  fl_site_require "$site"
  [[ -z "$user" ]] || fl_open_as_require_enabled "$site"
  fl_open_as_require_reachable "$site"
  if [[ -n "$user" ]]; then
    fl_open_as_require_served "$site"
    # in WSL wslview opens a Windows browser, which reads Windows' hosts file, not the distro's;
    # with --print-url or --no-browser the person (or the tray) opens the link and knows the name
    if [[ "$browser" == 1 && "$site" != localhost && "$site" != *.localhost ]] && declare -F fl_is_wsl >/dev/null && fl_is_wsl; then
      fl_die "$site is not a *.localhost name, so the Windows browser may not reach it from WSL." \
        "Use a site named NAME.localhost, or add $site to the Windows hosts file and open the link yourself: benchbar open --as USER --print-url"
    fi
    fl_site_developer_mode "$site" \
      || fl_die "${site} is not in developer mode, so benchbar will not sign in as another user." "On a development site: bench --site ${site} set-config developer_mode 1"
    [[ "$user" != "Guest" ]] || fl_die "Guest has no session to open." "Open the site without --as instead."
  fi
  if [[ -n "$path" ]]; then
    [[ "$path" == /* && "$path" != //* ]] || fl_die "--path must start with a single /." "Example: --path /app/todo"
    fl_path_without_sid_v path "$path"
  fi
  base="http://${site}:${FL_WEB_PORT}"
  if [[ -z "$user" ]]; then
    url="${base}${path}"
  else
    fl_bench_python_v fields "$FL_PY_OPEN_AS" benchbar-open-as "$site" "$user"
    name="${fields%%$'\t'*}"; fields="${fields#*$'\t'}"
    full_name="${fields%%$'\t'*}"; fields="${fields#*$'\t'}"
    user_type="${fields%%$'\t'*}"; sid="${fields#*$'\t'}"
    [[ "$sid" != *$'\t'* && "$sid" != "$user_type" ]] || sid=""
    [[ -n "$sid" ]] || fl_die "The bench's Python started no session for ${user}." "Check the bench with: benchbar doctor"
    if [[ -z "$path" ]]; then
      path=/; [[ "$user_type" == "System User" ]] && path=/app
    fi
    fl_urlencode_v enc "$path"
    url="${base}/login?redirect-to=${enc}&sid=${sid}&t=$(date +%s)"
  fi
  if [[ "$browser" == "1" ]]; then
    if fl_open_url "$url" >/dev/null; then opened=true
    else
      fl_die "No program here opens a browser ($(fl_open_cmd))." "Open the site yourself, or run: benchbar open --print-url"
    fi
  fi
  if [[ "$OPT_JSON" == "1" ]]; then
    printf '{"schema_version":%d,"cli_version":"%s","site":%s,"user":%s,"full_name":%s,"user_type":%s,"path":%s,"opened":%s' \
      "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$site")" "$(fl_json_str_or_null "$name")" \
      "$(fl_json_str_or_null "$full_name")" "$(fl_json_str_or_null "$user_type")" "$(fl_json_str "${path:-/}")" "$opened"
    if [[ "$print_url" == "1" ]]; then fl_json_str_v j "$url"; printf ',"url":%s' "$j"; fi
    printf '}\n'
  elif [[ "$print_url" == "1" ]]; then
    printf '%s\n' "$url"
  elif [[ -n "$user" ]]; then
    fl_ok "${site}: opened as ${name} (${full_name}, ${user_type}) at ${path}"
  else
    fl_ok "${site}: opened ${base}${path}"
  fi
}

# fl_json_str_or_null TEXT: a JSON string, or null for an empty TEXT
fl_json_str_or_null() { if [[ -z "$1" ]]; then printf 'null'; else fl_json_str "$1"; fi; }

fl_cmd_users() {
  local search="" limit=50 site="$FL_SITE" result more line rows=() u n t r
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --search) [[ "$#" -ge 2 ]] || fl_die "--search needs some text." "Example: --search priya"; search="$2"; shift 2 ;;
      --search=*) search="${1#*=}"; shift ;;
      --limit) [[ "$#" -ge 2 ]] || fl_die "--limit needs a number from 1 to 500." "Example: --limit 50"; limit="$2"; shift 2 ;;
      --limit=*) limit="${1#*=}"; shift ;;
      *) fl_die "Unknown argument for users: $1" "Use: benchbar users [--site NAME] [--search TEXT] [--limit N] [--json]" ;;
    esac
  done
  [[ "$limit" =~ ^[0-9]+$ ]] && [[ "$limit" -ge 1 && "$limit" -le 500 ]] || fl_die "--limit needs a number from 1 to 500." "Example: --limit 50"
  fl_require_bench
  [[ -n "$site" ]] || fl_die "This bench has no default site." "Pass --site NAME (benchbar site list shows them)"
  fl_site_require "$site"
  fl_open_as_require_enabled "$site"
  [[ -n "$(fl_port_listener_pid "$FL_REDIS_CACHE_PORT")" ]] || fl_die "The bench is not running." "Start it first: benchup"
  if [[ "$OPT_JSON" == "1" ]]; then
    fl_bench_python_v result "$FL_PY_USERS" benchbar-users "$site" "$search" "$limit" json
    printf '{"schema_version":%d,"cli_version":"%s","site":%s,%s\n' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$site")" "${result#\{}"
    return 0
  fi
  fl_bench_python_v result "$FL_PY_USERS" benchbar-users "$site" "$search" "$limit" table
  more=0; rows=("User|Name|Type|Roles")
  while IFS= read -r line; do
    if [[ "$line" == 0 || "$line" == 1 ]]; then more="$line"; continue; fi
    IFS=$'\t' read -r u n t r <<<"$line"
    [[ -n "$u" ]] && rows+=("${u}|${n//|//}|${t}|${r}")
  done <<<"$result"
  if [[ "${#rows[@]}" == 1 ]]; then
    fl_info "No enabled user on ${site} matches${search:+ \"${search}\"}."
    return 0
  fi
  fl_table "${rows[@]}"
  [[ "$more" == 0 ]] || fl_note "More users match; narrow it with --search or raise --limit (up to 500)."
}

# site open-as on|off|status [NAME]: the per site opt-in. on and off change
# benchbar's state only (OPEN_AS_SITES), never the site. on is a person's
# decision: it is refused when nothing can ask (BENCHBAR_NONINTERACTIVE=1,
# so also --for-agent and benchbar mcp; the dispatcher checks it before the
# lock), so an agent cannot turn it on and then ask for a session id. off is
# always allowed. on tells what does not work yet but still records the choice.
fl_cmd_site_open_as() {
  local action="${1:-}" name="" a dm=false enabled=false served="" active=false why=""
  shift || true
  [[ "$action" == on || "$action" == off || "$action" == status ]] \
    || fl_die "Usage: benchbar site open-as on|off|status [NAME] [--json]" "Example: benchbar site open-as on ${FL_SITE:-NAME}"
  for a in "$@"; do
    case "$a" in
      -*) fl_die "Unknown option for site open-as: $a" "Use: benchbar site open-as on|off|status [NAME] [--json]" ;;
      *) [[ -n "$name" ]] || name="$a" ;;
    esac
  done
  [[ "$action" != status ]] || fl_site_json_begin
  fl_require_bench
  [[ -n "$name" ]] || name="$FL_SITE"
  [[ -n "$name" ]] || fl_die "This bench has no default site." "Pass NAME: benchbar site open-as ${action} NAME"
  fl_site_valid_name "$name"
  fl_site_require "$name"
  fl_site_config_value_v served default_site
  if [[ "$action" == on ]]; then
    fl_noninteractive && fl_die "Turning on Open as is a person's decision, so nothing run without a terminal can do it." \
      "Run it in a terminal: benchbar site open-as on ${name}"
    # --yes skips the question, not the person: a terminal on stdin, or the app (BENCHBAR_SUDO=gui, after its own alert)
    [[ "${FL_DRY_RUN:-0}" == 1 || -t 0 || "${BENCHBAR_SUDO:-}" == gui ]] || fl_die "Turning on Open as needs a person at a terminal, and this run has none." \
      "Run it in a terminal: benchbar site open-as on ${name}"
    if ! fl_open_as_enabled "$name" && [[ "${FL_DRY_RUN:-0}" != "1" ]]; then
      fl_info "Open as signs in as any enabled user of ${name} with no password: benchbar open --as USER."
      fl_info "Each sign in runs the apps' on_login hooks, updates the user's last_login and, past the simultaneous_sessions limit, ends that user's oldest session."
      fl_confirm "Turn on Open as for ${name}?" || fl_die "Open as stays off for ${name}." "Run again and answer yes, or pass --yes"
    fi
  fi
  case "$action" in
    on)
      if fl_open_as_enabled "$name"; then fl_ok "unchanged: Open as is already on for ${name}"
      elif [[ "${FL_DRY_RUN:-0}" == "1" ]]; then fl_info "dry-run: would turn on Open as for ${name} (benchbar state only)"
      else
        fl_open_as_set "$name" 1
        fl_changed open_as "$name" "turned on"
        fl_ok "Open as is on for ${name} (benchbar state only, ${name} itself is not changed)"
      fi ;;
    off)
      if ! fl_open_as_enabled "$name"; then fl_ok "unchanged: Open as is already off for ${name}"
      elif [[ "${FL_DRY_RUN:-0}" == "1" ]]; then fl_info "dry-run: would turn off Open as for ${name}"
      else
        fl_open_as_set "$name" 0
        fl_changed open_as "$name" "turned off"
        fl_ok "Open as is off for ${name}"
      fi ;;
  esac
  fl_site_developer_mode "$name" && dm=true
  fl_open_as_enabled "$name" && enabled=true
  [[ "$enabled" == true && "$dm" == true && ( -z "$served" || "$served" == "$name" ) ]] && active=true
  if [[ "$enabled" == true && "$dm" != true ]]; then
    why="${name} is not in developer mode, so open --as will refuse it. On a development site: bench --site ${name} set-config developer_mode 1"
  elif [[ "$enabled" == true && -n "$served" && "$served" != "$name" ]]; then
    why="Port ${FL_WEB_PORT} serves only ${served}, so open --as will refuse ${name}. Use: benchbar site default ${name}, then benchrestart"
  fi
  if [[ "$action" == status && "$OPT_JSON" != "1" ]]; then
    fl_ok "${name}: Open as is $([[ "$enabled" == true ]] && printf on || printf off)$([[ "$enabled" == true && "$active" == true ]] && printf ', ready' || true)"
    [[ "$enabled" == true ]] || fl_info "Turn it on in a terminal: benchbar site open-as on ${name}"
  fi
  [[ -z "$why" ]] || fl_warn "$why"
  fl_open_as_result_doc "$name" "$enabled" "$dm" "$active"
}

# fl_open_as_result_doc NAME ENABLED DEVMODE ACTIVE: the document of site
# open-as (status: one document with the done fields; on and off: what the
# stream's done line merges)
fl_open_as_result_doc() {
  [[ "$OPT_JSON" == "1" || "${FL_JSONL:-0}" == "1" ]] || return 0
  fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"default_site":%s,"open_as_enabled":%s,"developer_mode":%s,"open_as":%s}' \
    "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$1")" "$(fl_json_str "$FL_SITE")" "$2" "$3" "$4")"
}
