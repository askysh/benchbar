#!/bin/bash
# SessionStart hook: prints working notes into the session's context. Cloud
# sessions get cloud-context.md; a local Linux session (WSL included) gets
# linux-context.md; a local Windows session gets windows-context.md. A local
# Mac session prints nothing.
dir="${CLAUDE_PROJECT_DIR:-.}/.claude"
if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
  cat "$dir/cloud-context.md"
elif [ "${OS:-}" = "Windows_NT" ]; then
  cat "$dir/windows-context.md"
elif [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
  cat "$dir/linux-context.md"
fi
exit 0
