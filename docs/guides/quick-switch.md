---
title: "Quick Switch"
description: "Open a Frappe site as a pinned user from any app with Quick Switch (Control Option U) on the Mac, and how to set up the users it lists."
---

Quick Switch opens a list from any app on the Mac. From the list you open
a site in your browser, signed in as one of its users. It is a Lab on
macOS. On Windows the tray menu has its own Quick Switch. See
[Windows](../windows-tray.md#the-benchbar-window).

## Before you start

1. Turn on the `quick-switch` Lab: **Settings > Labs** in the Mac app, or
   `benchbar labs on quick-switch`. See [Labs](labs.md).
2. Allow Open as for the site. In the BenchBar window, open the bench's
   **Sites** tab, then the `...` menu of the site, and click **Allow
   Open as…**. Open as is off for every site until you do this.
3. Pin the users you switch to most. Click **Find User…** for the site,
   search for the user and click the pin. A site keeps nine pins. Give a
   pin a short label, for example `NE`.

## Open the panel

Press **⌃⌥U** (Control, Option, U) from any app. The panel lists:

- **Switch Back**, to return to the user you signed in as last.
- Your pinned users and Administrator, for the sites where Open as is on.

| Keys | Action |
|---|---|
| ↑ ↓ | Select a row |
| ↩ | Open the site as the selected user |
| 0 to 9 | Open as Administrator or a pin, at once, while nothing is typed |
| ⇥ | The next site: another bench's default site |
| esc | Close the panel |

Typing filters the list. From two characters on, it also searches the
site's other users. Press **⌃⌥U** again to close the panel.

## Notes

- Quick Switch needs no Accessibility permission.
- The link opens in the browser you used last. Other tabs of that site
  keep the old user's screen, so reload them.
- BenchBar keeps the sessions it made in memory and reuses one while the
  site still says it belongs to that user. Quitting BenchBar forgets them.
  Nothing about a session is written to disk.
- If another app already uses **⌃⌥U**, the Labs row says so in red. Turn
  the Lab off and on again after the other app lets go of the key.
- The key is the physical key that is U on a US keyboard. On another
  layout, BenchBar names the key by the letter your keyboard shows.

## Related

- [The menu bar app](../app.md#quick-switch): the same panel, in the
  reference for the app
- [Labs](labs.md)
