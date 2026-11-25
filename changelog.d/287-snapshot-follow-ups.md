### Command line

- `benchbar site snapshots` names a folder a cut short snapshot left behind (`.incomplete-ID`) with its size and the command that moves its backup files back. It also says how many snapshots beyond the limit are held back as undo points, and their size, and so does the prune plan (#287).
- After a retried rollback, the undo line names the snapshot from before the first attempt, not the half restored site (#287).
