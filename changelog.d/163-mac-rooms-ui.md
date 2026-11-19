### Mac app

- The guest health loop of "On your network" no longer runs forever: it asks the joined rooms only while the pane is open or a room is open in the browser, leaves removed or ended rooms alone, asks a room that does not answer less and less often (up to every 5 minutes) and ends when the `lan-rooms` Lab is turned off (#163).
- **Forget** and **Remove and Join Again** on a joined room ask first and say what is lost. **Open** says so in the row when its local connection cannot start (#163).
- Turning the `lan-rooms` Lab off while you host a room or have a joined room open asks first and says who is signed out (#163).
- A sharing setup that stopped halfway is shown on the Sharing tab with a **Finish setup** button (`setup_interrupted` from `benchbar share status`) (#163).
- The room code on the Sharing tab is drawn as dots, with **Show** and **Hide**; it shows once after Start sharing and New code and hides again when you leave the tab (#163).
