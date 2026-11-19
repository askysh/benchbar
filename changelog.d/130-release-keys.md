### For contributors

- The signing, notarization, Sparkle and Homebrew tap secrets now live in a `release` environment that accepts only `v*` tags and waits for the maintainer, so a branch or pull request run cannot reach the release keys.
- A `v*` tag build with a missing signing secret fails instead of producing an unsigned release; the ad hoc build is only for a manual run with the `adhoc` input.
- The certificate is deleted from the runner right after the build, the notary key and the Sparkle key are written to disk only around the one command that uses each, and `.github/CODEOWNERS` names the maintainer on the release code and the installers.
- The Homebrew tap workflow opens the tap pull request and stops: you read it and merge it. It no longer turns on auto-merge.
- A published release is never edited by a workflow: the draft steps fail on one, and on a draft they delete a file of the same name before uploading, so no `--clobber` is left. An ad hoc run on a `v*` tag is refused.
