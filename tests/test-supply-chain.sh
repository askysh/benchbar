#!/usr/bin/env bash
# What the build trusts is pinned, and the pins say the same everywhere
# (docs/DECISIONS.md, "Supply chain"): every action is a commit sha with its
# version in a comment, every job has a timeout, Dependabot watches each
# package manager and targets next-release, the Swift packages of the app are
# the ones macos/Package.resolved names (and Package.swift, project.yml and
# sparkle.yml agree), the build tools of the CI come with a sha256, the Go of
# the shim is a supported release, the NuGet packages of the tray are locked
# (packages.lock.json, restored with RestoreLockedMode), and the third party
# installers of the Linux install carry a version and a sha256.
# shellcheck disable=SC2016  # the patterns hold literal $ on purpose
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---- workflows and actions: every `uses:` is a sha with a version comment; every job has a timeout
set +e
OUT="$(python3 -I - "$ROOT" <<'PY' 2>&1
import glob, re, sys

root = sys.argv[1]
bad = []
files = sorted(glob.glob(root + "/.github/workflows/*.yml")) + sorted(glob.glob(root + "/.github/actions/*/action.yml"))
for path in files:
    name = path[len(root) + 1:]
    lines = open(path).read().split("\n")
    for n, line in enumerate(lines, 1):
        m = re.match(r"^\s*(?:- )?uses:\s*(\S+)(.*)$", line)
        if not m:
            continue
        ref, rest = m.group(1), m.group(2)
        if ref.startswith("./"):
            continue
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}", ref):
            bad.append(f"{name}:{n}: {ref} is not pinned to a full commit sha")
        elif not re.fullmatch(r"\s+#\s+v\d+(\.\d+)*\s*", rest):
            bad.append(f"{name}:{n}: {ref} has no '# vX.Y.Z' comment after it")
    if "/workflows/" in path:
        in_jobs, cur, jobs = False, None, {}
        for line in lines:
            if re.match(r"^jobs:\s*$", line):
                in_jobs = True
                continue
            if in_jobs and re.match(r"^\S", line) and line.strip() and not line.startswith("#"):
                in_jobs = False
            m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
            if in_jobs and m:
                cur = m.group(1)
                jobs[cur] = []
            elif in_jobs and cur:
                jobs[cur].append(line)
        for job, body in jobs.items():
            if not any(re.match(r"^    timeout-minutes:\s*\S", b) for b in body):
                bad.append(f"{name}: job {job} has no timeout-minutes (the default is six hours)")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
)"
CODE=$?
set -e
assert_eq 0 "$CODE" "(actions pinned by sha, jobs with a timeout)"$'\n'"$OUT"

# no tool that floats: Homebrew formulas of the build, latest Xcode, a tag only for the CI image
for f in "$ROOT"/.github/workflows/*.yml "$ROOT"/.github/actions/*/action.yml; do
  body="$(grep -v '^[[:space:]]*#' "$f")"
  case "$f" in
    */homebrew-formula.yml | */homebrew-tap.yml) ;;   # they test brew itself
    *) assert_not_contains "$body" "brew install" ;;
  esac
  assert_not_contains "$body" "latest-stable"
done
assert_contains "$(cat "$ROOT/.github/workflows/ci.yml")" "bash:3.2.57@sha256:"

# ---- dependabot: one entry per package manager, all on next-release, all with a cooldown
set +e
OUT="$(python3 -I - "$ROOT" <<'PY' 2>&1
import re, sys

text = open(sys.argv[1] + "/.github/dependabot.yml").read()
entries = re.split(r"\n  - package-ecosystem: ", "\n" + text.split("\nupdates:\n", 1)[1])[1:]
found = {}
bad = []
for e in entries:
    eco = e.split("\n", 1)[0].strip()
    dirs = re.findall(r"^\s+directory:\s*(\S+)", e, re.M) + re.findall(r"^\s+-\s+(/\S*)", e, re.M)
    found[eco] = dirs
    if not re.search(r"^    target-branch: next-release$", e, re.M):
        bad.append(f"{eco}: no target-branch next-release")
    if not re.search(r"^    cooldown:\n      default-days: [1-9]", e, re.M):
        bad.append(f"{eco}: no cooldown")
want = {"github-actions": "/", "gomod": "/windows/shim", "nuget": "/windows/tray", "dotnet-sdk": "/windows/tray",
        "swift": "/macos", "bun": "/site"}
for eco, d in want.items():
    if d not in found.get(eco, []):
        bad.append(f"{eco} does not watch {d}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
)"
CODE=$?
set -e
assert_eq 0 "$CODE" "(dependabot)"$'\n'"$OUT"
for dir in windows/shim windows/tray macos site; do
  [[ -d "$ROOT/$dir" ]] || fail "dependabot.yml watches $dir, which does not exist"
done

# ---- Swift packages: project.yml, sparkle.yml, Package.swift and Package.resolved agree
set +e
OUT="$(python3 -I - "$ROOT" <<'PY' 2>&1
import json, re, sys

root = sys.argv[1] + "/macos/"
bad = []

def specs(path):
    # "  Name:\n    url: ...\n    from: "x"" under a top level packages: key
    text = open(root + path).read()
    block = re.search(r"^packages:\n((?:[ ]+.*\n|\n)+)", text, re.M)
    out = {}
    if block:
        for m in re.finditer(r"^  (\w+):\n    url: (\S+)\n    from: \"([^\"]+)\"", block.group(1), re.M):
            out[m.group(1)] = (m.group(2), m.group(3))
    return out

want = {}
want.update(specs("project.yml"))
want.update(specs("sparkle.yml"))
if set(want) != {"Subprocess", "Sparkle"}:
    bad.append(f"project.yml and sparkle.yml declare {sorted(want)}, expected Subprocess and Sparkle")

manifest = open(root + "Package.swift").read()
declared = dict(re.findall(r'\.package\(url: "([^"]+)", from: "([^"]+)"\)', manifest))
for name, (url, ver) in want.items():
    if declared.get(url) != ver:
        bad.append(f"{name}: project.yml/sparkle.yml say {url} from {ver}; Package.swift says {declared.get(url)}")
if len(declared) != len(want):
    bad.append(f"Package.swift declares {len(declared)} packages, the specs {len(want)}")

pins = {p["location"]: p["state"] for p in json.load(open(root + "Package.resolved"))["pins"]}
def key(v):
    return tuple(int(x) for x in v.split("."))
for name, (url, ver) in want.items():
    st = pins.get(url)
    if not st:
        bad.append(f"{name}: no pin for {url} in Package.resolved")
        continue
    got = st.get("version", "")
    if not (key(got) >= key(ver) and key(got)[0] == key(ver)[0]):
        bad.append(f"{name}: Package.resolved has {got}, which is outside 'from {ver}' (same major, not older)")
    if not re.fullmatch(r"[0-9a-f]{40}", st.get("revision", "")):
        bad.append(f"{name}: the pin has no revision")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
)"
CODE=$?
set -e
assert_eq 0 "$CODE" "(Swift package pins)"$'\n'"$OUT"
# the build scripts install that file and build without resolving again
BUILD="$(cat "$ROOT/scripts/macos-build.sh")"
assert_contains "$BUILD" 'scripts/macos-packages.sh" "$DERIVED"'
assert_contains "$BUILD" 'scripts/macos-packages.sh" --check'
assert_contains "$BUILD" "-disableAutomaticPackageResolution"
assert_contains "$(cat "$ROOT/.github/workflows/snapshots.yml")" "scripts/macos-packages.sh"
assert_contains "$(cat "$ROOT/.github/workflows/snapshots.yml")" "-disableAutomaticPackageResolution"
assert_contains "$(cat "$ROOT/.github/workflows/ci.yml")" "-disableAutomaticPackageResolution"
assert_contains "$(cat "$ROOT/macos/Package.swift")" "swift-tools-version"

# ---- the build tools of the CI: a version and a 64 digit sha256 for every archive
TOOLS="$(cat "$ROOT/scripts/ci-install-tool.sh")"
assert_eq "shellcheck 0.11.0
xcodegen 2.47.0
actionlint 1.7.12
zizmor 1.32.0" "$(bash "$ROOT/scripts/ci-install-tool.sh" --list)" "(the pinned tools; update this list with the script)"
sums="$(grep -oE 'SUM=[0-9a-f]+' <<<"$TOOLS" | cut -d= -f2)"
assert_eq "13" "$(grep -c . <<<"$sums")" "(one sum per tool and platform: shellcheck 4, xcodegen 1, actionlint 4, zizmor 4)"
while IFS= read -r s; do
  [[ "${#s}" == "64" ]] || fail "a pinned sha256 in ci-install-tool.sh is ${#s} digits: $s"
done <<<"$sums"
assert_contains "$TOOLS" '[ "$got" = "$SUM" ] || die'
assert_not_contains "$(grep -v '^[[:space:]]*#' <<<"$TOOLS")" "latest"
# the workflows install them through the script, so the sums are the only source
assert_contains "$(cat "$ROOT/.github/workflows/ci.yml")" "scripts/ci-install-tool.sh actionlint"
assert_contains "$(cat "$ROOT/.github/workflows/ci.yml")" "scripts/ci-install-tool.sh zizmor"
assert_contains "$(cat "$ROOT/.github/actions/release-prepare/action.yml")" "scripts/ci-install-tool.sh xcodegen"
assert_contains "$(cat "$ROOT/.github/actions/release-prepare/action.yml")" "xcode-version: '26.6'"

# ---- the Go of the shim is a supported release (the two newest are: update this floor when Go ends one)
go_ver="$(sed -n 's/^go \([0-9][0-9.]*\)$/\1/p' "$ROOT/windows/shim/go.mod")"
[[ -n "$go_ver" ]] || fail "windows/shim/go.mod has no go line"
go_minor="$(cut -d. -f2 <<<"$go_ver")"
[[ "$(cut -d. -f1 <<<"$go_ver")" == "1" && "$go_minor" -ge 26 ]] || fail "windows/shim/go.mod says go ${go_ver}: Go 1.25 and older no longer get security fixes"
assert_contains "$(cat "$ROOT/.github/workflows/ci.yml")" "govulncheck"

# ---- the installers of the Linux install: a version in the URL, a 64 digit sha256, the same uv everywhere
LINUX="$(cat "$ROOT/00-linux-system-deps.sh")"
uv_ver="$(sed -n 's/^UV_VERSION=\(.*\)$/\1/p' <<<"$LINUX")"
fnm_ver="$(sed -n 's/^FNM_VERSION=\(.*\)$/\1/p' <<<"$LINUX")"
[[ -n "$uv_ver" && -n "$fnm_ver" ]] || fail "00-linux-system-deps.sh has no UV_VERSION or FNM_VERSION"
assert_contains "$LINUX" 'UV_INSTALLER_URL="${UV_INSTALLER_URL:-https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-installer.sh}"'
assert_contains "$LINUX" 'FNM_INSTALLER_URL="${FNM_INSTALLER_URL:-https://raw.githubusercontent.com/Schniz/fnm/v${FNM_VERSION}/.ci/install.sh}"'
for var in UV_INSTALLER_SHA256 FNM_INSTALLER_SHA256; do
  sum="$(sed -n "s/^${var}=\"\${${var}:-\([0-9a-f]*\)}\"\$/\1/p" <<<"$LINUX")"
  [[ "${#sum}" == "64" ]] || fail "$var in 00-linux-system-deps.sh is not a pinned 64 digit sha256 (got '${sum}')"
done
assert_not_contains "$LINUX" "astral.sh/uv/install.sh"
assert_not_contains "$LINUX" "fnm.vercel.app"
assert_contains "$(cat "$ROOT/lib/frappe-local/bench.sh")" "astral.sh/uv/${uv_ver}/install.sh"

# ---- NuGet packages of the tray: a lock file per project, and every CI restore is locked (OPS-7)
props="$(cat "$ROOT/windows/tray/Directory.Build.props")"
assert_contains "$props" "<RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>"
for proj in "$ROOT"/windows/tray/*/*.csproj; do
  [[ -f "$(dirname "$proj")/packages.lock.json" ]] || fail "${proj#"$ROOT"/} has no packages.lock.json next to it (cd windows/tray && dotnet restore --force-evaluate, then commit it)"
done
for lock in "$ROOT"/windows/tray/*/packages.lock.json; do
  assert_contains "$(cat "$lock")" '"version": 2' "(${lock#"$ROOT"/} is a NuGet lock file)"
  assert_contains "$(cat "$lock")" "win-arm64" "(${lock#"$ROOT"/} covers the arm64 build)"
done
# a restore that is not locked (-p:RestoreLockedMode=true, or dotnet restore --locked-mode) would take a version that changed since the lock file was written
set +e
OUT="$(python3 -I - "$ROOT" <<'PY' 2>&1
import glob, re, sys

root = sys.argv[1]
bad = []
files = sorted(glob.glob(root + "/.github/workflows/*.yml")) + sorted(glob.glob(root + "/.github/actions/*/action.yml"))
for path in files:
    for n, line in enumerate(open(path).read().split("\n"), 1):
        code = line.strip()
        m = re.match(r"^(?:-\s+)?(?:run:\s+)?dotnet (restore|build|test|publish|pack)\b(.*)$", code)
        if not m:
            continue
        # --no-restore and --no-build leave the restore to an earlier command that is checked on its own
        if m.group(1) != "restore" and "--no-restore" in m.group(2):
            continue
        if m.group(1) == "test" and "--no-build" in m.group(2):
            continue
        if "--locked-mode" not in m.group(2) and "-p:RestoreLockedMode=true" not in m.group(2):
            bad.append(f"{path[len(root) + 1:]}:{n}: {code} restores without -p:RestoreLockedMode=true")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
)"
CODE=$?
set -e
assert_eq 0 "$CODE" "(every dotnet restore in CI is locked)"$'\n'"$OUT"

printf 'test-supply-chain: ok\n'
