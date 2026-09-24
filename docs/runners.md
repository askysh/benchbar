# Custom runners

The character in the menu bar is a **runner**. BenchBar ships two, Bench
and Coffee cup, and you can add your own: a folder with a `manifest.json`
and PNG frames. A working example with the script that drew it is in
[`examples/runners/blob`](../examples/runners/blob).

## Install one

1. Open BenchBar Settings (right click the runner, Settings, or ⌘, in the popover).
2. Under Menu bar runner, click **Import Runner…**.
3. Choose the runner folder, or a `.zip` of it.

BenchBar checks it, copies it to
`~/Library/Application Support/BenchBar/Runners/<id>/` and switches to
it. The id is the folder name in lowercase, with anything other than
letters, digits, `.`, `-` and `_` turned into `-`. Importing a runner
with the same id again replaces it. **Remove** moves it to the Trash.

You can also copy a folder into that Runners folder by hand (**Show
Runners Folder** opens it); it is loaded the next time Settings opens.

## The folder

```
blob/
  manifest.json
  run1.png
  run2.png
  ...
```

## manifest.json

```json
{
  "name": "Blob",
  "author": "Your Name",
  "template": true,
  "states": {
    "running": ["run1.png", "run2.png", "run3.png", "run4.png"],
    "sleeping": ["sleep1.png", "sleep2.png"],
    "crashed": ["wobble1.png", "wobble2.png"],
    "alert": ["alert.png"]
  },
  "frame_order": "forward"
}
```

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | shown in Settings, 1 to 40 characters |
| `author` | no | shown in Settings as "Name (by author)" |
| `template` | yes | `true`: only the alpha of your frames counts, BenchBar paints them in the menu bar's text color (like every other menu bar icon). `false`: your colors are shown as they are |
| `states` | yes | frames per state, in play order |
| `frame_order` | no | `"forward"` (default): 1 2 3, 1 2 3. `"ping_pong"`: 1 2 3 2, 1 2 3 2, a back and forth loop from fewer frames |

### States

| State | When it plays | How |
|---|---|---|
| `running` | the bench is up | loops; faster when the bench is busy (up to 12 times) |
| `starting` | the bench is starting | loops |
| `sleeping` | the bench is stopped | loops, slowly |
| `crashed` | the bench crashed or the crash guard paused it | plays 3 times |
| `alert` | after `crashed` | plays once, then holds its last frame |
| `unknown` | the CLI is missing, or no answer yet | loops, slowly |

`running` is required. Any other state you leave out uses the running
frames. With Reduce Motion on, BenchBar shows one still frame per state:
the first frame, or the last one of `alert`.

## Frame rules

BenchBar is strict, so a runner never breaks the menu bar. A runner that
breaks a rule is not imported, and Settings says which rule and which
file.

- PNG files, named in `manifest.json` by plain file name: no folders, no
  `..`, not hidden (no leading `.`), ending in `.png`.
- **36 px tall** (18 points at 2x), **10 to 100 px wide**, and every
  frame the same size.
- At most **30 frames** per state.
- At most **2 MB** for the whole folder.
- No symbolic links.
- Only `manifest.json` and the files it lists are copied on import;
  anything else in the folder or zip is left behind.

## Tips

- Draw at 36 px tall and look at it at actual size: the menu bar is 18
  points tall, and fine detail disappears.
- For a template runner, draw in black on transparent and cut details
  (eyes, a mouth) out as transparent holes; they read well in both light
  and dark menu bars.
- Keep the character in the same spot across frames and move only what
  should move, or it jitters.
- 4 to 8 running frames are plenty. The running loop plays 5 frames per
  second when idle and up to 60 when the bench is busy.

## Making frames in code

[`examples/runners/blob/make-frames.swift`](../examples/runners/blob/make-frames.swift)
draws the example with Core Graphics:

```bash
cd examples/runners/blob
swift make-frames.swift
```

Any drawing app works too: export PNGs at 36 px tall with a transparent
background.

## Not allowed

The built in names `bench` and `cup` are reserved. Do not use art,
names or characters you do not have the rights to: a runner is yours to
share only if you made it or its license allows it.
