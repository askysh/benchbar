### Windows tray

- The Add App form on the Apps tab can add several apps in one plan: **Add Another App** gives each app its own branch, a commit to pin and the sites to install it on, and one plan sheet and token covers them all (#175).
- An `app update` or `app add` that stopped part way shows a banner on the bench page with what stopped, why and the fix command. **Finish Update** and **Finish Add** open the plan of the same command, which runs only the steps left, and **Discard** asks first and then runs `benchbar app update NAME --discard-pending` (#175).

### Docs

- The Windows guide describes the Add Another App button and the banner for unfinished updates and adds (#175).
