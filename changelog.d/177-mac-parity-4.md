### Mac app

- The Overview's **⋯** menu has **Run Bench Command…**: one command of the `benchbar run` allow list, a site of the bench and the flags the command takes. A read (`doctor`, `list-apps`, `version`) runs at once and shows its output; a change (`migrate`, `clear-cache`, `build`, `run-tests`) shows the CLI's plan first and runs exactly that plan by its own token (#181).
- The Overview lists the bench's running background operations (`benchbar op list --running`), from a terminal, an agent or the app, with their step and progress, and says how one ended. It is read only while the window can be seen (#180).
- **Watch Assets in Terminal** in the same menu opens `benchbar watch` for the bench (#177).
