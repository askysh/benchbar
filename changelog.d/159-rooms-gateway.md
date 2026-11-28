### Sharing

- The gateway can run a room where you give out the seats: a person who joins with the code waits (up
  to 10 minutes) until you run `benchbar share assign` for them, and cannot take or change a seat
  themselves. This is how `benchbar share start` starts a room now (see New defaults);
  `--open-seats` starts one where the code lets a person take any free seat, as before. The docs and
  the start box say which of the two a room is. `benchbar share people` lists the free seats with their
  ids when someone has no seat (#159).
- A device on the Wi-Fi can no longer keep new guests out of a room by holding idle connections open: a
  connection of a device that is not in the room must send a request within 10 seconds and is closed
  60 seconds after it opened. A connection pool that stays full shows as `join_trouble` in
  `benchbar share status` (#159).
- A file that a guest uploads to the copy and that a browser could run (HTML, SVG, XML, an unknown type)
  reaches the other guests as a download with a sandbox policy, so it cannot act as a page of the copy.
  Images, PDFs, text, audio and video show as before (#159).
- The copy's hardening also takes away every role that may write a User, a Role, a Role Profile or a
  User Permission, because such a role could give itself back what the hardening removed. If a seat of
  a copy made by 0.8.3 holds such a role, `benchbar share start` refuses with the name of the role: run
  `benchbar share setup --refresh` once (#159).

### Mac app

- Joining a room whose host gives out the seats says so ("Ask the host for yours") when you pick a seat,
  where it said "That seat isn't available" (#159).
