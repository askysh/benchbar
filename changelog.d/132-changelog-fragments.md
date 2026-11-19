### For contributors

- A pull request now adds a fragment, `changelog.d/<issue>-<slug>.md`, instead of editing `## Unreleased` in `CHANGELOG.md`, so pull requests no longer conflict on that block. The release step folds the fragments into `CHANGELOG.md` with `scripts/changelog-fold.sh` (`--check` validates them, `--print` shows the result). The format is in `changelog.d/README.md` (#132).
