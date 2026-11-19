### Mac app

- The update path (Sparkle) is built and tested in every pull request, with an unsigned appcast made from the build and checked by `scripts/macos-appcast.sh`. The signed appcast links the release notes, and a release without Mac files skips the appcast instead of failing.
