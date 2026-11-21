### Docs

- The [Features](docs/features.md) page has a row for every command and every MCP tool: `op` and `--background`, `stats`, `history`, `listen` and the 127.0.0.1 default, verified downloads, `where`, `docs` and the newer MCP tools. Rooms are listed once, for macOS and Linux, and the Windows tray has its Sharing tab.
- [What's new](docs/whats-new.md) for 0.9.0 lists the new commands, the agent tools, rooms on Linux and Windows, and what the Mac app and the Windows tray gained.
- Small facts corrected: the share guide says where rooms work on Linux and Windows, the Linux install line is the strict `curl --proto '=https' --tlsv1.2 -fsSL` one on every page, PDF printing on Linux needs x86_64 or arm64, and the Windows page no longer describes a Microsoft Store install.

### For contributors

- `test-docs` fails when a top level command or an MCP tool is named in no row of `docs/features.md`, and when a table there has the same feature twice. It reads the version of What's new from `FL_VERSION`: "(coming)" is refused on a version that is released.
