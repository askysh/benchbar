### Windows tray

- The More menu of a bench's Overview has the end of a bench's life (#183): **Tidy Up...** marks the bench scratch for 1 to 90 days (`bench scratch`) or not, lists the scratch benches that expired (`bench gc --dry-run`) and the databases no site refers to (`db orphans`), and **Remove Expired...** runs the plan of `bench gc` by its own token. **Forget Bench...** and **Remove Bench...** show the plan of `bench forget` and `bench remove` first; Remove asks you to type the folder name. **Remove Service...** is `uninstall-service` for that one bench, after its dry run. Each entry shows only when the CLI lists its command. The tray never drops an orphan database and never edits the Windows hosts file, so `site hosts --prune` has no entry there.

### Command line

- `bench scratch` started from the app or the tray records the mark as made by a person, not an agent, so `bench gc` names who marked the bench correctly (#183).
