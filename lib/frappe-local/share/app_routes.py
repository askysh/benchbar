# The routes of the copy's own app front ends, for the sharing gateway's allowlist.
# Pure (no frappe import), so it is tested without a bench; signin.py feeds it the hooks.
import re

# A single page app's catch-all rule: /x/<path:app_path> served by the www page x
# (exponent_ecr's /engineering-change, crm, insights). Portal rules such as
# /rfq/<path:name> or /orders are not front ends and stay out.
SPA_RULE = re.compile(r"^/([a-z0-9][a-z0-9-]*)/<path:app_path>$")


def app_routes(apps_screen, website_route_rules):
    routes = []

    def add(route):
        if isinstance(route, str) and route not in routes:
            routes.append(route)

    for entry in apps_screen or []:
        if isinstance(entry, dict):
            add(entry.get("route"))
    for rule in website_route_rules or []:
        if not isinstance(rule, dict):
            continue
        match = SPA_RULE.match(str(rule.get("from_route", "")))
        if match and str(rule.get("to_route", "")).strip("/") == match.group(1):
            add("/" + match.group(1))
    return routes
