#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# neutralise.sh: what a copy of a real site must not keep. One routine, used
# by benchbar pull (a production site into a local one) and by share setup
# (the copy a room serves), so the two cannot drift apart.
#
# The copy keeps the data and loses the means to reach out or act as the
# real site: outbound integrations are switched off, URLs and keys that are
# stored in plain fields are blanked, tokens and queued mail are dropped, jobs
# that call out are stopped, and every stored password (the __Auth table:
# every Password field of every doctype) is deleted, except the Administrator
# login when the caller keeps it. Customer data (names, addresses, documents)
# is not touched: this is not a scrub.
#
# The list below is the whole policy, one entry per line with the comment
# above it saying why. It is Python data, run by the bench's own Python
# (fl_bench_python_v), so no SQL is typed by hand into mariadb and nothing
# under sites/ is edited. An entry for a doctype the site does not have (an app
# that is not installed, a field another Frappe version lacks) is skipped, so
# one list serves Frappe v15 and v16. To add a doctype, add one entry and its
# comment; tests/test-neutralise.sh checks that every entry has a comment.
#
# Entry: (KEY, DOCTYPE, OP, FIELDS, WHERE, LABEL)
#   KEY     the name the count goes under (the done line, the output); entries
#           with one KEY add up, and the first LABEL names the count
#   OP      "set"      FIELDS is {field: value}: 0 and 1 for a check, "" or
#                      None for a text field; counted per row that changes
#           "delete"   the rows (WHERE narrows them) go
#           "orphans"  the child rows whose parent DOCTYPE FIELDS is gone
#           "auth"     every stored password (see keep_admin)
#   WHERE   {column: [value, ...]} (a value with % is a LIKE pattern) or None
#   A single doctype (settings page) has no table of its own: its fields are
#   rows of tabSingles, and the same entry covers it.
#
# The Python must not contain a single quote: it lives in a shell string.

# shellcheck disable=SC2016  # Python source: the backticks and dollar signs are not the shell's
FL_PY_NEUTRALISE='
NEUTRALISE = [
    # Mail accounts: no sending and no fetching from the real mailbox (the password goes with the other stored passwords)
    ("email_accounts", "Email Account", "set", {"enable_outgoing": 0, "enable_incoming": 0, "enable_auto_reply": 0}, None, "email accounts switched off"),
    # Email Account API key (an API based mail service) is a plain Data field
    ("integration_keys", "Email Account", "set", {"api_key": ""}, None, "integration keys blanked"),
    # Mail waiting to go out would be sent to real customers the day mute_emails is lifted
    ("email_queue", "Email Queue", "delete", None, {"status": ["Not Sent", "Sending", "Partially Sent"]}, "queued emails dropped"),
    # The recipients of the queued mail just dropped (not counted again)
    ("email_queue", "Email Queue Recipient", "orphans", "Email Queue", None, "queued emails dropped"),
    # Reports that mail themselves to a list of real addresses
    ("auto_email_reports", "Auto Email Report", "set", {"enabled": 0}, None, "auto email reports switched off"),
    # Notifications send mail, SMS, Slack messages and system alerts on document events
    ("notifications", "Notification", "set", {"enabled": 0}, None, "notifications switched off"),
    # Webhooks post document data to outside URLs on document events (the secret goes with the stored passwords)
    ("webhooks", "Webhook", "set", {"enabled": 0}, None, "webhooks switched off"),
    # A webhook URL often carries the key or token in its path or query string, so it is blanked and not only switched off
    ("webhook_urls", "Webhook", "set", {"request_url": ""}, None, "webhook URLs and header values blanked"),
    # Webhook headers (Authorization, API keys) are plain Data in a child table
    ("webhook_urls", "Webhook Header", "set", {"value": ""}, None, "webhook URLs and header values blanked"),
    # v16 Automation Flow: its CallWebhook and SendNotification actions fire on save, whether the scheduler runs or not
    ("automation_flows", "Automation Flow", "set", {"enabled": 0}, None, "automation flows switched off"),
    # The log of what webhooks posted: payloads of real documents and the answers
    ("webhook_logs", "Webhook Request Log", "delete", None, None, "webhook logs dropped"),
    # A Slack webhook URL is the credential itself and is stored in a plain field
    ("slack_webhooks", "Slack Webhook URL", "set", {"webhook_url": ""}, None, "Slack webhook URLs blanked"),
    # The SMS gateway URL, often with the key in its query string
    ("sms_gateway", "SMS Settings", "set", {"sms_gateway_url": ""}, None, "SMS gateway blanked"),
    # The SMS gateway parameters: user names, sender ids, keys, in plain fields
    ("sms_gateway", "SMS Parameter", "set", {"value": ""}, None, "SMS gateway blanked"),
    # Social and single sign on logins keep working against the real provider (client secret: stored passwords)
    ("social_logins", "Social Login Key", "set", {"enable_social_login": 0}, None, "social logins switched off"),
    # An OAuth client of this site: its secret is a plain field, so tokens made for it could be redeemed
    ("oauth_clients", "OAuth Client", "set", {"client_secret": ""}, None, "OAuth client secrets blanked"),
    # OAuth bearer tokens (the access and refresh tokens are plain fields)
    ("tokens", "OAuth Bearer Token", "delete", None, None, "OAuth and Connected App tokens dropped"),
    # OAuth authorization codes, which can still be redeemed for a token
    ("tokens", "OAuth Authorization Code", "delete", None, None, "OAuth and Connected App tokens dropped"),
    # The tokens Connected Apps obtained for users (Google, Microsoft and any other provider)
    ("tokens", "Token Cache", "delete", None, None, "OAuth and Connected App tokens dropped"),
    # Integration Request rows keep the payloads, headers and answers of calls to payment and other services
    ("integration_requests", "Integration Request", "delete", None, None, "integration requests dropped"),
    # Google Calendar sync (refresh token: stored passwords)
    ("google", "Google Calendar", "set", {"enable": 0}, None, "Google integrations switched off"),
    # Google Contacts sync (refresh token: stored passwords)
    ("google", "Google Contacts", "set", {"enable": 0}, None, "Google integrations switched off"),
    # Google Drive backups: the refresh token is a plain field here
    ("google", "Google Drive", "set", {"enable": 0, "refresh_token": ""}, None, "Google integrations switched off"),
    # Google Settings: the API key is a plain field (client secret: stored passwords)
    ("google", "Google Settings", "set", {"enable": 0, "api_key": ""}, None, "Google integrations switched off"),
    # Google indexing of the website: the refresh token is a plain field
    ("google", "Website Settings", "set", {"enable_google_indexing": 0, "indexing_refresh_token": ""}, None, "Google integrations switched off"),
    # The Google Analytics id of the website: the copy would send its hits to the real property
    ("google", "Website Settings", "set", {"google_analytics_id": ""}, None, "Google integrations switched off"),
    # Backups uploaded to Dropbox every day (the app secret and tokens: stored passwords)
    ("backup_uploads", "Dropbox Settings", "set", {"enabled": 0, "app_access_key": ""}, None, "backup uploads switched off"),
    # Backups uploaded to S3 or an S3 compatible bucket (the secret key: stored passwords)
    ("backup_uploads", "S3 Backup Settings", "set", {"enabled": 0, "access_key_id": ""}, None, "backup uploads switched off"),
    # LDAP logins and user sync against the real directory (the bind password: stored passwords)
    ("ldap", "LDAP Settings", "set", {"enabled": 0, "ldap_server_url": ""}, None, "LDAP switched off"),
    # The push notification relay of the real site (the API secret: stored passwords)
    ("push_notifications", "Push Notification Settings", "set", {"enable_push_notification_relay": 0, "api_key": ""}, None, "push notifications switched off"),
    # Payment gateway settings of the payments app: the key ids are plain fields, the secrets are stored passwords
    ("payment_gateways", "Razorpay Settings", "set", {"api_key": ""}, None, "payment gateway keys blanked"),
    # Stripe: the publishable key (the secret key: stored passwords)
    ("payment_gateways", "Stripe Settings", "set", {"publishable_key": ""}, None, "payment gateway keys blanked"),
    # PayPal: the API user name and the signature are plain Data fields (only the API password is a stored password)
    ("payment_gateways", "PayPal Settings", "set", {"api_username": "", "signature": ""}, None, "payment gateway keys blanked"),
    # Braintree: merchant and public key (private key: stored passwords)
    ("payment_gateways", "Braintree Settings", "set", {"merchant_id": "", "public_key": ""}, None, "payment gateway keys blanked"),
    # M-Pesa: the consumer key and the security credential, both plain fields (consumer secret: stored passwords)
    ("payment_gateways", "Mpesa Settings", "set", {"consumer_key": "", "security_credential": ""}, None, "payment gateway keys blanked"),
    # Paytm: the merchant id (merchant key: stored passwords)
    ("payment_gateways", "Paytm Settings", "set", {"merchant_id": ""}, None, "payment gateway keys blanked"),
    # Plaid bank feeds: the sync is switched off and the client id blanked (secret: stored passwords)
    ("payment_gateways", "Plaid Settings", "set", {"enabled": 0, "automatic_sync": 0, "plaid_client_id": ""}, None, "payment gateway keys blanked"),
    # GoCardless: the access token and the webhook secret are plain fields
    ("payment_gateways", "GoCardless Settings", "set", {"access_token": "", "webhooks_secret": ""}, None, "payment gateway keys blanked"),
    # A bank linked to Plaid keeps its access token in a plain field
    ("payment_gateways", "Bank", "set", {"plaid_access_token": ""}, None, "payment gateway keys blanked"),
    # ERPNext Video Settings: the YouTube API key is a plain field
    ("integration_keys", "Video Settings", "set", {"api_key": ""}, None, "integration keys blanked"),
    # ERPNext Currency Exchange Settings: the access key, the endpoint (which can carry it) and the url are plain fields
    ("integration_keys", "Currency Exchange Settings", "set", {"access_key": "", "api_endpoint": "", "url": ""}, None, "integration keys blanked"),
    # Recurring documents are created on a schedule and mailed to the parties of the original
    ("auto_repeats", "Auto Repeat", "set", {"disabled": 1}, None, "auto repeats paused"),
    # Scheduled jobs that send mail or read a mailbox, so they stay stopped if someone turns the scheduler on
    ("scheduled_jobs", "Scheduled Job Type", "set", {"stopped": 1}, {"method": ["frappe.email.%", "%.send\\_%", "%\\_reminder%", "%.trigger\\_emails", "%email\\_digest%", "%email\\_campaign%", "%send\\_auto\\_email%"]}, "scheduled jobs that call out stopped"),
    # Scheduled jobs that upload backups or sync with an outside service
    ("scheduled_jobs", "Scheduled Job Type", "set", {"stopped": 1}, {"method": ["frappe.integrations.%", "%plaid\\_settings%", "%update\\_youtube\\_data", "frappe.utils.change\\_log.%", "frappe.desk.doctype.changelog\\_feed.%", "frappe.utils.telemetry.%"]}, "scheduled jobs that call out stopped"),
    # The payments job that captures authorised Razorpay payments with the stored keys
    ("scheduled_jobs", "Scheduled Job Type", "set", {"stopped": 1}, {"method": ["%razorpay\\_settings.capture\\_payment"]}, "scheduled jobs that call out stopped"),
    # The v16 job that fetches the knowledge sources of the site from their outside URLs
    ("scheduled_jobs", "Scheduled Job Type", "set", {"stopped": 1}, {"method": ["frappe.flow.knowledge.ingest.sync_due_sources"]}, "scheduled jobs that call out stopped"),
    # Jobs of the India Compliance app, which talk to the GST portal and e-invoice services with the stored credentials
    ("scheduled_jobs", "Scheduled Job Type", "set", {"stopped": 1}, {"method": ["india\\_compliance.%"]}, "scheduled jobs that call out stopped"),
    # Server scripts that make HTTP requests themselves
    ("server_scripts", "Server Script", "set", {"disabled": 1}, {"script": ["%make\\_get\\_request%", "%make\\_post\\_request%", "%make\\_put\\_request%", "%make\\_patch\\_request%", "%make\\_delete\\_request%", "%requests.%", "%urllib%"]}, "server scripts that call out disabled"),
    # API keys of users (the API secret: stored passwords) and password reset keys that are still open
    ("api_keys", "User", "set", {"api_key": None, "reset_password_key": ""}, None, "API keys and reset keys cleared"),
    # Every Password field of every doctype lives in the __Auth table: email, SMTP, LDAP, S3, payment, OAuth and webhook secrets, and the passwords of users
    ("stored_secrets", "__Auth", "auth", None, None, "stored secrets cleared"),
]

def _changed(column, value):
    # the SQL test "this column is not already what the entry wants"
    if value == 1:
        return "ifnull(`%s`, 0) != 1" % column
    if value == 0:
        return "ifnull(`%s`, 0) != 0" % column
    return "ifnull(`%s`, %%s) != %%s" % column

def _changed_args(value):
    return () if value in (0, 1) else ("", "")

def _where(where):
    # the SQL and parameters of a WHERE dict: columns and, inside a column, values are alternatives
    parts, args = [], []
    for column, values in (where or {}).items():
        tests = []
        for value in values:
            tests.append("`%s` like %%s" % column if "%" in value else "`%s` = %%s" % column)
            args.append(value)
        parts.append("(" + " or ".join(tests) + ")")
    return " and ".join(parts), args

def _count(frappe, table, condition, args):
    return frappe.db.sql("select count(*) from `" + table + "` where " + condition, tuple(args))[0][0]

def neutralise(frappe, keep_admin=True):
    # runs the whole list; the caller commits. Returns [(key, count, label)] in list order.
    tables = set(r[0] for r in frappe.db.sql("select table_name from information_schema.tables where table_schema = database()"))
    counts, labels, order = {}, {}, []
    for key, doctype, op, fields, where, label in NEUTRALISE:
        if key not in counts:
            counts[key], labels[key] = 0, label
            order.append(key)
        table = "__Auth" if op == "auth" else "tab" + doctype
        n = 0
        if op == "auth":
            if table in tables:
                condition, args = "1 = 1", ()
                if keep_admin:
                    condition, args = "not (doctype = %s and name = %s and fieldname = %s)", ("User", "Administrator", "password")
                n = _count(frappe, table, condition, args)
                frappe.db.sql("delete from `" + table + "` where " + condition, args)
        elif op == "orphans":
            if table in tables and "tab" + fields in tables:
                frappe.db.sql("delete from `" + table + "` where not exists (select 1 from `tab" + fields + "` p where p.name = `" + table + "`.parent)")
        elif table not in tables:
            # no table of its own: a single doctype keeps its fields in tabSingles
            if op == "set" and "tabSingles" in tables:
                for field, value in fields.items():
                    if value == 1:
                        test, args = "ifnull(value, %s) != %s", ("", "1")
                    elif value == 0:
                        test, args = "ifnull(value, %s) not in (%s, %s)", ("", "", "0")
                    else:
                        test, args = "ifnull(value, %s) != %s", ("", "")
                    base = "doctype = %s and field = %s and " + test
                    base_args = (doctype, field) + args
                    if _count(frappe, "tabSingles", base, base_args):
                        n = 1
                        frappe.db.sql("update `tabSingles` set value = %s where " + base, (str(value or "") if value != 0 else "0",) + base_args)
        else:
            columns = set(r[0] for r in frappe.db.sql("select column_name from information_schema.columns where table_schema = database() and table_name = %s", (table,)))
            where_sql, where_args = _where(where)
            usable = all(column in columns for column in (where or {}))
            if op == "delete" and usable:
                condition = where_sql or "1 = 1"
                n = _count(frappe, table, condition, where_args)
                frappe.db.sql("delete from `" + table + "` where " + condition, tuple(where_args))
            elif op == "set" and usable:
                fields = dict((c, v) for c, v in fields.items() if c in columns)
                if fields:
                    changed, changed_args = [], []
                    for column, value in fields.items():
                        changed.append(_changed(column, value))
                        changed_args.extend(_changed_args(value))
                    condition = "(" + " or ".join(changed) + ")" + (" and " + where_sql if where_sql else "")
                    args = tuple(changed_args) + tuple(where_args)
                    n = _count(frappe, table, condition, args)
                    if n:
                        sets = ", ".join("`%s` = %%s" % c for c in fields)
                        frappe.db.sql("update `" + table + "` set " + sets + " where " + condition, tuple(fields.values()) + args)
        counts[key] += n
    return [(key, counts[key], labels[key]) for key in order]
'

# The helper pull runs on the copy (argv: SITE KEEP_ADMIN). It commits and prints
# one "BENCHBAR-RESULT KEY<US>COUNT<US>LABEL" row per key, counts only, never a
# name or a secret.
# shellcheck disable=SC2016  # Python source: the backticks and dollar signs are not the shell's
FL_PY_NEUTRALISE_BODY='
import sys
site, keep_admin = sys.argv[2], sys.argv[3] == "1"
import frappe
frappe.init(site=site)
frappe.connect()
try:
    rows = neutralise(frappe, keep_admin)
    frappe.db.commit()
    for key, count, label in rows:
        print("\nBENCHBAR-RESULT %s\x1f%d\x1f%s" % (key, count, label), flush=True)
finally:
    frappe.destroy()'
FL_PY_NEUTRALISE_RUN="${FL_PY_NEUTRALISE}${FL_PY_NEUTRALISE_BODY}"

# fl_neutralise_run_v VAR SITE KEEP_ADMIN: runs the routine on SITE in the bench's
# Python. KEEP_ADMIN 1 keeps the Administrator login. VAR gets one row per key,
# "KEY<US>COUNT<US>LABEL" (US is the unit separator), every key, zero counts too.
fl_neutralise_run_v() {
  fl_bench_python_v "$1" "$FL_PY_NEUTRALISE_RUN" benchbar-neutralise "$2" "${3:-1}" </dev/null
}

# fl_neutralise_summary_v VAR ROWS: "2 webhooks switched off, 41 stored secrets
# cleared" from the rows, the keys with a count of zero left out ("nothing to
# switch off" when there are none)
fl_neutralise_summary_v() {
  local __var="$1" __row __key __count __label __out="" us=$'\x1f'
  while IFS= read -r __row; do
    [[ -n "$__row" ]] || continue
    __key="${__row%%"$us"*}"; __row="${__row#*"$us"}"
    __count="${__row%%"$us"*}"; __label="${__row#*"$us"}"
    [[ "$__count" =~ ^[0-9]+$ && "$__count" != "0" ]] || continue
    __out="${__out}${__out:+, }${__count} ${__label}"
  done <<<"$2"
  printf -v "$__var" '%s' "${__out:-nothing to switch off or clear}"
}

# fl_neutralise_json_v VAR ROWS: {"on":true,"counts":{...},"labels":{...}} for a done line
fl_neutralise_json_v() {
  local __var="$1" __row __key __count __label __c="" __l="" __sc="" __sl="" us=$'\x1f'
  while IFS= read -r __row; do
    [[ -n "$__row" ]] || continue
    __key="${__row%%"$us"*}"; __row="${__row#*"$us"}"
    __count="${__row%%"$us"*}"; __label="${__row#*"$us"}"
    [[ "$__count" =~ ^[0-9]+$ ]] || continue
    __c="${__c}${__sc}$(fl_json_str "$__key"):${__count}"; __sc=","
    __l="${__l}${__sl}$(fl_json_str "$__key"):$(fl_json_str "$__label")"; __sl=","
  done <<<"$2"
  printf -v "$__var" '{"on":true,"counts":{%s},"labels":{%s}}' "$__c" "$__l"
}
