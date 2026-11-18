"""Runs the real Python of benchbar's neutralisation routine (lib/frappe-local/neutralise.sh)
under a stand-in frappe whose database is an in-memory sqlite. Parameters are applied
the way pymysql does (the query is formatted with the escaped values), so a format
mistake in a query raises here and not on a real site.

usage: neutralise_stub.py SNIPPET_FILE
The snippet is the whole helper (FL_PY_NEUTRALISE_RUN), run with argv "benchbar-neutralise SITE KEEP_ADMIN".
"""
import io
import json
import re
import sqlite3
import sys
import types


def escape(value):
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, (tuple, list, set)):
        return "(" + ",".join(escape(v) for v in value) + ")"
    return "'" + str(value).replace("'", "''") + "'"


def render(query, values):
    if values is None:
        return query
    if isinstance(values, dict):
        return query % {k: escape(v) for k, v in values.items()}
    if not isinstance(values, (tuple, list)):
        values = (values,)
    return query % tuple(escape(v) for v in values)


def mariadb_like(pattern, value):
    # LIKE as MariaDB has it: backslash escapes, % and _ are wildcards, case does not matter
    if pattern is None or value is None:
        return None
    out, i = "", 0
    while i < len(pattern):
        c = pattern[i]
        if c == "\\" and i + 1 < len(pattern):
            out += re.escape(pattern[i + 1])
            i += 1
        elif c == "%":
            out += ".*"
        elif c == "_":
            out += "."
        else:
            out += re.escape(c)
        i += 1
    return 1 if re.fullmatch(out, str(value), re.S | re.I) else 0


class DB:
    def __init__(self):
        self.con = sqlite3.connect(":memory:")
        self.con.create_function("like", 2, mariadb_like)
        self.log = []

    def sql(self, query, values=None, as_dict=False):
        # information_schema is answered from sqlite itself
        if "information_schema.tables" in query:
            return [(r[0],) for r in self.con.execute("select name from sqlite_master where type = 'table'")]
        if "information_schema.columns" in query:
            return [(r[1],) for r in self.con.execute("pragma table_info(`%s`)" % values[0])]
        text = render(query, values)
        self.log.append(text)
        cur = self.con.execute(text)
        return cur.fetchall()

    def table_exists(self, doctype):
        row = self.con.execute("select 1 from sqlite_master where type = 'table' and name = ?", ("tab" + doctype,)).fetchone()
        return bool(row)

    def has_column(self, doctype, column):
        cols = [r[1] for r in self.con.execute("pragma table_info(`tab%s`)" % doctype)]
        return column in cols

    def commit(self):
        self.log.append("COMMIT")


def build():
    db = DB()
    run = db.con.executescript
    run("""
    create table `tabWebhook` (name text, enabled int, webhook_secret text);
    insert into `tabWebhook` values ('hook a', 1, '*****'), ('hook b', 1, null), ('hook c', 0, null);
    create table `tabEmail Account` (name text, enable_outgoing int, enable_incoming int, enable_auto_reply int, password text);
    insert into `tabEmail Account` values ('Sales', 1, 1, 0, '*****'), ('Support', 0, 1, 1, null);
    create table `tabSlack Webhook URL` (name text, webhook_url text);
    insert into `tabSlack Webhook URL` values ('ops', 'https://hooks.slack.com/services/T0/B0/secret'), ('empty', '');
    create table `tabOAuth Bearer Token` (name text, access_token text);
    insert into `tabOAuth Bearer Token` values ('t1', 'tok'), ('t2', 'tok2');
    create table `tabToken Cache` (name text, access_token text);
    insert into `tabToken Cache` values ('c1', '*****');
    create table `tabIntegration Request` (name text, data text);
    insert into `tabIntegration Request` values ('i1', '{"key": "live"}');
    create table `tabEmail Queue` (name text, status text);
    insert into `tabEmail Queue` values ('q1', 'Not Sent'), ('q2', 'Sending'), ('q3', 'Sent'), ('q4', 'Partially Sent'), ('q5', 'Error');
    create table `tabEmail Queue Recipient` (name text, parent text, recipient text, status text);
    insert into `tabEmail Queue Recipient` values ('r1', 'q1', 'a@x.com', 'Not Sent'), ('r2', 'q3', 'b@x.com', 'Sent'), ('r3', 'q4', 'c@x.com', 'Not Sent');
    create table `tabScheduled Job Type` (name text, method text, stopped int);
    insert into `tabScheduled Job Type` values
      ('j1', 'frappe.email.queue.flush', 0),
      ('j2', 'frappe.integrations.doctype.s3_backup_settings.s3_backup_settings.take_backups_daily', 0),
      ('j3', 'frappe.sessions.clear_expired_sessions', 0),
      ('j4', 'hrms.controllers.employee_reminders.send_birthday_reminders', 0);
    create table `tabServer Script` (name text, script text, disabled int);
    insert into `tabServer Script` values
      ('calls out', 'r = frappe.make_post_request("https://x.example", data={})', 0),
      ('local only', 'doc.status = "Open"', 0);
    create table `tabUser` (name text, api_key text, reset_password_key text);
    insert into `tabUser` values ('Administrator', 'adminkey', ''), ('a@x.com', 'key', 'resetkey'), ('b@x.com', null, null);
    create table `tabAuto Repeat` (name text, disabled int);
    insert into `tabAuto Repeat` values ('ar1', 0), ('ar2', 1);
    create table `tabSingles` (doctype text, field text, value text);
    insert into `tabSingles` values
      ('Google Settings', 'enable', '1'), ('Google Settings', 'api_key', 'AIza'),
      ('S3 Backup Settings', 'enabled', '1'), ('S3 Backup Settings', 'access_key_id', 'AKIA'), ('S3 Backup Settings', 'bucket', 'prod-backups'),
      ('LDAP Settings', 'enabled', '1'), ('LDAP Settings', 'ldap_server_url', 'ldaps://ldap.example.com'),
      ('SMS Settings', 'sms_gateway_url', 'https://sms.example.com/send?key=live'),
      ('Razorpay Settings', 'api_key', 'rzp_live_x'),
      ('Push Notification Settings', 'enable_push_notification_relay', '1'),
      ('System Settings', 'enable_scheduler', '1');
    create table `__Auth` (doctype text, name text, fieldname text, password text, encrypted int);
    insert into `__Auth` values
      ('User', 'Administrator', 'password', 'hash-of-the-admin-login', 0),
      ('User', 'a@x.com', 'password', 'hash-a', 0),
      ('User', 'a@x.com', 'api_secret', 'enc-secret', 1),
      ('Email Account', 'Sales', 'password', 'enc-smtp', 1),
      ('Webhook', 'hook a', 'webhook_secret', 'enc-hook', 1),
      ('Social Login Key', 'github', 'client_secret', 'enc-oauth', 1);
    create table `tabSocial Login Key` (name text, enable_social_login int);
    insert into `tabSocial Login Key` values ('github', 1);
    """)
    return db


def run(snippet, argv, db, keep_admin_arg):
    frappe = types.ModuleType("frappe")
    frappe.db = db
    frappe.init = lambda **kw: None
    frappe.connect = lambda: None
    frappe.destroy = lambda: None
    frappe.clear_cache = lambda: None
    sys.modules["frappe"] = frappe
    out = io.StringIO()
    real = sys.stdout
    sys.stdout = out
    old_argv = sys.argv
    sys.argv = ["-c"] + argv
    try:
        exec(compile(snippet, "neutralise", "exec"), {"__name__": "__main__"})
    finally:
        sys.stdout = real
        sys.argv = old_argv
    rows = {}
    for line in out.getvalue().splitlines():
        if line.startswith("BENCHBAR-RESULT "):
            key, count, label = line[len("BENCHBAR-RESULT "):].split("\x1f")
            rows[key] = (int(count), label)
    return rows


def count(db, sql):
    return db.con.execute(sql).fetchone()[0]


def main():
    snippet = open(sys.argv[1]).read()
    db = build()
    rows = run(snippet, ["benchbar-neutralise", "copy.localhost", "1"], db, "1")
    got = {k: v[0] for k, v in rows.items()}

    # outbound switches are off
    assert count(db, "select count(*) from `tabWebhook` where enabled = 1") == 0, "webhooks"
    assert got["webhooks"] == 2, got
    assert count(db, "select count(*) from `tabEmail Account` where enable_outgoing = 1 or enable_incoming = 1 or enable_auto_reply = 1") == 0
    assert got["email_accounts"] == 2, got
    assert count(db, "select count(*) from `tabSocial Login Key` where enable_social_login = 1") == 0
    assert count(db, "select count(*) from `tabAuto Repeat` where disabled != 1") == 0 and got["auto_repeats"] == 1, got
    # plain secrets and URLs are blank
    assert count(db, "select count(*) from `tabSlack Webhook URL` where ifnull(webhook_url, '') != ''") == 0 and got["slack_webhooks"] == 1, got
    assert count(db, "select count(*) from `tabUser` where ifnull(api_key, '') != ''") == 0 and got["api_keys"] == 2, got
    assert count(db, "select count(*) from `tabUser` where ifnull(reset_password_key, '') != ''") == 0
    # tokens, requests and queued mail are gone; sent mail stays
    for table in ("OAuth Bearer Token", "Token Cache", "Integration Request"):
        assert count(db, "select count(*) from `tab%s`" % table) == 0, table
    assert [r[0] for r in db.con.execute("select name from `tabEmail Queue` order by name")] == ["q3", "q5"], "unsent mail kept"
    assert [r[0] for r in db.con.execute("select name from `tabEmail Queue Recipient`")] == ["r2"], "orphan recipients kept"
    assert got["email_queue"] == 3, got
    # scheduled jobs that call out are stopped, a housekeeping job is not
    stopped = {r[0]: r[1] for r in db.con.execute("select name, stopped from `tabScheduled Job Type`")}
    assert stopped == {"j1": 1, "j2": 1, "j3": 0, "j4": 1}, stopped
    assert {r[0]: r[1] for r in db.con.execute("select name, disabled from `tabServer Script`")} == {"calls out": 1, "local only": 0}
    # single doctypes live in tabSingles
    singles = {(r[0], r[1]): r[2] for r in db.con.execute("select doctype, field, value from `tabSingles`")}
    assert singles[("Google Settings", "enable")] == "0" and singles[("Google Settings", "api_key")] == ""
    assert singles[("S3 Backup Settings", "enabled")] == "0" and singles[("S3 Backup Settings", "access_key_id")] == ""
    assert singles[("S3 Backup Settings", "bucket")] == "prod-backups", "what is not a secret stays"
    assert singles[("LDAP Settings", "enabled")] == "0" and singles[("LDAP Settings", "ldap_server_url")] == ""
    assert singles[("SMS Settings", "sms_gateway_url")] == "" and singles[("Razorpay Settings", "api_key")] == ""
    assert singles[("Push Notification Settings", "enable_push_notification_relay")] == "0"
    assert singles[("System Settings", "enable_scheduler")] == "1", "the scheduler is pull's own business"
    # every stored password goes but the Administrator login
    left = db.con.execute("select doctype, name, fieldname from `__Auth`").fetchall()
    assert left == [("User", "Administrator", "password")], left
    assert got["stored_secrets"] == 5, got
    # a second run finds nothing to do
    again = {k: v[0] for k, v in run(snippet, ["benchbar-neutralise", "copy.localhost", "1"], db, "1").items()}
    assert not any(again.values()), again
    # a site without the Administrator login kept: everything goes
    db = build()
    run(snippet, ["benchbar-neutralise", "copy.localhost", "0"], db, "0")
    assert count(db, "select count(*) from `__Auth`") == 0
    # a bench that lacks a table (an app not installed) is skipped, not an error
    db = build()
    db.con.execute("drop table `tabWebhook`")
    db.con.execute("drop table `tabEmail Queue Recipient`")
    rows = run(snippet, ["benchbar-neutralise", "copy.localhost", "1"], db, "1")
    assert rows["webhooks"][0] == 0
    print("neutralise_stub: ok")


main()
