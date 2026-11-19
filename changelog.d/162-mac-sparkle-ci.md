### Mac app

- The update path (Sparkle) is built and tested in every pull request, with an unsigned appcast made from the build and checked by `scripts/macos-appcast.sh`. The signed appcast links the release notes. A release whose Mac build is missing still fails before anything is published.
