"""Unit tests of lib/frappe-local/mcp.py (askysh/benchbar#157, MCP-18): dispatch, validate, scrub, cap and
the tool table. Standard library only, Python 3.9 syntax. Run by tests/test-mcp-unit.sh."""
import importlib.util
import io
import json
import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("mcp", os.path.join(ROOT, "lib", "frappe-local", "mcp.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def server():
    out = io.StringIO()
    s = m.Server(out)
    s.initialized = True
    return s, out


def replies(out):
    return [json.loads(line) for line in out.getvalue().splitlines() if line.strip()]


class ToolTable(unittest.TestCase):
    def test_every_tool_has_the_five_facts(self):
        for name, tool in m.TOOLS.items():
            self.assertIsInstance(tool, m.Tool, name)
            self.assertTrue(tool.description, name)
            self.assertIsInstance(tool.props, dict, name)
            self.assertTrue(callable(tool.build), name)
            self.assertIsInstance(tool.read_only, bool, name)
            self.assertIsInstance(tool.codes, tuple, name)

    def test_every_side_table_key_is_a_known_tool(self):
        tables = {"REQUIRED": m.REQUIRED, "ENV": m.ENV, "ANNOTATIONS": m.ANNOTATIONS, "UNTRUSTED": m.UNTRUSTED,
                  "TIMEOUTS": m.TIMEOUTS, "AFTER": m.AFTER, "PLAN_OF": m.PLAN_OF, "LAB_OF": m.LAB_OF,
                  "OUTPUT_SCHEMAS": m.OUTPUT_SCHEMAS}
        for label, table in tables.items():
            for key in table:
                self.assertIn(key, m.TOOLS, "%s names a tool that does not exist: %s" % (label, key))
        for plan in m.PLAN_OF.values():
            self.assertIn(plan, m.TOOLS, plan)

    def test_required_arguments_are_properties(self):
        for name, keys in m.REQUIRED.items():
            for key in keys:
                self.assertIn(key, m.TOOLS[name].props, "%s requires %s, which is no property" % (name, key))

    def test_titles(self):
        self.assertEqual(m.tool_title("benchbar_site_add_plan"), "Site add plan")
        for entry in m.tool_list()["tools"]:
            self.assertTrue(entry["title"], entry["name"])

    def test_profile_check_has_its_own_limit(self):
        self.assertGreater(m.TIMEOUTS["benchbar_profile_check"], 180)


class Validate(unittest.TestCase):
    PROPS = {"n": {"type": "integer", "minimum": 1, "maximum": 5}, "e": {"type": "string", "enum": ["a", "b"]},
             "s": {"type": "string"}, "b": {"type": "boolean"}}

    def test_ok(self):
        self.assertIsNone(m.validate(self.PROPS, {"n": 3, "e": "a", "s": "x", "b": True}))

    def test_problems(self):
        for args, word in (({"n": 0}, "at least"), ({"n": 6}, "at most"), ({"n": "1"}, "integer"), ({"n": True}, "integer"),
                           ({"e": "c"}, "one of"), ({"s": 1}, "string"), ({"b": "no"}, "boolean")):
            self.assertIn(word, m.validate(self.PROPS, args), args)


class Scrub(unittest.TestCase):
    def test_color_codes_go(self):
        self.assertEqual(m.scrub("\x1b[31mred\x1b[0m"), "red")

    def test_nested(self):
        self.assertEqual(m.scrub({"a": ["\x1b[1mx"]}), {"a": ["x"]})

    def test_the_password_store_is_withheld(self):
        out = m.scrub("fine\nthe password is in the Keychain\nalso fine")
        self.assertNotIn("Keychain", out)
        self.assertIn("fine", out)


class Cap(unittest.TestCase):
    def test_small_result_is_unchanged(self):
        r = m.envelope("x", {"a": 1})
        self.assertIs(m.cap(r, "x"), r)

    def test_big_result_is_cut_and_marked(self):
        old = m.MAX_BYTES
        m.MAX_BYTES = 2000
        try:
            r = m.cap(m.envelope("x", {"lines": ["line %d" % i for i in range(2000)]}), "x")
        finally:
            m.MAX_BYTES = old
        self.assertTrue(r["structuredContent"]["truncated"])
        self.assertLessEqual(len(r["content"][0]["text"].encode()), 2000)
        self.assertEqual(r["structuredContent"]["lines"][-1], "line 1999")      # the newest stay

    def test_the_notice_is_in_structured_content_and_text(self):
        r = m.envelope("x", {"a": 1})
        self.assertEqual(r["structuredContent"]["_notice"], m.NOTICE)
        self.assertEqual(json.loads(r["content"][0]["text"].split("\n", 1)[1]), r["structuredContent"])
        self.assertIn("_notice", m.failed_result("no", 1)["structuredContent"])
        self.assertIn("_notice", m.bench_error("boom", 1)["structuredContent"])


class ToolCall(unittest.TestCase):
    def test_a_bad_name_is_unknown_tool(self):
        for name in (None, 5, ["x"], {"a": 1}, "nope"):
            with self.assertRaises(m.RpcError) as ctx:
                m.tool_call({"name": name, "arguments": {}})
            self.assertEqual(ctx.exception.code, -32602, name)

    def test_argument_problems_are_tool_errors(self):
        for args in ({}, {"site": "x", "z": 1}, {"site": "--yes"}, {"site": "a\x00b"}, {"site": 5}):
            r = m.tool_call({"name": "benchbar_site_backups", "arguments": args})
            self.assertTrue(r["isError"], args)
        self.assertTrue(m.tool_call({"name": "benchbar_list", "arguments": ["x"]})["isError"])

    def test_control_characters(self):
        self.assertEqual(m.control_char({"a": ["ok", "b\x07"]}, ""), "a[1]")
        self.assertIsNone(m.control_char({"a": "plain text, ü"}, ""))


class Dispatch(unittest.TestCase):
    def test_client_replies_are_ignored(self):
        s, out = server()
        s.dispatch(b'{"jsonrpc":"2.0","id":5,"result":{}}')
        s.dispatch(b'{"jsonrpc":"2.0","id":6,"error":{"code":1,"message":"x"}}')
        self.assertEqual(replies(out), [])

    def test_ping_and_garbage(self):
        s, out = server()
        s.dispatch(b'{"jsonrpc":"2.0","id":1,"method":"ping"}')
        s.dispatch(b"not json")
        s.dispatch(b"[1]")
        s.dispatch(b'{"jsonrpc":"2.0","id":2,"method":"nope"}')
        got = replies(out)
        self.assertEqual(got[0]["result"], {})
        self.assertEqual([g["error"]["code"] for g in got[1:]], [-32700, -32600, -32601])

    def test_busy_when_the_cap_is_reached(self):
        s, out = server()
        old = m.MAX_INFLIGHT
        m.MAX_INFLIGHT = 1
        try:
            s.inflight[1] = m.Call(1)
            s.start_call(2, {"name": "benchbar_list", "arguments": {}})
        finally:
            m.MAX_INFLIGHT = old
        got = replies(out)
        self.assertTrue(got[0]["result"]["isError"])
        self.assertIn("busy", got[0]["result"]["content"][0]["text"])

    def test_terminate_only_sets_a_flag(self):
        s, _out = server()
        s.terminate()
        self.assertTrue(s.terminating)


if __name__ == "__main__":
    unittest.main(verbosity=1)
