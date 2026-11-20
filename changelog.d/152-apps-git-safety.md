### Command line

- `benchbar app add`, `app update` and `lock apply` keep your own SSH setup
  (`core.sshCommand`, `GIT_SSH_COMMAND`) and no longer report a readable repo as
  unreadable (#152).
- Every fetch of `app update` and `lock apply` has a deadline and ends with
  "timed out after Ns" instead of hanging (#152).
- `app add` reads the branch again right before `bench get-app` and clones nothing
  when it moved since the plan. A pinned commit gets its own Python and node
  requirements, also in `lock apply` on a fresh bench (#152).
- `app add` refuses an app that needs another Frappe than the bench has, and the
  branch check matches the exact branch name (#152).
- `app update` says when upstream deleted or renamed the branch and how to switch (#152).
- A team profile's `frappe_branch` moves erpnext with it; `erpnext_branch` sets it
  on its own. `config/apps.tsv` names real branches: builder works again, and crm,
  helpdesk and lms follow `version-15` and `version-16` (#152).
