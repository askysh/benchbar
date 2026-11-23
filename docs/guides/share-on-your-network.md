---
title: "Share a site on your network"
description: "Open a room so colleagues on your Wi-Fi can use a copy of a dev site in their own browser, or join a room a colleague opened. Steps for the Mac app and the command line."
---

A room lets colleagues on the same Wi-Fi use a copy of one of your dev
sites in their own browser. The copy is hardened. Your site, its database
and its files stay on your computer.

Read [How sharing keeps your bench safe](../concepts/sharing-safety.md)
before you open a room for someone else. It explains what guests can see
and what the LAN guard does.

Sharing is a Lab, so it is off until you turn it on. Use **Settings >
Labs** in the Mac app or the **Labs** page of the BenchBar window on
Windows, or run `benchbar labs on lan-rooms`. See [Labs](labs.md).

- **macOS.** Open a room in the Mac app or on the command line, and join
  one in the Mac app.
- **Linux.** Open a room on the command line, since 0.9.0. The LAN guard
  is an nftables table.
- **Windows.** Open a room on the **Sharing** tab of the BenchBar window,
  since 0.9.0. The bench runs in WSL, which needs mirrored networking for
  a room. The tray cannot join a room yet. See
  [Rooms on Windows](../windows.md#rooms-on-windows).

## Open a room in the Mac app

1. Open the bench in the BenchBar window and choose the **Sharing** tab.
2. Click **Set up sharing**. Pick the site and the seats. A seat is a
   Frappe user that a guest signs in as. BenchBar makes the copy. Nothing
   is shared yet.
3. If the tab asks, click **Turn on network protection**. macOS asks for
   your password once, in its own dialog. The protection is a firewall
   rule that keeps the bench's ports closed to other Macs.
4. Click **Start sharing** and pick how long the room stays open: 1, 2,
   4, 8 or 12 hours. **Extend** adds time, up to 12 hours in total.
5. Give your colleague the room code, or click **Copy invite**. The
   invite is a link that holds the code.
6. Click **Stop** when you are done. Every guest session ends with it.

While the room is open, you can:

- **Show** or **Hide** the room code. The code is hidden when you leave
  the tab.
- **New code** makes the old code stop working.
- **Lock room** stops new joins. Guests already in the room stay.
- **Remove** ends one guest's session. The seat menu moves a guest to
  another seat.
- **Refresh copy…** makes a new copy of the site for guests.

Guests see changes after a page refresh. The Mac stays awake while the
room is open. Closing the lid still ends the room.

## Open a room on the command line

```bash
benchbar labs on lan-rooms                        # once: turn on the Lab
benchbar share setup --site mysite.localhost --users alice,bob
benchbar share start --for 2h                     # the room is open for 2 hours
benchbar share code                               # show the room code
benchbar share invite                             # a link with the code
benchbar share people                             # who is in the room
benchbar share extend --by 1h                     # more time
benchbar share stop                               # end the room
```

`share setup` takes the site (`--site`) and the Frappe users for the seats
(`--users`). `share code --new` makes a new code. `share lock` and
`share unlock` stop and allow new joins. Every command is in the
[share reference](../reference/cli/share.md).

The room code lets a person into the room, and by default it also lets
them take any free seat. To decide yourself who gets which seat, start
the room in a terminal with `benchbar share start --assign-seats`, then
give each person a seat with `benchbar share assign`
(`benchbar share people` lists the people and the free seats). The app's
**Start** button starts a room where guests pick their own seat.

Network protection is a separate step: `benchbar lan-guard install`
asks for your password. Run it yourself. An agent or a script cannot
install it.

## Join a room in the Mac app

1. Open **On your network** in the sidebar of the BenchBar window.
2. Under **Nearby**, choose the room and click **Join**. Type the room
   code, then pick a seat. In a room where the host gives out the seats,
   the pane says so: ask the host for your seat, then open the room.
3. If a colleague sent you an invite link, click **Paste invite** instead.
4. Click **Open** on the room in **Your rooms**. The room's site opens in
   your browser.

The first time, macOS asks for Local Network access. Allow it. If you
said no, the pane shows a button that opens System Settings. **Find rooms**
looks for rooms again.

In **Your rooms**, **Change Seat** picks another seat. **Forget** signs
this Mac out of the room and deletes its key. A new code or invite from
the host is needed to join again.

## When a room ends

A room ends when its time runs out, when the host clicks **Stop**, or when
the host turns off the `lan-rooms` Lab. Turning off the Lab signs out every
guest. Sharing also ends by itself when the protection checks fail twice
in a row.

## Related

- [How sharing keeps your bench safe](../concepts/sharing-safety.md)
- [share and lan-guard](../reference/cli/share.md), the command reference
- [Labs](labs.md)
