### Sharing

- `benchbar share people --json` lists every seat of the room (`seats`: id, name, roles, and who holds
  it or null), and it and `benchbar share status --json` say who gives out the seats (`seat_mode`:
  `host` or `open`). The apps use both to give a waiting guest a seat (#159).
