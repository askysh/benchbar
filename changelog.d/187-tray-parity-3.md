### Windows tray

- A site's menu in the BenchBar window has **Snapshots...**: take a snapshot with an optional label, list them, **Roll Back...** by the plan and token of `benchbar site rollback` (you type the site name first, and a snapshot of the site as it is is taken first) and **Remove...** after asking. The default site can be rolled back too, as you, and the plan says so (#187).
- The Overview shows who holds a lease on the bench or a site and until when. A start, stop, restart or plan that a lease refuses shows the holder, and **Break Lease...** is your own choice: it asks, then runs the same command with `--break-lease` (#187).
- A **History** page below the benches lists what ran on this computer and changed something, who started it and how it ended (`benchbar history`) (#187).
- The Overview charts the CPU and memory of a running bench with its process count and the runner speed (`benchbar stats`), and lists its running background operations (`benchbar op list`), only while it is on screen (#187).
- **Run Bench Command...** in the Overview's More menu runs one command of the `benchbar run` allow list: a read at once, a change after its plan, by the token of that plan (#187).
