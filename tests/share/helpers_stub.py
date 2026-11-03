"""Runs the real Python of benchbar's share helpers (users, harden) under a
stand-in frappe whose database applies %-style parameters the way pymysql
does, so a format mistake in a query raises here and not on a real site.

usage: helpers_stub.py USERS_SNIPPET_FILE HARDEN_SNIPPET_FILE
"""
import io
import json
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
    return "'" + str(value).replace("\\", "\\\\").replace("'", "\\'") + "'"


def render(query, values):
    # pymysql: no arguments, no substitution; arguments, always "query % escaped"
    if values is None:
        return query
    if isinstance(values, dict):
        return query % {k: escape(v) for k, v in values.items()}
    if not isinstance(values, (tuple, list)):
        values = (values,)
    return query % tuple(escape(v) for v in values)


class DB:
    def __init__(self, scenario):
        self.scenario = scenario
        self.log = []

    def sql(self, query, values=None, as_dict=False):
        text = render(query, values)
        self.log.append(text)
        return self.scenario.answer(text, as_dict)

    def sql_list(self, query, values=None):
        text = render(query, values)
        self.log.append(text)
        return self.scenario.answer_list(text)

    def get_single_value(self, *args):
        return self.scenario.single.get(args[1])

    def set_single_value(self, doctype, field, value):
        self.log.append("single %s.%s=%r" % (doctype, field, value))

    def delete(self, doctype, filters=None):
        self.log.append("delete %s %r" % (doctype, filters))

    def truncate(self, doctype):
        self.log.append("truncate %s" % doctype)

    def table_exists(self, doctype):
        return doctype not in self.scenario.missing_tables

    def has_column(self, doctype, column):
        return True

    def commit(self):
        self.log.append("COMMIT")

    def rollback(self):
        self.log.append("ROLLBACK")


class Scenario:
    def __init__(self, users, profiles_kept=False, missing_tables=()):
        self.users = users
        self.profiles_kept = profiles_kept
        self.missing_tables = set(missing_tables)
        self.single = {"default_role": "Customer"}
        self.profile_cut = False
        self.db = None

    def answer(self, q, as_dict):
        if "from `tabDocPerm`" in q:
            return [{"parent": "Server Script", "role": "Script Dev", "write": 1, "create": 0, "submit": 0}]
        if "from `tabCustom DocPerm`" in q:
            return []
        if "select name, enabled, user_type from `tabUser` where name in" in q:
            return [dict(name=u["name"], enabled=u["enabled"], user_type=u["user_type"]) for u in self.users]
        if "from `tabUser` where name !=" in q:
            limit = int(q.rsplit("limit ", 1)[1])
            return [dict(u) for u in self.users][:limit]
        if "from `tabHas Role`" in q and "select parent, role" in q:
            return [dict(parent=u["name"], role=r) for u in self.users for r in u["roles"]]
        if "select count(*) from `tabUser Role Profile`" in q:
            return [[1]]
        if "select count(*)" in q:
            return [[3]]
        if "set role_profile_name = NULL" in q:
            self.profile_cut = True
        return []

    def answer_list(self, q):
        if "role_profile_name" in q:
            if self.profiles_kept or not self.profile_cut:
                return ["u@x.com"]
            return []
        if "select role from `tabHas Role`" in q:
            return ["System Manager", "Sales User"]
        return []


def run(snippet, argv, scenario, stdin=""):
    scenario.db = DB(scenario)
    frappe = types.ModuleType("frappe")
    frappe.db = scenario.db
    frappe.cache = types.SimpleNamespace(hdel=lambda *a: None)
    frappe.init = frappe.connect = frappe.destroy = frappe.clear_cache = lambda *a, **k: None
    password = types.ModuleType("frappe.utils.password")
    password.update_password = lambda *a, **k: None
    saved = dict(sys.modules), sys.argv, sys.stdin, sys.stdout
    sys.modules.update({"frappe": frappe, "frappe.utils": types.ModuleType("frappe.utils"), "frappe.utils.password": password})
    sys.argv = ["-c"] + argv
    sys.stdin = io.StringIO(stdin)
    out = io.StringIO()
    sys.stdout = out
    code = 0
    try:
        exec(snippet, {"__name__": "__main__"})
    except SystemExit as e:
        code = e.code or 0
    finally:
        sys.modules.clear()
        sys.modules.update(saved[0])
        sys.argv, sys.stdin, sys.stdout = saved[1:]
    return code, out.getvalue(), scenario.db.log


def results(text):
    return [line[len("BENCHBAR-RESULT "):] for line in text.split("\n") if line.startswith("BENCHBAR-RESULT ")]


def user(name, roles, kind="System User"):
    return {"name": name, "full_name": name.title(), "enabled": 1, "user_type": kind, "roles": roles}


def main():
    users_snippet = open(sys.argv[1]).read()
    harden_snippet = open(sys.argv[2]).read()
    base = [user("Administrator", []), user("u@x.com", ["System Manager", "Script Dev", "Sales User"]), user("web@x.com", ["Customer"], "Website User")]

    for mode in ("json", "rows", "classes"):
        code, out, log = run(users_snippet, ["m", "macdev", mode], Scenario(base))
        assert code == 0 and results(out), (mode, code, out)
    code, out, log = run(users_snippet, ["m", "macdev", "json"], Scenario(base))
    doc = json.loads(results(out)[0])
    by_name = {u["name"]: u for u in doc["users"]}
    assert doc["truncated"] is False
    assert by_name["u@x.com"]["will_demote"] and sorted(by_name["u@x.com"]["code_capable_roles"]) == ["Script Dev", "System Manager"], by_name["u@x.com"]
    assert by_name["u@x.com"]["selectable"] and not by_name["web@x.com"]["selectable"] and not by_name["Administrator"]["selectable"]
    assert any(q.endswith("limit 5001") for q in log), log
    # the cap: one more user than it allows is dropped and said
    many = [user("a%d@x.com" % i, []) for i in range(5001)]
    code, out, log = run(users_snippet, ["m", "macdev", "json"], Scenario(many))
    doc = json.loads(results(out)[0])
    assert doc["truncated"] is True and len(doc["users"]) == 5000
    code, out, log = run(users_snippet, ["m", "macdev", "rows"], Scenario(many))
    assert results(out)[0] == "\x1ftruncated\x1f1", results(out)[0]

    # harden: the role profile is cut before the roles go, the allowed user is demoted, sessions are deleted
    seat = [user("u@x.com", ["System Manager", "Script Dev", "Sales User"])]
    code, out, log = run(harden_snippet, ["m", "share.localhost"], Scenario(seat), "u@x.com\n")
    assert code == 0, (out, log)
    counts = json.loads(results(out)[0])
    assert counts["role_profiles_cleared"] == 2 and counts["users_demoted"] == 1 and counts["roles_removed"] == 1, counts
    cut = next(i for i, q in enumerate(log) if "set role_profile_name = NULL" in q)
    gone = next(i for i, q in enumerate(log) if q.startswith("delete from `tabHas Role`"))
    assert cut < gone, log
    assert any("tabUser Role Profile" in q for q in log)
    assert "COMMIT" in log
    # a seat that keeps a profile is refused and rolled back
    code, out, log = run(harden_snippet, ["m", "share.localhost"], Scenario(seat, profiles_kept=True), "u@x.com\n")
    assert code == 1 and "BENCHBAR-ERROR" in out and "ROLLBACK" in log, (code, out)
    # Administrator and Guest are never seats
    code, out, log = run(harden_snippet, ["m", "share.localhost"], Scenario(base), "Administrator\n")
    assert code == 1 and "BENCHBAR-ERROR" in out
    # a bench without the optional tables
    code, out, log = run(harden_snippet, ["m", "share.localhost"], Scenario(seat, missing_tables=("User Role Profile", "Social Login Key", "Token Cache")), "u@x.com\n")
    assert code == 0, (out, log)
    print("helpers_stub: ok")


main()
