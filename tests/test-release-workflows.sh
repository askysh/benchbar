#!/usr/bin/env bash
# The release keys are guarded (docs/releasing.md, "Secrets"): every job that
# reads one of the ten release secrets declares `environment: release`, and
# no other job does, so a pull request or a branch run never reaches the
# environment; the composite actions read no secret; the signed build
# checks out without a token, imports the certificate for codesign only (no
# -A), removes the keychain and keys in an always() step before the draft
# step, and a tag build with a missing secret fails instead of going ad hoc;
# macos-release.sh keeps the notary and Sparkle keys out of the environment
# of the build; no workflow replaces a published release's files (no
# --clobber), the tap workflow never merges its own pull request, and an
# ad hoc run is refused on a release tag.
# shellcheck disable=SC2016  # the patterns hold literal $ on purpose
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

WF="$ROOT/.github/workflows"
RELEASE="$WF/release.yml"
SCRIPT="$ROOT/scripts/macos-release.sh"

# ---- which job reads a secret, and which declares the environment
set +e
OUT="$(python3 -I - "$ROOT" <<'PY' 2>&1
import glob, re, sys

root = sys.argv[1]
secrets = {"APPLE_TEAM_ID", "MACOS_SIGN_IDENTITY", "MACOS_CERTIFICATE_P12", "MACOS_CERTIFICATE_PASSWORD",
           "NOTARY_API_KEY_P8", "NOTARY_API_KEY_ID", "NOTARY_API_ISSUER_ID", "SPARKLE_ED_PRIVATE_KEY",
           "SPARKLE_ED_PUBLIC_KEY", "HOMEBREW_TAP_TOKEN"}
bad = []
for path in sorted(glob.glob(root + "/.github/workflows/*.yml")):
    jobs, cur, in_jobs = {}, None, False
    for line in open(path):
        if re.match(r"^jobs:\s*$", line):
            in_jobs = True
            continue
        if in_jobs and re.match(r"^\S", line) and line.strip():
            in_jobs = False
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if in_jobs and m:
            cur = m.group(1)
            jobs[cur] = []
        elif in_jobs and cur:
            jobs[cur].append(line)
    for name, lines in jobs.items():
        text = "".join(lines)
        reads = {s for s in secrets if re.search(r"secrets\.%s\b" % s, text)}
        env = re.search(r"^    environment:\s*release\s*$", text, re.M) is not None
        base = path.rsplit("/", 1)[1] + ":" + name
        if reads and not env:
            bad.append("%s reads %s without environment: release" % (base, ",".join(sorted(reads))))
        if env and not reads:
            bad.append("%s declares environment: release but reads no release secret" % base)
for path in glob.glob(root + "/.github/actions/*/action.yml"):
    if re.search(r"secrets\.", open(path).read()):
        bad.append("%s reads a secret: a composite action must take it as an input" % path)
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
)"
CODE=$?
set -e
assert_eq 0 "$CODE" "(secret jobs and the release environment)"$'\n'"$OUT"

# ---- release.yml: tag builds are signed or fail, ad hoc only by input
assert_contains "$(cat "$RELEASE")" "environment: release"
assert_contains "$(cat "$RELEASE")" "refs/tags/v*) ;;"
assert_contains "$(cat "$RELEASE")" "A tag build is never released unsigned"
assert_contains "$(cat "$RELEASE")" "mode == 'adhoc'"
CHECK_JOB="$(awk '/^  check:/{f=1;next} /^  [a-z-]+:$/{f=0} f' "$RELEASE")"
assert_not_contains "$CHECK_JOB" "secrets."
ADHOC_JOB="$(awk '/^  build-adhoc:/{f=1;next} /^  [a-z-]+:$/{f=0} f' "$RELEASE")"
assert_not_contains "$ADHOC_JOB" "secrets."
assert_not_contains "$ADHOC_JOB" "environment:"

SIGNED_JOB="$(awk '/^  build-signed:/{f=1;next} /^  [a-z-]+:$/{f=0} f' "$RELEASE")"
assert_contains "$SIGNED_JOB" "persist-credentials: false"
assert_contains "$SIGNED_JOB" "-T /usr/bin/codesign"
case "$SIGNED_JOB" in *"security import"*" -A "*) fail "the certificate is imported with -A (any program may use the key)" ;; esac
# the cleanup runs always, and before the release is drafted
clean_line="$(grep -n -m 1 'Remove the keychain and keys' <<<"$SIGNED_JOB" | cut -d: -f1)"
draft_line="$(grep -n -m 1 'release-draft' <<<"$SIGNED_JOB" | cut -d: -f1)"
[[ -n "$clean_line" && -n "$draft_line" && "$clean_line" -lt "$draft_line" ]] || fail "the key cleanup step must come before the draft step"
assert_contains "$(printf '%s\n' "$SIGNED_JOB" | sed -n "${clean_line},$((clean_line + 2))p")" "if: always()"

assert_contains "$(cat "$RELEASE")" "never runs on a release tag"
assert_contains "$SIGNED_JOB" "BENCHBAR_KEY_DIR"
assert_contains "$(printf '%s\n' "$SIGNED_JOB" | sed -n "${clean_line},$((clean_line + 6))p")" 'rm -rf "$BENCHBAR_KEY_DIR"'

# ---- no workflow overwrites or merges by itself
for f in "$WF"/*.yml "$ROOT"/.github/actions/*/action.yml; do
  case "$(grep -v '^[[:space:]]*#' "$f")" in
    *--clobber*) fail "$f uses --clobber: a release file is replaced by deleting it first, on a draft only" ;;
  esac
done
TAP="$(grep -v '^[[:space:]]*#' "$WF/homebrew-tap.yml")"
assert_not_contains "$TAP" "gh pr merge"
assert_not_contains "$TAP" "--auto"
assert_contains "$TAP" "persist-credentials: false"

# ---- a published release is refused; only a draft is edited, files deleted first
DRAFT="$(cat "$ROOT/.github/actions/release-draft/action.yml")"
assert_contains "$DRAFT" "--json isDraft"
assert_contains "$DRAFT" '"$view" != "true"'
assert_contains "$DRAFT" "gh release delete-asset"
edit_line="$(grep -n -m 1 'gh release edit' <<<"$DRAFT" | cut -d: -f1)"
gate_line="$(grep -n -m 1 '"$view" != "true"' <<<"$DRAFT" | cut -d: -f1)"
[[ -n "$edit_line" && -n "$gate_line" && "$gate_line" -lt "$edit_line" ]] || fail "release-draft must check the release is a draft before it edits it"
WIN="$(cat "$WF/release-windows.yml")"
assert_contains "$WIN" "gh release delete-asset"
assert_contains "$WIN" "Release already published"
win_gate="$(grep -n -m 1 'Release already published' <<<"$WIN" | cut -d: -f1)"
win_up="$(grep -n -m 1 'gh release upload' <<<"$WIN" | cut -d: -f1)"
[[ -n "$win_gate" && -n "$win_up" && "$win_gate" -lt "$win_up" ]] || fail "release-windows.yml must refuse a published release before it uploads"

# ---- macos-release.sh: content keys never reach the build's environment
assert_contains "$(cat "$SCRIPT")" "unset NOTARY_KEY_BASE64 SPARKLE_ED_KEY"
assert_contains "$(cat "$SCRIPT")" "use_sparkle_key"
assert_contains "$(cat "$SCRIPT")" "drop_notary_key"
assert_contains "$(cat "$SCRIPT")" 'mktemp "${BENCHBAR_KEY_DIR:-${TMPDIR:-/tmp}}/benchbar-notary.XXXXXX"'
assert_contains "$(cat "$SCRIPT")" 'mktemp "${BENCHBAR_KEY_DIR:-${TMPDIR:-/tmp}}/benchbar-sparkle.XXXXXX"'

# ---- release candidates (docs/releasing.md, "Release candidates"): a tag with a
# suffix builds like a release but is a GitHub pre-release, which no updater
# offers and the tap skips; a tag must sit on merged work
assert_contains "$(cat "$RELEASE")" 'prerelease: ${{ steps.version.outputs.prerelease }}'
assert_contains "$SIGNED_JOB" 'prerelease: ${{ needs.check.outputs.prerelease }}'
assert_contains "$SIGNED_JOB" "is not on main"
assert_contains "$SIGNED_JOB" 'git merge-base --is-ancestor "$GITHUB_SHA" origin/main'
assert_contains "$DRAFT" "--prerelease --latest=false"
assert_contains "$DRAFT" '"${flags[@]}"'
assert_contains "$(cat "$ROOT/.github/actions/release-prepare/action.yml")" 'scripts/check-version.sh --folded "$VERSION"'
assert_contains "$WIN" "'--prerelease'"
assert_contains "$TAP" "if: github.event_name != 'release' || !github.event.release.prerelease"
assert_contains "$TAP" "case \"\$v\" in *-rc.*) PRERELEASE=true ;; esac"
# no job that starts the environment for a release candidate: the tap job is skipped before it
tap_if="$(grep -n -m 1 "if: github.event_name != 'release'" <<<"$TAP" | cut -d: -f1)"
tap_env="$(grep -n -m 1 'environment: release' <<<"$TAP" | cut -d: -f1)"
[[ -n "$tap_if" && -n "$tap_env" && "$tap_if" -lt "$tap_env" ]] || fail "the tap job must skip a pre-release (if:) before it asks for the environment"

# ---- a release is a fast forward of main (docs/releasing.md): auto-tag tags main's
# commit, refuses a candidate on main, runs the one version check, and pushes no
# branch (main equals next-release after the fast forward, nothing to catch up)
AUTO="$(grep -v '^[[:space:]]*#' "$WF/auto-tag.yml")"
assert_contains "$AUTO" 'scripts/check-version.sh --folded "$cli"'
assert_contains "$AUTO" 'scripts/check-version.sh --kind "$cli")" != final'
assert_not_contains "$AUTO" "refs/heads/next-release"
assert_not_contains "$AUTO" "repos/\${GITHUB_REPOSITORY}/merges"
if grep -Eq 'git merge( |$)' <<<"$AUTO"; then fail "auto-tag.yml merges"; fi
assert_not_contains "$AUTO" "git push origin \"\$GITHUB_SHA"
assert_not_contains "$AUTO" "--force"
assert_not_contains "$AUTO" "push -f"
# the only push is the tag
assert_eq "1" "$(printf '%s\n' "$AUTO" | grep -c 'git push')"
assert_contains "$AUTO" 'git push origin "refs/tags/v$VERSION"'
# a tagged version with code in the push fails (it was a notice), a docs push stays one
assert_contains "$AUTO" 'scripts/docs-only.sh "$BEFORE" "$GITHUB_SHA"'
assert_contains "$AUTO" "release PR merged without a version bump?"
assert_contains "$AUTO" "::error title=Release without a version bump"
assert_contains "$AUTO" "main is ahead"
bump_line="$(grep -n -m 1 'Release without a version bump' <<<"$AUTO" | cut -d: -f1)"
assert_contains "$(printf '%s\n' "$AUTO" | sed -n "${bump_line},$((bump_line + 1))p")" "exit 1"

# ---- scripts/docs-only.sh uses the rule of CI: the same pattern as ci-plan.sh, and it
# tells docs from code in a real range
ci_re="$(sed -n "s/^docs_paths='\(.*\)'\$/\1/p" "$ROOT/scripts/ci-plan.sh")"
do_re="$(sed -n "s/^DOCS_RE='\(.*\)'\$/\1/p" "$ROOT/scripts/docs-only.sh")"
[[ -n "$ci_re" && "$ci_re" == "$do_re" ]] || fail "docs-only.sh and ci-plan.sh disagree on what is docs: '$do_re' vs '$ci_re'"
D="$TMP_DIR/docsrepo"
(
  PATH="/usr/bin:/bin:$PATH"   # a real git, not the mock of the harness
  git init -q "$D"
  cd "$D"
  g() { git -c user.name=t -c user.email=t@example.com "$@"; }
  mkdir -p docs site lib
  echo a >lib/x.sh; echo a >docs/a.md; echo a >README.md; g add -A; g commit -q -m base
  echo b >docs/a.md; echo b >site/index.html; echo b >CHANGES.md; g add -A; g commit -q -m docs
  echo b >lib/x.sh; echo c >docs/a.md; g add -A; g commit -q -m code
  DOC="$(git rev-parse HEAD~1)" BASE="$(git rev-parse HEAD~2)" CODE="$(git rev-parse HEAD)"
  rc=0; out="$(bash "$ROOT/scripts/docs-only.sh" "$BASE" "$DOC")" || rc=$?
  [[ "$rc" == 0 && -z "$out" ]] || { echo "docs range not accepted: rc=$rc $out" >&2; exit 1; }
  rc=0; out="$(bash "$ROOT/scripts/docs-only.sh" "$BASE" "$CODE")" || rc=$?
  [[ "$rc" == 1 && "$out" == "lib/x.sh" ]] || { echo "code range: rc=$rc out=$out" >&2; exit 1; }
  rc=0; bash "$ROOT/scripts/docs-only.sh" --commit "$DOC" >/dev/null || rc=$?
  [[ "$rc" == 0 ]] || { echo "--commit docs: rc=$rc" >&2; exit 1; }
  rc=0; bash "$ROOT/scripts/docs-only.sh" --commit "$CODE" >/dev/null || rc=$?
  [[ "$rc" == 1 ]] || { echo "--commit code: rc=$rc" >&2; exit 1; }
  rc=0; bash "$ROOT/scripts/docs-only.sh" --commit "$BASE" >/dev/null || rc=$?
  [[ "$rc" == 1 ]] || { echo "--commit root: rc=$rc" >&2; exit 1; }
  rc=0; bash "$ROOT/scripts/docs-only.sh" --commit nosuch >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 2 ]] || { echo "--commit unknown: rc=$rc" >&2; exit 1; }
) || fail "scripts/docs-only.sh"

# ---- build provenance (#134): the Mac files are attested by one job that alone
# has id-token and attestations write, the tap verifies before it renders, and
# the sums carry the installers that self-update runs
set +e
OUT="$(python3 -I - "$ROOT" <<'PY' 2>&1
import re, sys
root = sys.argv[1]
bad = []
rel = open(root + "/.github/workflows/release.yml").read()
m = re.search(r"^  attest:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", rel, re.M | re.S)
rest = rel.replace(m.group(0), "") if m else rel
if not m:
    bad.append("release.yml has no attest job")
else:
    job = m.group(1)
    if not re.search(r"^      id-token: write$", job, re.M) or not re.search(r"^      attestations: write$", job, re.M):
        bad.append("the attest job lacks id-token and attestations write")
    if re.search(r"^    environment:", job, re.M) or re.search(r"secrets\.", job):
        bad.append("the attest job has an environment or reads a secret")
    if not re.search(r"needs:\s*\[check, build-signed\]", job):
        bad.append("the attest job does not wait for build-signed")
    if "needs.check.outputs.mode == 'signed'" not in job:
        bad.append("the attest job is not limited to the signed (tag) path")
    uses = re.findall(r"uses:\s*(\S+)[ \t]*(#.*)?$", job, re.M)
    attest = [u for u in uses if u[0].startswith("actions/attest-build-provenance@")]
    if len(attest) != 1:
        bad.append("expected one attest-build-provenance step, found %d" % len(attest))
    for ref, comment in uses:
        if not re.search(r"@[0-9a-f]{40}$", ref) or not re.match(r"#\s*v\d", comment or ""):
            bad.append("%s is not pinned by commit sha with a version comment" % ref)
    subjects = job.split("subject-path:")[-1]
    for want in (".dmg", ".zip", ".tar.gz", "dist/SHA256SUMS"):
        if want not in subjects:
            bad.append("the attest job does not attest *%s" % want)
if re.search(r"id-token:\s*write", rest):
    bad.append("release.yml: a job other than attest has id-token: write")
tap = open(root + "/.github/workflows/homebrew-tap.yml").read()
v = tap.find("gh attestation verify \"$f\"")
r = tap.find("scripts/homebrew-render.sh")
if v < 0 or r < 0 or v > r:
    bad.append("homebrew-tap.yml does not run gh attestation verify before it renders the formula")
if "askysh/benchbar/.github/workflows/release.yml" not in tap:
    bad.append("homebrew-tap.yml does not pin the signer workflow")
if '-lt 9' not in tap or "files_to_verify" not in tap:
    bad.append("homebrew-tap.yml does not skip the check for a version below 0.9.0")
if "attestations: read" not in tap:
    bad.append("homebrew-tap.yml has no attestations: read permission")
win = open(root + "/.github/workflows/release-windows.yml").read()
if "'{0}  install.ps1'" not in win:
    bad.append("release-windows.yml does not put install.ps1 into the checksums")
if "SHA256SUMS.txt" not in win.split("subject-path:")[1].split("- name:")[0]:
    bad.append("release-windows.yml does not attest the checksums file")
for f in ("scripts/macos-release.sh", "scripts/release-local.sh"):
    if "shasum -a 256 install.sh install.ps1)" not in open(root + "/" + f).read():
        bad.append("%s does not append install.sh and install.ps1 to SHA256SUMS" % f)
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
)"
code=$?
set -e
assert_eq "0" "$code" "$OUT"

# ---- the signed release does not run the suite again: CI's verdict on the tagged
# tree is checked (scripts/release-ci-gate.sh), and the Swift tests are left out
PREP="$(cat "$ROOT/.github/actions/release-prepare/action.yml")"
assert_contains "$SIGNED_JOB" 'ci_gate: "true"'
assert_contains "$SIGNED_JOB" 'BENCHBAR_SKIP_TESTS: "1"'
assert_contains "$PREP" 'scripts/release-ci-gate.sh "$GITHUB_SHA"'
assert_contains "$PREP" "if: inputs.ci_gate != 'true'"
assert_contains "$(cat "$RELEASE")" "checks: read"
ADHOC_PREP="$(awk '/build-adhoc:/{f=1} f' "$RELEASE")"
assert_not_contains "$ADHOC_PREP" "ci_gate"
gate_step="$(grep -n -m 1 'CI passed for this commit' <<<"$PREP" | cut -d: -f1)"
tests_step="$(grep -n -m 1 'run-tests.sh' <<<"$PREP" | cut -d: -f1)"
[[ -n "$gate_step" && -n "$tests_step" && "$gate_step" -lt "$tests_step" ]] || fail "the CI gate must come first in release-prepare"
assert_contains "$(cat "$SCRIPT")" 'BENCHBAR_SKIP_TESTS'

# ---- scripts/release-promote.sh is the release: a plain push of a fast forward after the
# checks, with no merge and no force (tests/test-release-promote.sh runs its refusals)
PROMOTE="$(grep -v '^[[:space:]]*#' "$ROOT/scripts/release-promote.sh")"
assert_contains "$PROMOTE" 'git merge-base --is-ancestor "$OLD" "$SHA"'
# the sync of docs only commits: a merge made without a checkout, pushed as a fast forward of next-release
assert_contains "$PROMOTE" '"$HERE/docs-only.sh" --commit "$c"'
assert_contains "$PROMOTE" 'git merge-tree --write-tree'
assert_contains "$PROMOTE" 'git push "$REMOTE" "${MERGE}:refs/heads/next-release"'
assert_contains "$PROMOTE" '"$HERE/check-version.sh" --kind "$VERSION")" == final'
assert_contains "$PROMOTE" '--folded "$VERSION"'
assert_contains "$PROMOTE" '"$HERE/release-ci-gate.sh" "$SHA"'
assert_contains "$PROMOTE" 'git push "$REMOTE" "${TARGET}:refs/heads/main"'
assert_not_contains "$PROMOTE" "--force"
assert_not_contains "$PROMOTE" "push -f"
assert_not_contains "$PROMOTE" "+refs/heads/main:refs/heads/main"
if grep -Eq 'git merge( |$)' <<<"$PROMOTE"; then fail "release-promote.sh merges"; fi
# every check comes before the push of main
push_line="$(grep -n 'git push "\$REMOTE" "\${TARGET}' <<<"$PROMOTE" | cut -d: -f1)"
for chk in 'merge-base --is-ancestor' '--kind "$VERSION"' 'ls-remote --exit-code --tags' 'release-ci-gate.sh'; do
  line="$(grep -n -F -m 1 -- "$chk" <<<"$PROMOTE" | cut -d: -f1)"
  [[ -n "$line" && -n "$push_line" && "$line" -lt "$push_line" ]] || fail "release-promote.sh: '$chk' must come before the push"
done
# the release job leans on the gate, the gate on the docs rule
assert_contains "$(cat "$ROOT/.github/actions/release-prepare/action.yml")" 'scripts/release-ci-gate.sh "$GITHUB_SHA"'
assert_contains "$(cat "$ROOT/scripts/release-ci-gate.sh")" 'docs-only.sh" --commit'

printf 'test-release-workflows: ok\n'
