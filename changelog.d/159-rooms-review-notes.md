### Sharing

- `benchbar lan-guard remove` gives back the pf reference of an install that failed, also when the
  guard's two files are gone and it reads "not installed". Before, pf stayed enabled until the next
  restart (#159).
- `benchbar lan-guard allow-node` records the firewall entry before it asks for your password, so an
  entry is never left behind without `lan-guard remove` knowing of it (#159).
