### Sharing

- `benchbar labs off lan-rooms` can be finished: `lan-guard remove`, `lan-guard status`, `share stop`,
  `share status` and `share teardown` now run while the Lab is off. Before, the warning of `labs off`
  named `benchbar lan-guard remove`, and that command then refused with "is an experiment and it is off" (#159).
- `benchbar lan-guard remove` also takes node out of the macOS firewall's allowed apps when
  `lan-guard allow-node` added it, with the same password. `allow-node` now says that the entry lets
  every script this node runs accept connections, records what it added, and removes the entry of an
  older node after a Homebrew upgrade. An entry from 0.8.3 or older has no record: `lan-guard remove`
  prints the command that takes it out (#159).
