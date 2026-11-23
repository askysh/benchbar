### Sharing

- After `benchbar share extend`, people in the room stay signed in. Before, their browser dropped the
  sign-in cookie at the old deadline (#159).
- The room's activity log names a seat by its id, not by the e-mail address of the seat's user
  (`benchbar share log` shows the seat's name). A day's file stops at 16 MB, and files older than 14 days
  are deleted when a share ends and when `share log` reads them, not only at the next start (#159).
- A room no longer tells the name of the site you copied to every device on the network: the Bonjour
  record and the room's greeting carry the room's label and your Mac's name only. A person sees the
  site's name once they are in the room (#159).
- A `benchbar lan-guard install` that fails after it turned pf on now keeps the pf token, so
  `lan-guard remove` turns pf off again. Before, pf stayed enabled until the next restart (#159).
- A node under a folder like `/tmp` (mode 1777) is no longer refused by the share checks because of the
  folder's group write bit: the sticky bit covers it (#159).

### Mac app

- An invite link is dialled only at an address of a local network. A link that names any other address
  (a server on the internet) finds its room by Bonjour or not at all (#159).
- Forgetting your last room also deletes the key that shows this Mac to hosts, so the next room you join
  cannot tell it is the same Mac (#159).
