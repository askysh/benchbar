### For contributors

- A push to `next-release` cancels the push run of the tree before it, since every pull request already passed CI on its merge result; a push to `main` is never cancelled (CI-12). `docs/releasing.md` has a hotfix path for the released version while `next-release` holds unfinished work (OPS-10).
