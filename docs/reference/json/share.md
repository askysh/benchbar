---
title: "JSON: share and lan-guard"
description: "The JSON of benchbar share and lan-guard: the status, the room documents and the guest documents."
---

The documents of the commands that share a site on your network. The [rules for readers](../../json-schema.md#rules-for-readers) apply to all of them.

## Sharing

`benchbar share` and `benchbar lan-guard` ([reference](../cli/share.md)).
Every document starts with `schema_version` and `cli_version`; under
`--json` the done fields follow. The streams (setup, start, stop, extend,
lock, unlock, remove, assign, teardown, and lan-guard install, remove and
allow-node) end in a done line carrying the fields shown. No document but
`share code --json` and `share invite --json` ever holds the room code, and
none holds a session id.

### `benchbar share status --json`

```json
{"schema_version":1,"cli_version":"…","protocol":3,"bench":"/path/to/bench","site":"mysite.localhost",
 "share_site":"share.localhost","state":"on","phase":null,"web_up":true,"degraded":false,"error":null,
 "label":"Your Mac","port":8443,"web_port":8001,"lan_ip":"192.168.1.20","started":"…","deadline":"…",
 "seconds_left":3600,"can_extend_s":28800,"copy":{…},"allowed_users":["priya@example.com"],"seats":2,
 "people":1,"devices_total":1,"devices_online":1,"pending":0,"locked":false,"lock_reason":null,
 "budget_left":10,"join_trouble":false,"wipe_failed":0,"lan_guard":"installed","preflight":null,
 "setup_interrupted":false,"seat_mode":"open","host_key":"0123456789abcdef"}
```

- `state`: `on`, `off`, `expired` or `error`.
- `lock_reason`: `host`, `budget` (10 wrong codes; only `share code --new` opens it), `full`, or null.
- `wipe_failed`: a sign-out that is owed or failed. While sharing is off it
  reads 1 or more from the marker `share stop` leaves when it could not end
  every session of the copy. It reads 1 for a moment after every
  `share remove`, until the removed seat's sessions are gone.
- `pending` is always 0: there are no join requests to approve in rooms.
- `lan_guard`: as `lan-guard status`'s `state`.
- `preflight`: null, or with `--preflight` the critical checks as in `share preflight`.
- `setup_interrupted`: a setup stopped halfway (no `share.json`, but the one it set
  aside or the copy is there); `share setup --refresh` finishes it.
- `host_key`: the first 16 hex digits of the fingerprint of this host's key, or
  null before `share setup`. The join sheet of an invite shows a guest the same
  digits, so a host can read them out. It is not a secret.
- `seats`: the number of seats of the room, an integer. In `share people --json`
  the key of the same name is a list, one object per seat.
- `seat_mode`: who gives a person their seat in the room that is on: `host`
  (you, with `share assign`; a guest cannot take one) or `open` (anyone in the
  room takes a free one). null while no room is on.

### `benchbar share preflight --json`

`{"schema_version":1,"cli_version":"…","protocol":3,"ok":bool,"lan_ip":"…"|null,"checks":[{"id","class","status","message","fix_action"}]}`.
`class` is `static` or `critical`; `status` is `ok`, `fail`, `warn` or
`skip`. `fix_action` is a machine name for the app's button (`none`,
`install_network_protection`, `allow_node_firewall`,
`open_local_network_settings`, `rerun_setup`, `restart_sharing`, …).

### `benchbar share users --json`

`benchbar share users [--site S] --json`: who can take a seat in a shared
copy, and what each would lose there.

```json
{"schema_version":1,"cli_version":"…","site":"mysite.localhost","users":[
  {"name":"priya@example.com","full_name":"Priya","enabled":true,"user_type":"System User",
   "roles":["Sales User"],"code_capable_roles":[],"will_demote":false,"selectable":true}],"truncated":false}
```

`code_capable_roles` are the roles that can run code or change settings: the
copy takes them from the user (`will_demote`; never for `Administrator`).
`selectable` is true for an enabled System User that is not `Administrator`.
`truncated` is true past the first 500 users.

### `share start`, `share extend`, `share stop`

Streams that end in a done line carrying the fields shown (with `--dry-run`,
`share start` prints one document with the plan).

| Command | Fields |
|---|---|
| `share start` | `bench`, `share_site`, `state` (`on`), `label`, `port`, `started_epoch`, `deadline_epoch`, `started`, `deadline` (ISO 8601, UTC), `seat_mode` (`host`: guests wait until you give each a seat; `open`: `--open-seats`) |
| `share start --dry-run` | `bench`, `share_site`, `dry_run`, `label`, `for_s`, `deadline`, `seat_mode` (`host` or `open`: what the room would be), `steps` (ids of what a start does) |
| `share extend` | `bench`, `deadline_epoch`, `deadline`, `capped` (the 12 hour limit from the start was reached), `seconds_left` |
| `share stop` | `bench`, `share_site`, `state` (`off`) |

### The room documents

They share `bench`, `share_site` and `wipe`. `wipe` is null when nothing was
owed, else `{"retried":bool,"wiped":N|null,"wipe_failed":M|null}`.

| Command | Fields |
|---|---|
| `share code` | `code` (`"NNNNNN"`, a placeholder here), `new`, `budget_left` |
| `share invite` | `url` (`benchbar://share/join?v=1&r=…&h=…&s=…&c=…&a=…&x=…`, holds the code), `text` (the message, lines apart by `\n`), `expires_at` (ISO 8601, UTC), `room` |
| `share lock`, `share unlock` (done) | `locked`, `lock_reason` |
| `share people`, `share devices` | `state` (`on`/`off`), `people`: `[{id, name, model, ip, seat_id, seat_full_name, online, joined, last_seen}]` (`devices` is another name for `people`), `seats`: every seat of the room, `[{seat_id, full_name, roles, held_by, held_by_name}]` (`held_by` is the `id` of the person in the seat, null for a free seat; never the seat's user; in `share status --json` `seats` is the count, an integer), `seat_mode` (`host`, `open`, or null while sharing is off, as in `share status`). With sharing off `people` and `seats` are empty |
| `share remove`, `share revoke` (done) | `device`, `name`, `removed`, `new_code` (a bool, never the code) |
| `share assign` (done) | `device`, `name`, `seat_id`, `seat_full_name` |
| `share log` | `entries`: `[{ts, device, user, method, path, status}]`, `truncated`. `user` is the seat's name (its id when the room no longer has the seat); a line written by 0.8.3 holds the e-mail address of the seat's user until it is 14 days old |
| `share open-as` | `user`, `page`, `opened`: never the link or the session id, even with `--print-url` |
| `share teardown` (done) | `copy_dropped`, `archived_path`, `state_removed` |

### The guest documents

A guest's commands act on somebody else's room, so they have no `bench`.
None of them ever holds the room code or a key.

| Command | Fields |
|---|---|
| `share join` | `joined` (false: this computer was in the room already, no code was used), then the room: `id` (the first 16 hex digits of the host's key), `room`, `host`, `site`, `address`, `port`, `host_key`, `joined_at`, `forwarding`, `state`, `seat`, `url`, `local_port`, `deadline_epoch`. While `state` is `waiting`: `host_assigns` and `seats`: `[{seat_id, full_name, roles, taken_by}]` |
| `share join --dry-run` | `id`, `host_pin` (the 64 hex digits of the host's key), `host_key` (its first 16), `address`, `port`, `room`, `host`, `locked`, `full`, `people`, `seats`, `known`, `paired` (this computer is in the room now), `from_invite` |
| `share joined` | `rooms`: a list of the room fields of `share join` |
| `share leave`, `share forget` (done) | `id`, `room`, `host`, `told_host` (false: the room did not answer, or this computer was no longer in it), `forwarder_stopped` (false: the process of the local address did not end); `share forget` adds `forgotten` |

- `state`: `ready` (a seat, the room is open on `url`), `waiting` (no seat yet), `removed`, `new_room` (the host started another room: join it with its code), `ended`, `identity_changed` (the host shows another key: not connected), `offline`, or `closed` (no local address is open; `share join` opens it).
- `seat`: the user of the seat this computer holds, or null.
- `url`: the local address that signs a browser in as the seat. It is null under `BENCHBAR_NONINTERACTIVE`.
- A refused `share join --json` prints no document: the sentence is on stderr, and the exit code is 1.

### `benchbar lan-guard status --json`

```json
{"schema_version":1,"cli_version":"…","state":"installed","active":true,
 "ports":"8000:8099 9000:9099 11000:11099 13000:13099 3306","anchor":"com.apple/250.benchbar","lan_ip":"192.168.1.20"}
```

- `state`: `installed`, `missing` or `outdated` (the anchor's rules differ, or the daemon does not load it).
- `active`: whether pf refuses the bench ports, by the probe alone (the files are `state`): true when no bench port answered from `lan_ip` and the control port did, false when a bench port answered, null with no LAN address or when the probe could not run.

`lan-guard install` and `remove` end in a done line with the same fields (after
`remove`, `state` is `missing`; a `remove` with nothing installed changes nothing
and prints the same document). `lan-guard allow-node` ends in a done line with
`node`, the realpath of the node it allowed (or found allowed already, or the
firewall is off: nothing changes then, the line is the same), and no `state`.
