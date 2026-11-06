#!/usr/bin/env python3
# Run by the sharing gateway with the bench's Python, once per request, so
# that nothing here outlives a call:
#
#   signin.py SITE USER          starts a session of USER; stdout is the sid
#   signin.py wipe SITE USER     ends every session of USER; stdout is a count
#
# Nothing but the sid or the count goes to stdout, nothing is logged, and no
# secret travels in argv. A refusal is exit 1 and no output. USER must be an
# enabled System User and never Administrator or Guest: a seat is a demoted
# person, and the gateway maps devices to seats, so this is the second lock.
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_mint import mint_session  # noqa: E402

REFUSED_USERS = ("Administrator", "Guest")


def sites_dir():
    explicit = os.environ.get("BENCHBAR_SITES_DIR")
    if explicit:
        return explicit
    # <bench>/env/bin/python: the venv's own path, not its resolved target
    bench = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(sys.executable))))
    return os.path.join(bench, "sites")


def seat_row(frappe, user):
    row = frappe.db.get_value("User", user, ["name", "enabled", "first_name", "last_name", "user_type"], as_dict=True)
    if not row or not row.enabled or row.user_type != "System User" or row.name in REFUSED_USERS:
        return None
    return row


def wipe(frappe, user):
    import frappe.sessions
    sids = frappe.db.sql_list("select sid from `tabSessions` where user = %s", (user,))
    for sid in sids:
        frappe.sessions.delete_session(sid, user=user, reason="BenchBar room")
    return len(sids)


def main(argv):
    do_wipe = argv[:1] == ["wipe"]
    args = argv[1:] if do_wipe else argv
    if len(args) != 2 or not all(args):
        return 2
    site, user = args
    os.chdir(sites_dir())
    import frappe
    frappe.init(site=site)
    frappe.connect()
    try:
        if do_wipe:
            sys.stdout.write("%d\n" % wipe(frappe, user))
            return 0
        row = seat_row(frappe, user)
        if row is None:
            return 1
        try:
            _, sid = mint_session(frappe, row)
        except frappe.AuthenticationError:
            return 1
        sys.stdout.write(sid + "\n")
        return 0
    finally:
        frappe.destroy()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
