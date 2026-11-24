### Command line

- The approval token of `app add` and `lock apply` now covers the current commit of the apps already in the bench. A plan that was approved before someone moved an app's checkout is refused as changed, and nothing runs (#153).
