### Mac app

- **Add App…** takes several apps in one plan: each row has its own branch, an optional commit to pin it to and the site it installs on. Review shows one plan from `benchbar app add A B --dry-run --json`, and **Add N Apps** runs exactly that plan by its token (#177).
- Health has **Acknowledge** on a warning (`benchbar doctor --ack`) and **Undo** under **acknowledged**. A failure cannot be acknowledged (#177).
- The ⋯ menu of a stopped bench has **Start Services Only** (`benchbar up --services-only`) and **Stop Services**, and the Overview has **Start after login** (`benchbar autostart`) (#177).
- **Install Service…** or **Refresh Service…** on the Overview shows the plan of `benchbar service --dry-run --json` and runs it by its token. A step that needs your password asks in macOS's own dialog (#177).
- The window offers these only when `benchbar commands --json` lists the command, read once per session (#177).
