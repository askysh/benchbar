---
title: Folder scanning design brief
description: Native discovery and selection of existing Frappe benches.
---

# Folder scanning for existing benches

Add Scan Folder to the menu bar and a Find Benches pane in the existing window.
Users choose a directory, scan recursively, review paths/sites, and add selected
benches to a persistent CLI registry. Rescanning deduplicates canonical paths.
The scan is read only, skips hidden/dependency/test fixture folders and symlinks,
reports inaccessible directories, supports cancellation, and works for an empty
result. Native controls provide keyboard navigation and text status indicators.

BenchBar is the intended manager, per the user's direction. Adding a bench
makes it visible; Set Up Management previews the existing CLI adopt plan before
applying service setup. No scan automatically starts benches or modifies sites.
Active externally started processes must be stopped before management setup.

Extend the existing CLI and SwiftUI discovery flow, retain upstream 0.5.6 UI,
and verify with shell fixture tests, Swift tests, a release build, and a real
read-only scan of Developer. Install the local build after verification.
