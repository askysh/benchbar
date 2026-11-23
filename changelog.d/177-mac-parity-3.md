### Mac app

- The Overview has **Write Lock File…** and **Apply…** in the Lockfile section. Each shows the CLI's plan of `benchbar lock write` or `lock apply` and runs it when you confirm. A bench with no lockfile shows the section too, so you can write the first one (#177).
- A site's ⋯ menu has **Snapshots…**: take a snapshot with an optional label, list them, **Roll Back…** by the plan and token of `benchbar site rollback` (a snapshot of the site as it is is taken first) and **Remove…** after asking. The default site can be rolled back too, as you, and the plan says so (#177).
- A **History** pane in the sidebar lists what ran on this Mac that changed something, who started it and how it ended (`benchbar history`) (#177).
- The Overview shows who holds a lease on the bench or a site and until when. A change a lease refuses shows the holder; the only way past it is your own **Break Lease…**, which asks first (#177).
- The log window has **Since last start** (`benchbar logs --since-restart`) and the worker filter now shows `logs/worker.log` (#177).
- **Start Services Only** and **Stop Services** also show for a bench with no service installed, and **Start after login** is read from `status --json` (#177).
