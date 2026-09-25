#!/usr/bin/env python3
"""benchbar mcp: a Model Context Protocol server over stdio.

Coding agents (Claude Code, Cursor, ...) can list benches, read status,
doctor and log tails, and start, stop or restart a bench. Every tool runs
`benchbar ... --json` and hands back what the CLI printed: no logic about
benches lives here, so the CLI stays the only thing that touches a bench.
Nothing that repairs, installs or needs sudo is offered.

Standard library only, Python 3.9 or newer (the Command Line Tools' python3).
Messages are JSON-RPC 2.0, one per line on stdin and stdout; stderr is for
humans.
"""

import json
import os
import subprocess
import sys

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


def bench_args(arguments):
    bench = arguments.get("bench")
    return ["--bench-dir", bench] if bench else []


def run_cli(argv, timeout=180):
    env = dict(os.environ, NO_COLOR="1", TERM="dumb")
    # stdin is closed: a question from the CLI is answered "no", never hangs
    p = subprocess.run([BENCHBAR] + argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, env=env, timeout=timeout)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


def tool_list():
    tools = []
    for name, (description, props, _argv, read_only, _codes) in TOOLS.items():
        tools.append({
            "name": name,
            "description": description,
            "inputSchema": {"type": "object", "properties": props, "additionalProperties": False},
            "annotations": {"readOnlyHint": read_only, "destructiveHint": False, "openWorldHint": False},
        })
    return {"tools": tools}


def tool_call(params):
    name = params.get("name")
    arguments = params.get("arguments") or {}
    if name not in TOOLS:
        raise RpcError(-32602, "unknown tool: %s" % name)
    _description, props, build, read_only, codes = TOOLS[name]
    unknown = [k for k in arguments if k not in props]
    if unknown:
        raise RpcError(-32602, "unknown argument(s) for %s: %s" % (name, ", ".join(unknown)))
    try:
        code, out, err = run_cli(build(arguments))
    except subprocess.TimeoutExpired:
        return text_result("benchbar did not answer in time", is_error=True)
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
    status_code, status_out, _ = run_cli(["status", "--json"] + bench_args(arguments))
    summary = {"exit_code": code, "output": (out + err).strip()}
    if status_code == 0:
        try:
            summary["status"] = json.loads(status_out)
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
    if method == "initialize":
        asked = params.get("protocolVersion")
        return {
            "protocolVersion": asked if asked in PROTOCOLS else PROTOCOLS[0],
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": SERVER,
            "instructions": "Local Frappe benches managed by benchbar. Read tools are safe to call any time; "
                            "benchbar_up, benchbar_down and benchbar_restart change a bench. Repairs and installs "
                            "are not offered: suggest the fix command doctor prints to the user instead.",
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
