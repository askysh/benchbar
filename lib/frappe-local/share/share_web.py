#!/usr/bin/env python3
# The web process of a share: the hardened copy, served to the gateway only.
# The share runner starts it from <bench>/sites as
#
#   env -u DEV_SERVER CI=1 <bench>/env/bin/python share_web.py --site SITE --port P
#
# It listens on 127.0.0.1 alone and runs Werkzeug without its debugger, evalex
# or reloader, whatever frappe.app.serve asks for: frappe binds 0.0.0.0 and
# turns the debugger on unless CI is set (frappe/app.py, serve). serve imports
# run_simple inside the function, so the replacement is put on
# werkzeug.serving before frappe.app is imported (spike S1); a frappe that
# imports it when the module loads gets the replacement too.
import argparse
import os
import sys

sys.dont_write_bytecode = True


def main(argv):
    parser = argparse.ArgumentParser(prog="share_web.py")
    parser.add_argument("--site", required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args(argv)

    os.environ["CI"] = "1"
    os.environ.pop("DEV_SERVER", None)

    import werkzeug.serving

    real_run_simple = werkzeug.serving.run_simple

    def loopback_run_simple(hostname, port, application, **kwargs):
        kwargs.update(use_debugger=False, use_evalex=False, use_reloader=False)
        return real_run_simple("127.0.0.1", port, application, **kwargs)

    werkzeug.serving.run_simple = loopback_run_simple

    import frappe.app

    frappe.app.serve(port=args.port, site=args.site, sites_path=".", no_reload=True)


if __name__ == "__main__":
    main(sys.argv[1:])
