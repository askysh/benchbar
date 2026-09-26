# Contributing to BenchBar

Thanks for helping. Issues, pull requests and ideas are welcome. This
page says how to run the tests, what a change needs before it can be
merged, and how to work with AI coding tools here.

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
Security problems go through a private report, never a public issue: see
[SECURITY.md](SECURITY.md).

## Before you start

- **A bug:** open an issue with the bug form and attach the zip from
  `benchbar report`. It contains no secrets, paths or names.
- **A small fix:** open a pull request directly.
- **A large change** (a new command, a new doctor check family, a change
  to the JSON API or the runner format, anything across the CLI and the
  app): open an issue first and say what you want to build. A short
  agreement on the shape saves you a rewrite.
- **A question:** ask in [Discussions, Q&A](https://github.com/askysh/benchbar/discussions/categories/q-a).

## Run the tests

```bash
tests/run-tests.sh              # the CLI, under mocks, in parallel; shellcheck when installed
scripts/macos-build.sh --test   # the app and its Swift tests
```

The CLI tests never touch your real benches, MariaDB or launchd: every
test builds its own `HOME` and mock state. `tests/run-tests.sh test-doctor`
runs one file. [docs/testing.md](docs/testing.md) is the guide for
trying a build on a real Mac.

CI runs the suite on macOS, builds the app, and uploads an unsigned
bundle for every pull request.

## How the code is written

- **Shell** targets macOS `/bin/bash` 3.2: no associative arrays, no
  `mapfile`, no `${var,,}`. No dependencies beyond the ones the installer
  needs. Every script passes `shellcheck` with the repo's `.shellcheckrc`.
- **Idempotent.** Every command can run twice: a second run changes
  nothing and says `unchanged`. A test for a new step runs it twice and
  checks the second run.
- **Safe with a real bench.** Never `rm -rf` inside a bench, never drop a
  database, never edit `sites/`: move broken folders aside into
  `.benchbar/backups/`. [AGENTS.md](AGENTS.md) has the full list; it holds
  for people too.
- **Swift** stays Swift 6 with the project's default MainActor
  isolation. App changes add a line to `macos/LEARNING.md` when they
  taught something.
- **Output** keeps the stable `[OK]`, `[WARN]`, `[FAIL]` and step line
  formats, and the JSON keeps its `schema_version`: scripts and the app
  parse both.

## What a pull request needs

- **Small, one topic.** A fix and a refactor are two pull requests.
- **CHANGELOG.** A line under `## Unreleased` in
  [CHANGELOG.md](CHANGELOG.md), in the section that fits.
- **DECISIONS.** One line per non obvious choice: the decision, then the
  reason. CLI and repo choices go in
  [docs/DECISIONS.md](docs/DECISIONS.md), app choices in
  [macos/DECISIONS.md](macos/DECISIONS.md). If a reviewer would ask "why
  not the obvious way?", that answer is a DECISIONS line.
- **Tested on.** The macOS version, the profile (`v15-lts`, `v16-lts` or
  a team profile) and whether it ran on a real Mac with a real bench, not
  only under the mocks.
- **Commits** have an imperative subject ("Add", "Fix", "Read") and a
  body that says why.

The pull request template asks for all of this.

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
