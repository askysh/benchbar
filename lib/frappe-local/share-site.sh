#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# share-site.sh: the Python helpers of benchbar share and the site side of
# share setup: the users who can take a seat, the hardening of the copy, and
# the copy itself (share.localhost, restored from a backup set by site
# restore's own plan and run).
#
# The helpers run in the bench's Python (fl_bench_python_v) and print one
# "BENCHBAR-RESULT " line: counts only, never a name or a secret. The roles
# that can run code come from one function, FL_PY_SHARE_ROLES, which both the
# user list and the hardening are built from, so what the picker warns about
# is exactly what the copy removes.

FL_SHARE_SITE="share.localhost"

# What can run code or change what runs: the doctypes whose write, create or
# submit permission makes a role code-capable (Frappe v15 names; Custom Script
# is a v14 name and matches nothing). The fixed names are a floor: they stay
# code-capable even if a site's permissions say otherwise. A Custom DocPerm row
# for a doctype replaces its standard DocPerm rows (frappe/model/meta.py,
# set_custom_permissions), so the standard rows of such a doctype do not count.
# shellcheck disable=SC2016  # Python source: the backticks and dollar signs are not the shell's
FL_PY_SHARE_ROLES='CODE_DOCTYPES = ("Server Script", "Client Script", "Custom Script", "Report", "System Settings", "Customize Form",
    "DocType", "Custom Field", "Property Setter", "Workflow", "Webhook", "Notification", "Email Account", "Scheduled Job Type",
    "Page", "Print Format", "Web Page", "Custom HTML Block", "System Console", "Website Script", "Module Def", "Package")
FLOOR_ROLES = ("System Manager", "Administrator", "Script Manager", "Server Script Manager", "Developer", "Report Manager")
AUTOMATIC_ROLES = ("All", "Guest", "Desk User")
def code_capable_roles(frappe):
    wanted = {"doctypes": CODE_DOCTYPES}
    standard = frappe.db.sql("select parent, role, `write`, `create`, submit from `tabDocPerm` where parent in %(doctypes)s", wanted, as_dict=True)
    custom = frappe.db.sql("select parent, role, `write`, `create`, submit from `tabCustom DocPerm` where parent in %(doctypes)s", wanted, as_dict=True)
    replaced = {row["parent"] for row in custom}
    roles = set(FLOOR_ROLES)
    for row in [r for r in standard if r["parent"] not in replaced] + list(custom):
        if (row["write"] or row["create"] or row["submit"]) and row["role"] not in AUTOMATIC_ROLES:
            roles.add(row["role"])
    return sorted(roles)
'

# share users: every user but Guest, who each would lose which roles in the
# copy, and who may take a seat (an enabled System User other than
# Administrator, who cannot be demoted). MODE json prints {"users":[...]},
# rows one line per user, fields apart by the unit separator (name, full name,
# enabled, type, roles and code-capable roles each joined by |), classes the
# record count of the main personal-data doctypes (name, count).
# shellcheck disable=SC2016  # Python source: the backticks and dollar signs are not the shell's
FL_PY_SHARE_USERS_BODY='
import sys, json
site, mode = sys.argv[2], sys.argv[3]
def say(*fields):
    print("\nBENCHBAR-RESULT " + "\x1f".join(" ".join(str(f).split()) for f in fields), flush=True)
import frappe
frappe.init(site=site)
frappe.connect()
try:
    if mode == "classes":
        for doctype in ("User", "Customer", "Supplier", "Contact", "Address", "Employee", "Lead", "Communication"):
            if frappe.db.table_exists(doctype):
                say(doctype, frappe.db.sql("select count(*) from `tab" + doctype + "`")[0][0])
        sys.exit(0)
    capable = set(code_capable_roles(frappe))
    users = frappe.db.sql("select name, full_name, enabled, user_type from `tabUser` where name != %s order by enabled desc, user_type, name limit 500", ("Guest",), as_dict=True)
    held = {}
    if users:
        for row in frappe.db.sql("select parent, role from `tabHas Role` where parenttype = %(kind)s and parent in %(names)s and role not in %(automatic)s order by role",
                {"kind": "User", "names": tuple(u["name"] for u in users), "automatic": AUTOMATIC_ROLES}, as_dict=True):
            held.setdefault(row["parent"], []).append(row["role"])
    out = []
    for u in users:
        roles = ["Administrator"] if u["name"] == "Administrator" else held.get(u["name"], [])
        lost = [r for r in roles if r in capable]
        out.append({"name": u["name"], "full_name": u["full_name"] or u["name"], "enabled": bool(u["enabled"]), "user_type": u["user_type"],
            "roles": roles, "code_capable_roles": lost, "will_demote": bool(lost) and u["name"] != "Administrator",
            "selectable": bool(u["enabled"]) and u["user_type"] == "System User" and u["name"] != "Administrator"})
    if mode == "json":
        print("\nBENCHBAR-RESULT " + json.dumps({"users": out}, separators=(",", ":")), flush=True)
    else:
        for u in out:
            say(u["name"], u["full_name"], "1" if u["enabled"] else "0", u["user_type"], "|".join(u["roles"]), "|".join(u["code_capable_roles"]))
finally:
    frappe.destroy()'
FL_PY_SHARE_USERS="${FL_PY_SHARE_ROLES}${FL_PY_SHARE_USERS_BODY}"

# The hardening of the copy, run inside it (argv: SITE; the allowed users on
# stdin, one per line). It sets what only the site's own data can set, and
# every step is safe to repeat:
#  - System Settings: allow_error_traceback off (a System Settings field, not
#    a site_config key), login with email link off; Website Settings: sign
#    ups off; Portal Settings: default_role empty, so a guest's sign in cannot
#    make a Customer or Supplier (erpnext's on_session_creation)
#  - Administrator and each allowed user get a random password nobody sees
#  - every API key and secret, OAuth token and Token Cache row is gone
#  - social logins, webhooks, notifications and mail accounts are switched off
#  - every enabled user but the allowed ones (and Administrator and Guest,
#    which Frappe never lets be disabled) is disabled
#  - every code-capable role is removed from each allowed user
#  - every session is deleted
# shellcheck disable=SC2016  # Python source: the backticks and dollar signs are not the shell's
FL_PY_SHARE_HARDEN_BODY='
import sys, json, secrets
site = sys.argv[2]
allowed = [line.strip() for line in sys.stdin if line.strip()]
def refuse(text):
    print("\nBENCHBAR-ERROR " + text, flush=True)
    sys.exit(1)
import frappe
frappe.init(site=site)
frappe.connect()
try:
    from frappe.utils.password import update_password
    if not allowed or any(u in ("Administrator", "Guest") for u in allowed):
        refuse("The copy needs at least one seat, and Administrator and Guest cannot be one.")
    seats = {u["name"]: u for u in frappe.db.sql("select name, enabled, user_type from `tabUser` where name in %(names)s", {"names": tuple(allowed)}, as_dict=True)}
    if any(u not in seats or not seats[u]["enabled"] or seats[u]["user_type"] != "System User" for u in allowed):
        refuse("A seat is missing from the copy, disabled there, or not a System User.")
    counts = {}
    counts["portal_default_role_cleared"] = 1 if frappe.db.get_single_value("Portal Settings", "default_role") else 0
    frappe.db.set_single_value("System Settings", "allow_error_traceback", 0)
    frappe.db.set_single_value("System Settings", "login_with_email_link", 0)
    frappe.db.set_single_value("Website Settings", "disable_signup", 1)
    frappe.db.set_single_value("Portal Settings", "default_role", "")
    counts["allow_error_traceback"] = 0
    counts["disable_signup"] = 1
    for user in ["Administrator"] + allowed:
        update_password(user, secrets.token_urlsafe(32))
    counts["admin_rotated"] = 1
    counts["passwords_rotated"] = len(allowed)
    counts["api_keys_cleared"] = frappe.db.sql("select count(*) from `tabUser` where ifnull(api_key, %s) != %s", ("", ""))[0][0]
    frappe.db.sql("update `tabUser` set api_key = NULL")
    frappe.db.delete("__Auth", {"doctype": "User", "fieldname": "api_secret"})
    counts["token_tables_cleared"] = 0
    for doctype in ("OAuth Bearer Token", "OAuth Authorization Code", "Token Cache"):
        if frappe.db.table_exists(doctype):
            frappe.db.truncate(doctype)
            counts["token_tables_cleared"] += 1
    def switch_off(doctype, fieldnames):
        fieldnames = [f for f in fieldnames if frappe.db.table_exists(doctype) and frappe.db.has_column(doctype, f)]
        if not fieldnames:
            return 0
        table = "`tab" + doctype + "`"
        n = frappe.db.sql("select count(*) from " + table + " where " + " or ".join("`%s` = 1" % f for f in fieldnames))[0][0]
        if n:
            frappe.db.sql("update " + table + " set " + ", ".join("`%s` = 0" % f for f in fieldnames))
        return n
    counts["social_logins_disabled"] = switch_off("Social Login Key", ["enable_social_login"])
    counts["webhooks_disabled"] = switch_off("Webhook", ["enabled"])
    counts["notifications_disabled"] = switch_off("Notification", ["enabled"])
    counts["email_accounts_disabled"] = switch_off("Email Account", ["enable_outgoing", "enable_incoming"])
    keep = tuple(allowed) + ("Administrator", "Guest")
    others = frappe.db.sql_list("select name from `tabUser` where enabled = 1 and name not in %(keep)s", {"keep": keep})
    if others:
        frappe.db.sql("update `tabUser` set enabled = 0 where name in %(names)s", {"names": tuple(others)})
    counts["users_disabled"] = len(others)
    capable = set(code_capable_roles(frappe))
    counts["users_demoted"] = counts["roles_removed"] = 0
    for user in allowed:
        held = frappe.db.sql_list("select role from `tabHas Role` where parenttype = %(kind)s and parent = %(user)s", {"kind": "User", "user": user})
        drop = [r for r in held if r in capable]
        if drop:
            frappe.db.sql("delete from `tabHas Role` where parenttype = %(kind)s and parent = %(user)s and role in %(roles)s", {"kind": "User", "user": user, "roles": tuple(drop)})
            counts["users_demoted"] += 1
            counts["roles_removed"] += len(drop)
    still = frappe.db.sql_list("select parent from `tabHas Role` where parenttype = %(kind)s and parent in %(names)s and role in %(roles)s",
        {"kind": "User", "names": tuple(allowed), "roles": tuple(capable)})
    if still:
        frappe.db.rollback()
        refuse("A seat still holds a code-capable role after the demotion.")
    sids = frappe.db.sql_list("select sid from `tabSessions`")
    for sid in sids:
        frappe.cache.hdel("session", sid)
        frappe.cache.hdel("last_db_session_update", sid)
    frappe.db.sql("delete from `tabSessions`")
    counts["sessions_deleted"] = len(sids)
    frappe.db.commit()
    frappe.clear_cache()
    print("\nBENCHBAR-RESULT " + json.dumps(counts, separators=(",", ":")), flush=True)
finally:
    frappe.destroy()'
FL_PY_SHARE_HARDEN="${FL_PY_SHARE_ROLES}${FL_PY_SHARE_HARDEN_BODY}"

# The bench's Redis, up for a Frappe call and down after it, whatever the
# bench is doing: a dry run reads too, so FL_DRY_RUN does not skip it.
fl_share_redis_up() { FL_DRY_RUN=0 fl_bench_redis_up "$FL_BENCH_DIR"; }
fl_share_redis_down() { fl_bench_redis_down; }

# fl_share_probe_v VAR SITE MODE: the output of the user helper (json, rows or classes)
fl_share_probe_v() {
  local __var="$1" __got
  fl_share_redis_up
  fl_bench_python_v __got "$FL_PY_SHARE_USERS" benchbar-share-users "$2" "$3"
  fl_share_redis_down
  printf -v "$__var" '%s' "$__got"
}

# fl_share_site_config KEY VALUE: bench --site share.localhost set-config -p
# (-p: the value is JSON, so 0 is a number and not the true string "0")
fl_share_site_config() {
  fl_bench_env_exports
  (cd "$FL_BENCH_DIR" && bench --site "$FL_SHARE_SITE" set-config -p "$1" "$2") >>"${FL_LOG_FILE:-/dev/null}" 2>&1 \
    || { fl_fail "bench --site ${FL_SHARE_SITE} set-config ${1} failed"; return 1; }
}

# fl_share_harden_v VAR USER...: the site config and the helper; the users go
# to the helper on stdin. VAR gets the helper's counts, one JSON object.
fl_share_harden_v() {
  local __var="$1" __got kv
  shift
  for kv in "developer_mode 0" "server_script_enabled 0" "pause_scheduler 1" "mute_emails 1" "allow_tests 0"; do
    # shellcheck disable=SC2086  # "key value"
    fl_share_site_config $kv || return 1
  done
  fl_share_redis_up
  fl_bench_python_v __got "$FL_PY_SHARE_HARDEN" benchbar-share-harden "$FL_SHARE_SITE" < <(printf '%s\n' "$@")
  fl_share_redis_down
  printf -v "$__var" '%s' "$__got"
}

# fl_share_app_heads_v VAR: {"app":"<git HEAD>",...} for the apps installed on
# the copy (an app with no git checkout is left out)
fl_share_app_heads_v() {
  local __var="$1" apps app sha json="" sep=""
  fl_bench_env_exports
  apps="$(cd "$FL_BENCH_DIR" && bench --site "$FL_SHARE_SITE" list-apps 2>>"${FL_LOG_FILE:-/dev/null}" | awk 'NF { print $1 }')" \
    || { fl_fail "bench --site ${FL_SHARE_SITE} list-apps failed"; return 1; }
  for app in $apps; do
    sha="$(git -C "${FL_BENCH_DIR}/apps/${app}" rev-parse -q --verify HEAD 2>/dev/null || true)"
    [[ "$sha" =~ ^[0-9a-f]{40,64}$ ]] || continue
    json="${json}${sep}$(fl_json_str "$app"):$(fl_json_str "$sha")"; sep=","
  done
  printf -v "$__var" '{%s}' "$json"
}

# fl_share_pick_stamp_v VAR DIR: the newest backup set of DIR with a plain
# (not partial, not encrypted) database; nothing when there is none
fl_share_pick_stamp_v() {
  local __var="$1" stamp set
  printf -v "$__var" '%s' ""
  while IFS= read -r stamp; do
    [[ -n "$stamp" ]] || continue
    set="$(fl_backup_set_json "$2" "$stamp")"
    [[ "$(fl_backup_field "$set" database)" != null && "$(fl_backup_field "$set" partial)" == false && "$(fl_backup_field "$set" encrypted)" == false ]] || continue
    printf -v "$__var" '%s' "$stamp"
    return 0
  done < <(fl_backup_stamps "$2")
}

# fl_share_copy_plan_apply SITE STAMP WITH_FILES: restores STAMP of SITE into
# share.localhost by site restore's own plan and run (a new site, or the
# existing one, which is backed up first). Its steps hang under the step that
# calls this; SH_RESTORE_TOKEN is the token of the plan it ran.
fl_share_copy_plan_apply() {
  local err code=0
  SR_TARGET="$FL_SHARE_SITE"; SR_FROM="$2"; SR_FROM_SITE="$1"; SR_WITH_FILES="$3"; SR_APPLY=1
  SR_NEW=1; [[ -f "${FL_BENCH_DIR}/sites/${FL_SHARE_SITE}/site_config.json" ]] && SR_NEW=0
  SR_STEP_PARENT=share_site
  fl_srestore_plan
  if [[ "$SR_CAN_APPLY" != "1" ]]; then
    for err in ${SR_ERRORS[@]+"${SR_ERRORS[@]}"}; do fl_fail "$err"; done
    return 1
  fi
  SH_RESTORE_TOKEN="$SR_TOKEN"
  fl_steps_push
  fl_srestore_execute || code=$?
  fl_steps_pop
  SR_STEP_PARENT=""
  return "$code"
}
