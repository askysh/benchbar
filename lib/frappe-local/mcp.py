#!/usr/bin/env python3
"""benchbar mcp: a Model Context Protocol server over stdio.

Coding agents (Claude Code, Cursor, ...) can list benches, read status,
doctor and log tails, start, stop or restart a bench, and add an app from
a plan the person approved (the plan's token). Every tool runs
`benchbar ... --json` and hands back what the CLI printed: no logic about
benches lives here, so the CLI stays the only thing that touches a bench.
Nothing that repairs, installs a bench or needs sudo is offered.

Standard library only, Python 3.9 or newer (the Command Line Tools' python3).
Messages are JSON-RPC 2.0, one per line on stdin and stdout; stderr is for
humans.
"""

import json
import os
import signal
import subprocess
import sys
import time

SERVER = {"name": "benchbar", "version": os.environ.get("BENCHBAR_VERSION", "0")}
PROTOCOLS = ["2025-06-18", "2025-03-26", "2024-11-05"]
BENCHBAR = os.environ.get("BENCHBAR") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "benchbar")

BENCH = {
    "type": "string",
    "description": "Absolute path of the bench (from benchbar_list). Omit for the default bench.",
}

# name -> (description, extra input properties, argv builder, read only, exit codes that still carry JSON)
TOOLS = {
    "benchbar_list": (
        "Every Frappe bench benchbar knows on this Mac: path, default site, sites, ports, whether its service is installed.",
        {},
        lambda a: ["list", "--json"],
        True,
        (0,),
    ),
    "benchbar_status": (
        "Live state of one bench: stopped, starting, running, crashed or paused, with pid, uptime start, ports, sites and site ping.",
        {"bench": BENCH},
        lambda a: ["status", "--json"] + bench_args(a),
        True,
        (0,),
    ),
    "benchbar_doctor": (
        "Read only health report of one bench: every check with its level and the exact fix command.",
        {"bench": BENCH},
        lambda a: ["doctor", "--json"] + bench_args(a),
        True,
        (0, 1),
    ),
    "benchbar_logs_tail": (
        "The last lines of the bench log (logs/bench.log), optionally only one honcho process.",
        {
            "bench": BENCH,
            "lines": {"type": "integer", "minimum": 1, "maximum": 2000, "description": "How many lines (default 100)."},
            "process": {
                "type": "string",
                "enum": ["web", "worker", "socketio", "schedule", "redis_queue", "redis_cache"],
                "description": "Only lines from this process.",
            },
        },
        lambda a: ["logs", "--json", "--no-follow", "-n%d" % int(a.get("lines") or 100)]
        + (["--process", a["process"]] if a.get("process") else [])
        + bench_args(a),
        True,
        (0,),
    ),
    "benchbar_site_list": (
        "The sites of one bench, which one is the default, whether /etc/hosts has it, and its ping code.",
        {"bench": BENCH},
        lambda a: ["site", "list", "--json"] + bench_args(a),
        True,
        (0,),
    ),
    "benchbar_profile_list": (
        "Built in and team profiles (user, imported, subscribed, BENCHBAR_PROFILE_PATH): source, subscription "
        "and how far behind it is, what shadows what, and parse errors.",
        {},
        lambda a: ["profile", "list", "--json"],
        True,
        (0,),
    ),
    "benchbar_profile_check": (
        "Whether git can read every repo of a team profile with the user's own credentials (reachable true, false, "
        "or null when offline), and which apps install --profile would leave out.",
        {"name": {"type": "string", "description": "The team profile name (from benchbar_profile_list)."}},
        lambda a: ["profile", "check", "--json", "--", required(a, "name")],
        True,
        (0,),
    ),
    "benchbar_up": (
        "Start a bench in the background (launchd) and wait for its default site to answer.",
        {"bench": BENCH},
        lambda a: ["up", "--plain"] + bench_args(a),
        False,
        (0,),
    ),
    "benchbar_down": (
        "Stop a bench and keep it stopped, also across reboots. Only this bench's processes are stopped.",
        {"bench": BENCH},
        lambda a: ["down", "--plain"] + bench_args(a),
        False,
        (0,),
    ),
    "benchbar_restart": (
        "Restart every process of a bench, for example after changing Python code.",
        {"bench": BENCH},
        lambda a: ["restart", "--plain"] + bench_args(a),
        False,
        (0,),
    ),
}


def required(arguments, key):
    value = arguments.get(key)
    if not isinstance(value, str) or not value:
        raise RpcError(-32602, "%s is required" % key)
    return value


APP_ADD = {
    "url_or_name": {"type": "string", "description": "A git URL (https, SSH, a host alias) or an app name from config/apps.tsv or the team profile."},
    "branch": {"type": "string", "description": "Branch or tag. Default: the known branch for a known app, else the remote's default branch."},
    "name": {"type": "string", "description": "The app (Python package) name, when it differs from the repository name."},
    "site": {"type": "string", "description": "Install the app on this site."},
    "all_sites": {"type": "boolean", "description": "Install the app on every site of the bench."},
    "bench": BENCH,
}


def app_add_args(a):
    argv = ["app", "add", a["url_or_name"]]
    if a.get("branch"):
        argv += ["--branch", a["branch"]]
    if a.get("name"):
        argv += ["--name", a["name"]]
    if a.get("site"):
        argv += ["--site", a["site"]]
    if a.get("all_sites"):
        argv += ["--all-sites"]
    return argv + bench_args(a)


# app add from a reviewed plan (0.6.0): the plan is a read tool, applying it
# needs the plan's token, and the CLI refuses a token the bench no longer matches
TOOLS["benchbar_app_add_plan"] = (
    "Plan adding a Frappe app to a bench from a git URL or a known app name, read only: the resolved repo and branch, "
    "whether the repo is readable, the sites, the required apps (from hooks.py) and whether each resolves, the steps, "
    "and a token for benchbar_app_add. Show this plan to the person before applying it.",
    APP_ADD,
    lambda a: app_add_args(a) + ["--dry-run", "--json"],
    True,
    (0,),
)
TOOLS["benchbar_app_add"] = (
    "Apply a plan from benchbar_app_add_plan: clone the app and its planned required apps, build, install on the planned "
    "sites. Only call this after showing that plan to the person and getting their OK; pass the same arguments and the "
    "plan's token. A stale token (apps.txt, apps/ or the sites changed) is refused: plan again. Takes minutes.",
    dict(APP_ADD, token={"type": "string", "description": "The token of the plan the person approved."}),
    lambda a: app_add_args(a) + ["--apply", a["token"], "--yes", "--json"],
    False,
    (0,),
)
REQUIRED = {"benchbar_profile_check": ["name"], "benchbar_app_add_plan": ["url_or_name"], "benchbar_app_add": ["url_or_name", "token"]}
# seconds per call; get-app, pip, yarn and a build take long on a slow network.
# BENCHBAR_MCP_TIMEOUT overrides every one of them (the tests use seconds).
TIMEOUTS = {"benchbar_app_add_plan": 300, "benchbar_app_add": 3600}
# after SIGTERM to the group, how long the CLI gets to run its EXIT trap
# (the setup Redis goes, the lock is released) before SIGKILL
try:
    KILL_GRACE = float(os.environ.get("BENCHBAR_MCP_KILL_GRACE", "10"))
except ValueError:
    KILL_GRACE = 10.0


def tool_timeout(name):
    env = os.environ.get("BENCHBAR_MCP_TIMEOUT")
    if env:
        try:
            return float(env)
        except ValueError:
            pass
    return TIMEOUTS.get(name, 180)
# what an action returns after its output: the fresh status, or the app list
AFTER = {"benchbar_app_add": ("apps", lambda a: ["app", "list", "--json"] + bench_args(a))}


def bench_args(arguments):
    bench = arguments.get("bench")
    return ["--bench-dir", bench] if bench else []


def known_bench_paths():
    """The real paths of the benches `benchbar list --json` knows, or None when the list could not be read."""
    try:
        code, out, _err = run_cli(["list", "--json"], timeout=60)
    except (subprocess.TimeoutExpired, OSError):
        return None
    if code != 0:
        return None
    try:
        benches = json.loads(out).get("benches") or []
    except ValueError:
        return None
    return set(os.path.realpath(b["path"]) for b in benches if isinstance(b, dict) and b.get("path"))


def unknown_bench_error(arguments):
    """For a tool that changes a bench: an error result when its bench argument is not a bench benchbar
    knows (registered, remembered or with an agent). Any other folder is not this server's to stop, start or
    write into. None when the argument is fine or absent (the default bench)."""
    bench = arguments.get("bench")
    if not bench:
        return None
    known = known_bench_paths()
    if known is None:
        return text_result("could not read the bench list (benchbar list --json); not touching %s" % bench, is_error=True)
    if os.path.realpath(bench) not in known:
        return text_result("%s is not a bench benchbar knows (see benchbar_list); nothing was changed. "
                           "Register it first in a terminal: benchbar register %s" % (bench, bench), is_error=True)
    return None


def run_cli(argv, timeout=180):
    env = dict(os.environ, NO_COLOR="1", TERM="dumb")
    # The CLI leads its own process group (start_new_session): a timeout then
    # reaches bench, pip, yarn, git and the setup Redis as well, not only
    # benchbar. SIGTERM first, so the CLI's EXIT trap runs (the setup Redis
    # stops, the lock is released), SIGKILL to the group after the grace.
    # stdin is closed: a question from the CLI is answered "no", never hangs
    p = subprocess.Popen([BENCHBAR] + argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env, start_new_session=True)
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        kill_group(p)
        raise
    return p.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")


def kill_group(p):
    """SIGTERM to the CLI's process group, a grace period, then SIGKILL; the pipes are drained either way."""
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except OSError:
        pass
    try:
        p.communicate(timeout=KILL_GRACE)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            p.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            pass
    # stragglers of the group that re-parented but kept the group id
    deadline = time.time() + 2
    while time.time() < deadline:
        try:
            os.killpg(p.pid, 0)
        except OSError:
            return
        time.sleep(0.1)
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except OSError:
        pass


def tool_list():
    tools = []
    for name, (description, props, _argv, read_only, _codes) in TOOLS.items():
        schema = {"type": "object", "properties": props, "additionalProperties": False}
        if name in REQUIRED:
            schema["required"] = REQUIRED[name]
        tools.append({
            "name": name,
            "description": description,
            "inputSchema": schema,
            "annotations": {"readOnlyHint": read_only, "destructiveHint": False, "openWorldHint": False},
        })
    return {"tools": tools}


def tool_call(params):
    name = params.get("name")
    arguments = params.get("arguments") or {}
    if not isinstance(arguments, dict):
        raise RpcError(-32602, "arguments must be an object")
    if name not in TOOLS:
        raise RpcError(-32602, "unknown tool: %s" % name)
    _description, props, build, read_only, codes = TOOLS[name]
    unknown = [k for k in arguments if k not in props]
    if unknown:
        raise RpcError(-32602, "unknown argument(s) for %s: %s" % (name, ", ".join(unknown)))
    missing = [k for k in REQUIRED.get(name, []) if not arguments.get(k)]
    if missing:
        raise RpcError(-32602, "missing argument(s) for %s: %s" % (name, ", ".join(missing)))
    # a value is never an option: "--yes" as a URL must not reach the CLI's parser
    if any(isinstance(v, str) and v.startswith("-") for v in arguments.values()):
        raise RpcError(-32602, "argument values must not start with '-'")
    if not read_only:
        refused = unknown_bench_error(arguments)
        if refused is not None:
            return refused
    try:
        code, out, err = run_cli(build(arguments), timeout=tool_timeout(name))
    except subprocess.TimeoutExpired:
        return text_result("benchbar did not answer in time (%ss); it and everything it started were stopped" % tool_timeout(name), is_error=True)
    except OSError as e:
        return text_result("could not run benchbar (%s): %s" % (BENCHBAR, e), is_error=True)
    if read_only:
        if code in codes and out.strip().startswith("{"):
            try:
                data = json.loads(out)
            except ValueError:
                return text_result(out + err, is_error=True)
            result = text_result(out.strip())
            result["structuredContent"] = data
            return result
        return text_result((err or out).strip() or "benchbar exited with %d" % code, is_error=True)
    # actions print text; the fresh status follows, so the agent sees the outcome
    key, after = AFTER.get(name, ("status", lambda a: ["status", "--json"] + bench_args(a)))
    status_code, status_out, _ = run_cli(after(arguments))
    summary = {"exit_code": code, "output": (out + err).strip()}
    if out.strip().startswith("{"):
        try:  # an action run with --json: its result, and the text from stderr
            summary["result"] = json.loads(out)
            summary["output"] = err.strip()
        except ValueError:
            pass
    if status_code == 0:
        try:
            summary[key] = json.loads(status_out)
        except ValueError:
            pass
    result = text_result(json.dumps(summary))
    result["structuredContent"] = summary
    result["isError"] = code != 0
    return result


def text_result(text, is_error=False):
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


class RpcError(Exception):
    def __init__(self, code, message):
        Exception.__init__(self, message)
        self.code = code
        self.message = message


def handle(msg):
    method = msg.get("method")
    params = msg.get("params") or {}
    if not isinstance(params, dict):
        raise RpcError(-32602, "params must be an object")
    if method == "initialize":
        asked = params.get("protocolVersion")
        return {
            "protocolVersion": asked if asked in PROTOCOLS else PROTOCOLS[0],
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": SERVER,
            "instructions": "Local Frappe benches managed by benchbar. Read tools are safe to call any time; "
                            "benchbar_up, benchbar_down and benchbar_restart change a bench. To add an app, call "
                            "benchbar_app_add_plan, show the plan to the person, and only after their OK call "
                            "benchbar_app_add with its token. Repairs and bench installs are not offered: suggest "
                            "the fix command doctor prints to the user instead.",
        }
    if method == "ping":
        return {}
    if method == "tools/list":
        return tool_list()
    if method == "tools/call":
        return tool_call(params)
    raise RpcError(-32601, "method not found: %s" % method)


def main():
    out = sys.stdout
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            out.write(json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}}) + "\n")
            out.flush()
            continue
        if not isinstance(msg, dict):
            # valid JSON that is not a request object ("5", a list): answer, keep going
            out.write(json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "invalid request"}}) + "\n")
            out.flush()
            continue
        if "id" not in msg:
            continue  # a notification (notifications/initialized, cancelled): nothing to answer
        try:
            reply = {"jsonrpc": "2.0", "id": msg["id"], "result": handle(msg)}
        except RpcError as e:
            reply = {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": e.code, "message": e.message}}
        except Exception as e:  # never let one bad call end the session
            reply = {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32603, "message": str(e)}}
        out.write(json.dumps(reply) + "\n")
        out.flush()


if __name__ == "__main__":
    main()
