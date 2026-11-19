### Mac app

- The ⋯ menu of a site has **Restore a Backup…**: pick one of the site's backups, restore it into the site (its name typed, and the CLI backs the site up with its files first) or into a copy under a new name. The sheet shows the plan from `benchbar site restore --dry-run --json` and runs exactly that plan by its token (#177).
- The Sites tab has **Pull…**: copy a production site over SSH, or a backup you downloaded, into a new site. The plan comes from `benchbar pull --dry-run --json`. The copy is neutralised by default, and keeping production's passwords and integrations is a choice you make with a switch (#177).
- The Apps tab lists **Unfinished changes**: an app update or add that stopped part way, with the step it stopped at and the steps left. **Resume…** opens the Update or Add App sheet for those steps, and **Drop the Record…** runs `benchbar app update NAME --discard-pending` (#177).
