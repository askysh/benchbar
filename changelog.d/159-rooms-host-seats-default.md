### New defaults

- You give out the seats of a room. A person who joins with the room code now waits until you give
  them a seat (`benchbar share assign`, **Give a Seat** in the Mac app, **Give this seat** in the
  Windows tray); before, the code let anyone take any free seat, the most privileged one included.
  The start of a room, `share people`, `share status` and both apps say that guests wait for you.
  To go back: `benchbar share start --open-seats`, or turn off **I give out the seats** next to
  Start. A notice says this once after the update, if you have the Rooms Lab on or set up sharing
  before (#159).

### Sharing

- A guest who waits for a seat keeps their place for 10 minutes. When the room is full, the next
  person who joins takes the place of whoever has waited longest, if that is more than 2 minutes, so
  waiting devices cannot keep a room full. `benchbar share remove ID` puts out somebody you do not
  know (#159).
- `benchbar share start --json` says who gives out the seats in its done line (`seat_mode`) (#159).
