#!/bin/bash
# SessionStart hook: prints the cloud working notes into the session's context,
# only in Claude Code cloud sessions. Local sessions on a Mac print nothing.
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
cat "${CLAUDE_PROJECT_DIR:-.}/.claude/cloud-context.md"
