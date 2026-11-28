### Windows tray

- Joining a room: a refusal that is not the room's own, for example "WSL is not installed" or "not found",
  now shows its line and the exit code instead of "The room could not be joined." Text
  the host chose stays one clean line and is never shown as the reason (#353).
- Long text is cut on a whole character: an emoji or a letter with its accent is no longer split
  at the end of a room, host or seat name. A seat's full name is shown up to 140 characters, and
  the roles of a seat on the Host tab are cleaned like the ones a guest sees (#353).
- The Sharing tab no longer asks the command line tool for its version at every look when it
  cannot join a room (it asks again after a minute), and closing the window while a join ends no
  longer raises an error (#353).
