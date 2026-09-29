---
title: "URL scheme"
description: "benchbar:// links start, stop and open a bench from Raycast, Shortcuts, Alfred, a script or a bookmark."
---

The BenchBar app answers `benchbar://` links. Anything that can open a
URL can drive a bench with them: Raycast, Shortcuts, Alfred, a shell
script with `open`, a bookmark in the browser.

```bash
open "benchbar://up?bench=frappe-bench"
```

The app has to be installed (it registers the scheme); if it is not
running, the link starts it first.

## Routes

| Link | What it does |
|---|---|
| `benchbar://up` | starts the bench, like `benchup` |
| `benchbar://down` | stops the bench, like `benchdown` |
| `benchbar://restart` | restarts the bench, like `benchrestart` |
| `benchbar://open` | opens the site in the browser |
| `benchbar://logs` | opens the bench's log window |
| `benchbar://window` | opens the BenchBar window at the bench's page |
| `benchbar://doctor` | runs doctor and opens the bench's Health tab |
| `benchbar://console` | Terminal with `benchbar console` for the site |
| `benchbar://db` | Terminal with `benchbar db` for the site |
| `benchbar://editor` | the bench folder in VS Code or Cursor (the one chosen in Settings) |

Start and restart check ports first, as the buttons do: a conflict is
not resolved from a link, it shows in the popover.

## Which bench

| Query | Meaning |
|---|---|
| `bench=NAME` | the bench with this name, as `benchbar list` shows it |
| `bench=/absolute/path` | the bench in this folder; `~/frappe-bench` works too |
| `site=NAME` | with `open`, `console` and `db`: this site instead of the default one |

Without `bench=`, a link acts on the bench selected in the menu bar, or
on the only bench there is. When that is not clear (several benches and
none selected, two benches with the same name, a name or site that does
not exist), the link does nothing and the BenchBar window opens with a
message that says why. `benchbar://window` without a bench just opens the
window.

Examples:

```text
benchbar://restart?bench=frappe-bench
benchbar://open?bench=v16-bench&site=v16two
benchbar://doctor?bench=%2FUsers%2Fyou%2Fwork%2Ffrappe-bench
```

Encode a path in a query: `/` becomes `%2F`, a space `%20`.

## Profile links

Two links share a team profile. They need no bench.

| Link | What it does |
|---|---|
| `benchbar://profile/import?url=ENC` | Team Profiles with the Import sheet filled in with this https address |
| `benchbar://profile/subscribe?url=ENC` | Team Profiles with the Subscribe sheet filled in with this git repository |

`ENC` is the address, percent encoded. The sheet waits for your click:
Review fetches and checks the profile, Add Profile saves it, Subscribe
clones the repository. Nothing is installed from a link. Import takes
only an https address, subscribe only an https, ssh or `git@host:owner/repo`
remote; any other address opens the window with a message instead.
Export in Team Profiles makes an import link for you (Copy Import Link).

## What links cannot do

Any web page can open a `benchbar://` link, so links only start, stop,
restart and open things. `console` and `db` only open a Terminal window
at a prompt; nothing runs in it until you type. There is no route for repair, install, update,
pull, restore, dropping a site or anything else that changes or deletes
files; the profile links only fill in a sheet, and the app ignores any
route not in the tables above and logs it.
Browsers ask before a page opens an app, so a page cannot do even that
silently.

To see ignored links, stream the app's log:

```bash
log stream --predicate 'subsystem == "com.akashmishra.benchbar" && category == "url"'
```

## Raycast

A [script command](https://github.com/raycast/script-commands) per
action. Save it in your script commands folder, for example
`~/raycast/benchup.sh`, and make it executable:

```bash
#!/bin/bash

# @raycast.schemaVersion 1
# @raycast.title Start Frappe bench
# @raycast.mode silent
# @raycast.packageName BenchBar

open "benchbar://up?bench=frappe-bench"
```

An argument makes one command for every bench:

```bash
#!/bin/bash

# @raycast.schemaVersion 1
# @raycast.title Restart bench
# @raycast.mode silent
# @raycast.packageName BenchBar
# @raycast.argument1 { "type": "text", "placeholder": "bench name" }

open "benchbar://restart?bench=$1"
```

A Raycast Quicklink with the link as its URL works too, without a script.

## Shortcuts

1. Create a shortcut and add the **URL** action with the link, for
   example `benchbar://up?bench=frappe-bench`.
2. Add **Open URLs** after it.
3. Give the shortcut a keyboard shortcut in its details, or add it to the
   menu bar.

A **Choose from Menu** action in front with Start, Stop and Restart, each
leading to its own URL, makes one shortcut for all three.
