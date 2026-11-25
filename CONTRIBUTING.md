# Contributing to BenchBar

Thanks for helping. Issues, pull requests and ideas are welcome. This
page says how to run the tests, what a change needs before it can be
merged, and how to work with AI coding tools here.

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
Security problems go through a private report, never a public issue: see
[SECURITY.md](SECURITY.md).

## Before you start

- **A bug on macOS or Linux:** open an issue with the bug form and attach
  the zip from `benchbar report`. It contains no secrets, paths or names.
- **A bug on Windows (beta):** use **Report a Bug** in the tray. It writes
  a redacted zip and opens the Windows bug form with the zip to drag in.
  User names and home paths are replaced in that zip.
- **A small fix:** open a pull request directly.
- **A large change** (a new command, a new doctor check family, a change
  to the JSON API or the runner format, anything across the CLI and the
  app): open an issue first and say what you want to build. A short
  agreement on the shape saves you a rewrite.
- **A question:** ask in [Discussions, Q&A](https://github.com/askysh/benchbar/discussions/categories/q-a).

## Run the tests

```bash
tests/run-tests.sh              # the CLI, under mocks, in parallel; shellcheck when installed
tests/affected.sh               # only the CLI tests your change touches (--base REF, --all)
scripts/macos-build.sh --test   # the app and its Swift tests
(cd windows/shim && go test ./...)                     # benchbar.exe, any OS
dotnet test windows/tray/BenchBarTray.sln -c Release   # the tray, on Windows
```

The CLI tests never touch your real benches, MariaDB or launchd: every
test builds its own `HOME` and mock state. `tests/run-tests.sh test-doctor`
runs one file. [docs/testing.md](docs/testing.md) is the guide for
trying a build on a real Mac.

A new test seam (a variable that lets a test replace a program, a path or
the clock) is read only when `FL_TESTING=1`, which `tests/lib/harness.sh`
sets: a production run must ignore it.

### What CI will do with your pull request

CI plans each run from the changed files. A pull request runs the tests
`tests/affected.sh` picks on Linux and under bash 3.2 in a container,
shellcheck on the changed files, and the app build when `macos/` changed;
macOS runs only for paths that need a Mac or with the label `test-macos`.
Pushes to `next-release` and `main` and the nightly run the whole suite on
macOS, Linux and bash 3.2, install a real bench on Ubuntu under
`systemd --user` for both profiles and upgrade one from release 0.8.3 (a
pull request gets those runs only with the label `test-linux`), build the
app and build and test the Windows shim and tray. The real install and the
upgrade on a Mac (`real-install.yml`) run nightly, by hand and when the
label `test-real` is added to a pull request, never on a push: they take
two of the five macOS runners for about eight minutes. The rules are in the next
section.

- **Many checks show "skipped".** A job with nothing to do for your
  change is skipped as a whole, and a skipped job passes. A docs only
  change starts no macOS job and no CLI shard beyond the docs tests.
- **`CI result` is the one required check on `next-release`.** It passes
  when every job that ran passed.
- **Rerun a few tests.** To run some tests on one platform without a full run,
  start the CI workflow by hand (Actions, CI, Run workflow) with `tests`
  (for example `test-run-lock test-lock`) and `legs` (`linux`, `bash32`,
  `macos`, `shellcheck`, `app`, `shim`, `real`).
- **Docs build** runs on a pull request that changes `docs/`, `site/`,
  the root `ROADMAP.md` or `CONTRIBUTING.md`, or the code the generated
  reference tables come from. To run it yourself: `bash tests/run-tests.sh
  test-docs`, then in `site/`: `bun install`, `bun run build`, `bun run
  linkcheck`. It is not required, but a red one means a broken page or
  link.
- **A pull request from someone who is not a collaborator waits for a
  maintainer** to click "Approve and run": the repository requires it for
  every outside contributor. Nothing is wrong; CI starts after the click.

### Choosing and timing the tests

```bash
tests/affected.sh                    # only the tests your change touches (from origin/main; --base REF, --all)
tests/run-tests.sh                   # every test, as many at a time as you have CPUs
PARALLEL=1 tests/run-tests.sh        # one after another
tests/run-tests.sh test-doctor       # only the named tests
SHARD=2/4 tests/run-tests.sh         # the second of four shards, as CI runs them
ONLY_TESTS="test-a test-b" SHARD=1/2 tests/run-tests.sh   # a list, sharded like the full suite
LIST_ONLY=1 SHARD=2/4 tests/run-tests.sh   # which tests that shard holds, without running them
```

`tests/affected.sh` maps the changed files to tests: a file in
`lib/frappe-local/` picks its own test files, the tests of its family
(the doctor library picks the doctor and repair tests, and so on: the
`lib_family` list in the script), every test that names a function it
changed, `test-cli` and `test-agent-contracts`; the LAN share's
JavaScript, the app fixtures in `macos/BenchBarTests/Fixtures/`, `scripts/`
and `docs/` have entries too. A change to the harness, the mocks,
`run-tests.sh`, `affected.sh` itself, `benchbar`, `templates/`, `config/`
or the phase scripts runs everything. `affected.sh --lib-coverage` lists
lib files that no test covers; `test-affected` fails on one, so add a
`lib_family` entry with a new lib file. Run the whole suite before you hand
work back.

Each test's output is printed whole when it finishes, in list order, and
a failing test does not stop the others: the run lists every failure at
the end and exits 1. `TEST_TIMEOUT` (default 600 seconds) kills a hung
test and prints its process tree. Every `tests/test-*.sh` is a test: a new
one needs no entry in any list. Shards are filled heaviest first from the
seconds in `tests/timings.tsv`; a test without a row counts as 10 seconds,
so a row is optional.

The app and its Swift tests build with `scripts/macos-build.sh --test`.

Issues and pull requests are welcome. For a bug, attach the zip from
`benchbar report`; it contains no secrets, paths or names. Shell code
targets macOS `/bin/bash` 3.2 with no dependencies beyond the ones the
installer needs, passes shellcheck, and every command stays idempotent:
a second run changes nothing and says so.

The shards are sized from the seconds per test in `tests/timings.tsv` (one
row per test: the name, the macOS seconds, the Linux seconds). After many
tests changed, take a green full run (a push to `next-release`) and run
`scripts/ci-timings.sh --write RUN_ID`; it rewrites the table. A test
without a row counts as 10 seconds, so a new test needs no row to run.

## How the code is written

- **Shell** targets macOS `/bin/bash` 3.2: no associative arrays, no
  `mapfile`, no `${var,,}`. No dependencies beyond the ones the installer
  needs. Every script passes `shellcheck` with the repo's `.shellcheckrc`.
- **Two older names.** The project was `frappe-mac` until 0.3.0 and its
  library `frappe-local` before that. The internal spelling stays on
  purpose, because a rename would touch every file for nothing a person
  sees: the `fl_` and `FL_` prefixes and the folder `lib/frappe-local/`.
  What an install has on disk under an old name is still read and
  migrated: the `frappe-mac` command next to `benchbar`, `com.frappe-mac.*`
  agents, `frappe-mac-run.sh`, the `# >>> frappe-mac >>>` rc block,
  `frappe-mac-template:` headers, the `.frappe-local` state folder and the
  MariaDB drop-in `frappe-mac-local-only.cnf`. None of these goes before
  1.0.0, and one goes only after a doctor check has named what is left of
  it. Do not add to the list: a new name, message or temp file says
  `benchbar`.
- **Idempotent.** Every command can run twice: a second run changes
  nothing and says `unchanged`. A test for a new step runs it twice and
  checks the second run.
- **Safe with a real bench.** Never `rm -rf` inside a bench, never drop a
  database, never edit `sites/`: move broken folders aside into
  `.benchbar/backups/`. [AGENTS.md](AGENTS.md) has the full list; it holds
  for people too.
- **Agent hooks.** If you run Claude Code here, two hooks in `.claude/`
  block a recursive delete outside the checkout and `gh` writes to other
  repositories, and `.claude/settings.json` asks before a push, a tag, a
  merge and `sudo`. They guard against mistakes and are not a security
  boundary, and under a bypass mode `ask` does nothing and the hooks do
  not cover push, tag or merge. A change to them adds its allowed and blocked command lines to
  `tests/test-guards.sh`, which runs with the rest of the suite.
- **Swift** stays Swift 6 with the project's default MainActor
  isolation. App changes add a line to `macos/LEARNING.md` when they
  taught something.
- **Output** keeps the stable `[OK]`, `[WARN]`, `[FAIL]` and step line
  formats, and the JSON keeps its `schema_version`: scripts and the app
  parse both.

## What a pull request needs

- **Against `next-release`.** `main` holds the last release and moves only
  when one is cut ([docs/releasing.md](docs/releasing.md#branches)).
- **Small, one topic.** A fix and a refactor are two pull requests. Keep a
  pull request under about 800 changed lines (generated files and fixtures
  aside): a larger change is a stack of pull requests, each one reviewable
  on its own. There is no release pull request: a release fast forwards
  `main` to commits that were already reviewed ([docs/releasing.md](docs/releasing.md#branches)).
- **Reviewed and green.** Every pull request is reviewed before it merges,
  by the maintainer or by a reviewer that reads it with a fresh context, and
  the review is a comment on the pull request. It merges only with a green
  "CI result": that one check needs every job, and the `next-release` and
  `main` rulesets require it, so a red or still running job blocks the merge.
- **The issue.** Write `Fixes #123` when the pull request finishes the
  issue and `Part of #123` when it does not. A pull request for a bug a
  user reported always names the report. GitHub closes an issue only from
  a merge into `main`, and pull requests merge into `next-release`, so
  the issue stays open after the merge: whoever merges closes a finished
  issue by hand, with a comment that names the pull request.
- **User docs.** A change a user can see updates the page that tells them
  about it: the guide or the app page under [docs/](docs/), and a row in
  [docs/features.md](docs/features.md) for a new feature, Lab or
  platform. `test-docs` fails when a top level command or an MCP tool is
  named in no row there. Updating only the reference page is not enough. The CLI
  reference tables (flags, what a command needs, the MCP tools) are
  generated from the code: after you change `lib/frappe-local/commands.sh`
  or `lib/frappe-local/mcp.py`, run `python3 -I scripts/docs-reference.py
  --write` and commit the result; `tests/test-docs.sh` fails when they
  differ. A bug with a workaround gets a troubleshooting entry in the
  same pull request.
- **A changelog fragment.** Add `changelog.d/<issue number>-<short-slug>.md`
  with a `### <Section>` heading and a bullet for each user facing change
  ([format](changelog.d/README.md)). Do not edit [CHANGELOG.md](CHANGELOG.md):
  the release step folds the fragments into it, so pull requests do not
  conflict there. `bash scripts/changelog-fold.sh --check` validates yours.
- **DECISIONS.** One line per non obvious choice: the decision, then the
  reason. CLI and repo choices go in
  [docs/DECISIONS.md](docs/DECISIONS.md), app choices in
  [macos/DECISIONS.md](macos/DECISIONS.md). If a reviewer would ask "why
  not the obvious way?", that answer is a DECISIONS line.
- **Tested on.** The OS (the macOS version, or the Ubuntu version, or the
  Windows edition and build with the WSL distro), the profile (`v15-lts`,
  `v16-lts` or a team profile) and whether it ran on a real machine with a
  real bench, not only under the mocks.
- **Plain punctuation.** No em dash and no en dash in code, docs or
  commit and pull request text: a colon, a comma or a new sentence does
  the work.
- **Commits** have an imperative subject ("Add", "Fix", "Read") and a
  body that says why. The squash merge title is a plain imperative
  sentence that ends in the pull request number, for example `Fix the
  port check for a stopped bench (#123)`. No tool trailers in a commit or
  a pull request: no `Co-Authored-By` for a tool and no "Generated with"
  line. The reviewer checks the title before merging.

The pull request template asks for all of this as checkboxes. A docs only
fix (a typo, a wrong sentence) may go to `main` instead of `next-release`
when it cannot wait for a release; say so in the pull request. The site
is built from `main` only, so it shows the last release
([docs/releasing.md](docs/releasing.md#the-docs-site)).

## Issues

Every new issue gets a first reply within two days, even if the reply is
only "seen, confirmed" or "cannot reproduce yet, please attach the zip
from `benchbar report`". A one line reply is enough. The reply says one
of: confirmed, not reproduced, or fixed on `next-release` in pull request
N, and links a workaround when there is one.

- **Labels.** One of `bug`, `enhancement` or `question`, one `area:*`
  label and the platform (`macos`, `linux`, `windows`). `needs-repro`
  when the version, the platform or the report zip is missing.
- **Milestone.** An issue that a planned release fixes goes in that
  release's milestone. The milestone page is the list of what the release
  holds.
- **Closing.** A fixed issue is closed with the pull request that fixed
  it and, at the release, with the version (see
  [docs/releasing.md](docs/releasing.md#cutting-a-release)). An open
  issue means "not fixed yet": do not leave a fixed one open.
- **Security.** A hole that puts a user at risk is not a public issue.
  Report it as [SECURITY.md](SECURITY.md) says. A public issue that turns
  out to be one gets the `security` label and is never a
  `good first issue`.
- **`good first issue`** is only for a task that needs no special
  hardware, no release keys and no knowledge of the whole codebase, and
  that is still open and still wanted. Check the list when you triage.
- **Issues filed by an agent.** An agent session that files an issue for
  the maintainer says so in the first line ("Filed by an agent session
  for the maintainer."), sets the labels and the milestone, and closes
  the issue in the pull request that fixes it.

## AI assisted contributions

BenchBar is itself developed with AI coding agents; [AGENTS.md](AGENTS.md)
is the guide they read. AI assisted pull requests are welcome, on these
terms:

- **Disclose it.** One line in the pull request: the tool and how much it
  did, for example "Claude Code wrote the first draft of the doctor
  check, I rewrote the tests" or "None".
- **Own every line.** You must be able to explain every line you submit,
  and why it is there. "The model wrote it" is not an answer in review.
- **Run it on a real Mac.** Passing tests under mocks is not enough for a
  change that touches launchd, MariaDB, Homebrew or a bench.
- **No unedited AI text in issues or discussions.** Write in your own
  words; a pasted wall of generated text wastes the reader's time.
- **`good first issue` items are for people learning the codebase by
  hand.** Please do not solve them with an agent: they exist so a new
  contributor can find their way around.

## Releases

Maintainers cut releases; [docs/releasing.md](docs/releasing.md) has the
steps.
