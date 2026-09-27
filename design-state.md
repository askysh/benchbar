# Design state

Approved direction: choose a folder in BenchBar, discover nested Frappe benches,
select benches to remember, and use BenchBar for subsequent management.

Principles: native macOS controls, visible full paths, explicit scan/setup states,
read-only discovery, preserve existing data, no silent service starts.

Artifact: docs/designpowers/briefs/2026-09-27-folder-scan.md
Decision: work on local feat/folder-scan from v0.5.6 to preserve installed UI.
Verification: scanner and registry tests, Swift workflow tests, release build,
read-only scan and native UI verification.

Completed verification:
- 192 Swift tests pass; signed Release build installed locally (0.5.6, build 2).
- Full CLI suite and ShellCheck: 34 jobs, 0 failures.
- Independent review: hashed-service port ownership and filesystem-root issues
  resolved with regression tests.
- Native UI: folder picker, 17-bench scan, Add Selected, duplicate-aware rescan,
  persistence after relaunch, distinct sidebar names, and read-only setup preview
  verified. No bench services were adopted or started during validation.
