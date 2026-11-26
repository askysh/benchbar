#!/usr/bin/env python3
"""docs-links: every docs address in the code and the apps names a page and a heading that exist.

The CLI (`benchbar docs`, the notices, the doctor fix lines), the Mac app, the
tray, the installers and the README link to pages of the docs site, some with an
anchor. A page that is split or renamed must not break one of them (#169). This
script finds those addresses and checks each one against the markdown of the site:
the page (docs/<path>.md, or ROADMAP.md and CONTRIBUTING.md at the root) and the
anchor (a heading of the page, or an entry of site/public/moved/*.js, which sends a
reader of an old address to the page that has the heading now).

    python3 -I scripts/docs-links.py --check [ROOT]

Run it with -I. It reads only files and prints one line per problem.
"""
import json
import os
import re
import sys

HOST = r"benchbar\.akashmishra\.com"
SCAN_DIRS = ["lib", "macos", "windows", "scripts", "site/src", "templates", "packaging", "maintainers", "tests"]
SCAN_FILES = ["benchbar", "install.sh", "install.ps1", "AGENTS.md", "README.md", "CONTRIBUTING.md",
              "SECURITY.md", "SUPPORT.md", "ROADMAP.md"]
SKIP_DIRS = {".git", "node_modules", "bin", "obj", ".build", "DerivedData", "dist", ".generated", ".astro"}
SKIP_FILES = {"docs-links.py"}
TEXT_EXT = {".sh", ".swift", ".cs", ".py", ".md", ".ps1", ".mjs", ".js", ".ts", ".astro", ".tmpl", ".txt",
            ".json", ".yml", ".yaml", ".xaml", ".go", ".rb", ".toml", ".css", ".tsv", ""}


def slug(text):
    """The anchor GitHub's slugger (the one Starlight uses) makes from a heading."""
    text = re.sub(r"`", "", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = text.strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def headings(path):
    """The set of anchors of a markdown page."""
    seen, out, fence = {}, set(), False
    with open(path, encoding="utf-8", newline="") as f:
        for line in f.read().split("\n"):
            if line.startswith("```"):
                fence = not fence
            if fence:
                continue
            m = re.match(r"^#{1,6} (.*?)\s*$", line)
            if m:
                s = slug(m.group(1))
                n = seen.get(s, 0)
                seen[s] = n + 1
                out.add(s if n == 0 else f"{s}-{n}")
            for i in re.findall(r'<a [^>]*\bid="([^"]+)"', line):
                out.add(i)
    return out


def pages(root):
    """URL path -> markdown file, for every page of the site."""
    out = {}
    docs = os.path.join(root, "docs")
    for base, _, files in os.walk(docs):
        for name in files:
            if not name.endswith(".md") or (base == docs and name == "README.md"):
                continue
            full = os.path.join(base, name)
            rel = os.path.relpath(full, docs).replace(os.sep, "/")[:-3].lower()
            if rel == "index":
                url = "/"
            elif rel.endswith("/index"):
                url = "/" + rel[: -len("index")]
            else:
                url = "/" + rel + "/"
            out[url] = full
    for name, url in (("ROADMAP.md", "/roadmap/"), ("CONTRIBUTING.md", "/contributing/")):
        if os.path.exists(os.path.join(root, name)):
            out[url] = os.path.join(root, name)
    return out


def redirects(root):
    """Paths the site config redirects away (to GitHub): a link to one is not a docs page."""
    cfg = os.path.join(root, "site", "astro.config.mjs")
    if not os.path.exists(cfg):
        return set()
    text = open(cfg, encoding="utf-8").read()
    block = re.search(r"redirects:\s*\{(.*?)\}", text, re.S)
    return {m + "/" for m in re.findall(r"'(/[^']*)'\s*:", block.group(1))} if block else set()


def moved(root):
    """Old path -> {anchor: new path}, from site/public/moved/*.js."""
    out = {}
    folder = os.path.join(root, "site", "public", "moved")
    if not os.path.isdir(folder):
        return out
    for name in sorted(os.listdir(folder)):
        text = open(os.path.join(folder, name), encoding="utf-8").read()
        m = re.search(r"Object\.assign\(window\.MOVED_ANCHORS \|\| \{\}, (\{.*\})\);", text, re.S)
        if not m:
            raise SystemExit(f"docs-links: site/public/moved/{name} does not set window.MOVED_ANCHORS in the known form")
        for page, anchors in json.loads(m.group(1)).items():
            out.setdefault(page, {}).update(anchors)
    return out


def scan_files(root):
    for name in SCAN_FILES:
        if os.path.isfile(os.path.join(root, name)):
            yield name
    for d in SCAN_DIRS:
        for base, dirs, files in os.walk(os.path.join(root, d)):
            dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
            for name in files:
                if name in SKIP_FILES or os.path.splitext(name)[1] not in TEXT_EXT:
                    continue
                yield os.path.relpath(os.path.join(base, name), root).replace(os.sep, "/")


def links_in(rel, text):
    """(line number, path, anchor or None) for each docs address in a file."""
    found = []
    for n, line in enumerate(text.split("\n"), 1):
        for m in re.finditer(HOST + r"((?:/[A-Za-z0-9_.\-]+)*/?)(?:#([A-Za-z0-9_\-%]+))?", line):
            found.append((n, m.group(1) or "/", m.group(2)))
        for m in re.finditer(r'fl_docs_url "?(/[A-Za-z0-9_\-/]*)(?:#([A-Za-z0-9_\-]+))?', line):
            found.append((n, m.group(1), m.group(2)))
        for m in re.finditer(r'\$\{DOCS\}(/[A-Za-z0-9_\-/]*)(?:#([A-Za-z0-9_\-]+))?', line):
            found.append((n, m.group(1), m.group(2)))
        if rel == "macos/BenchBar/System/Links.swift":
            for m in re.finditer(r'docs\.appending\(path: "([^"]+)"\)', line):
                found.append((n, "/" + m.group(1), None))
        if rel == "lib/frappe-local/docs.sh":
            m = re.match(r"^(?:FL_DOCS_TOPICS=\")?[a-z][a-z,\-]*\|(/[^|]*)\|", line)
            if m:
                found.append((n, m.group(1), None))
        if rel == "lib/frappe-local/notices.sh":
            m = re.match(r"^notice~.*~(/[^~]*)$", line)
            if m:
                path, _, frag = m.group(1).partition("#")
                found.append((n, path, frag or None))
    out = []
    for n, path, frag in found:
        if re.search(r"\.[a-z0-9]+$", path):
            continue  # a file of the site (og.png), not a page
        out.append((n, path if path.endswith("/") else path + "/", frag))
    return out


def check_ids(root):
    """Every doctor check id, and the page each app and the CLI send an id to."""
    checks = open(os.path.join(root, "lib/frappe-local/checks.sh"), encoding="utf-8").read()
    ids = re.search(r'^FL_CHECK_ORDER="(.*)"$', checks, re.M).group(1).split() + ["port_block"]
    targets = []
    docs_sh = open(os.path.join(root, "lib/frappe-local/docs.sh"), encoding="utf-8").read()
    m = re.search(r'fl_docs_check_url\(\) \{ fl_docs_url "(/[^"#]*)#\$1"', docs_sh)
    if m:
        targets.append(("lib/frappe-local/docs.sh", m.group(1)))
    links = os.path.join(root, "macos/BenchBar/System/Links.swift")
    if os.path.exists(links):
        text = open(links, encoding="utf-8").read()
        m = re.search(r"func doctorCheck\(.*?appending\(path: \"([^\"]+)\"\)", text, re.S)
        if m:
            targets.append(("macos/BenchBar/System/Links.swift", "/" + m.group(1)))
    return ids, targets


def main(root):
    site = pages(root)
    redirected = redirects(root)
    moves = moved(root)
    anchors = {}
    problems = []

    def anchors_of(url):
        if url not in anchors:
            anchors[url] = headings(site[url])
        return anchors[url]

    def resolve(path, frag):
        """None when the address works, else the reason."""
        if path in redirected:
            return None
        if path not in site:
            return f"the page {path} does not exist"
        if frag is None or frag in anchors_of(path):
            return None
        target = moves.get(path, {}).get(frag)
        if target is None:
            return f"the page {path} has no heading #{frag}"
        if target not in site or frag not in anchors_of(target):
            return f"{path}#{frag} is sent to {target}, which has no heading #{frag}"
        return None

    count = 0
    for rel in scan_files(root):
        try:
            text = open(os.path.join(root, rel), encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for n, path, frag in links_in(rel, text):
            count += 1
            why = resolve(path, frag)
            if why:
                problems.append(f"{rel}:{n}: {why}")

    ids, targets = check_ids(root)
    for rel, path in targets:
        for cid in ids:
            count += 1
            why = resolve(path, cid)
            if why:
                problems.append(f"{rel}: the link of the doctor check {cid}: {why}")

    # an entry of a moved map must be an anchor the old page has no heading for, or the redirect never runs
    for old, entries in moves.items():
        for frag, target in entries.items():
            count += 1
            if old not in site:
                problems.append(f"site/public/moved: {old} is not a page")
            elif target not in site or frag not in anchors_of(target):
                problems.append(f"site/public/moved: {old}#{frag} is sent to {target}, which has no heading #{frag}")

    for p in problems:
        print(f"docs-links: {p}")
    if problems:
        print(f"docs-links: {len(problems)} broken of {count} addresses. Fix the link, or keep the old anchor working in site/public/moved/")
        return 1
    print(f"docs-links: ok ({count} addresses)")
    return 0


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--check"]
    sys.exit(main(os.path.abspath(args[0]) if args else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
