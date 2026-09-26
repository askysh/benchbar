#!/usr/bin/env bash
#
# docs.sh: "benchbar docs [topic]", the links to the documentation site,
# and the "see:" lines doctor prints under a failing check.
#
#   benchbar docs               opens https://benchbar.akashmishra.com
#   benchbar docs doctor        opens the doctor and repair guide
#   benchbar docs --print mcp   prints the URL instead of opening it
#
# The page is checked with one short HEAD request first; a page that is
# not there (404) opens the start page instead, and no answer at all
# (offline, a slow network) opens the page anyway.

FL_DOCS_BASE="${BENCHBAR_DOCS_URL:-https://benchbar.akashmishra.com}"
FL_DOCS_CHECK_SECS="${FL_DOCS_CHECK_SECS:-3}"

# Topic, path and a short description, one per line. The first word of a
# line is the topic; extra names for the same page follow a comma.
FL_DOCS_TOPICS="home|/|the introduction
install|/install/|install BenchBar and your first bench
quick-start,start|/quick-start/|the first ten minutes
app|/app/|the menu bar app and its window
sites,benches|/guides/benches-and-sites/|benches and sites
apps|/guides/apps/|add, install and update apps
doctor,repair|/guides/doctor-and-repair/|doctor, repair and every check
teams,profiles,lock|/guides/teams/|team profiles and the lockfile
agents|/guides/agents/|coding agents
mcp|/reference/cli/mcp/|benchbar mcp
cli|/reference/cli/install/|the command reference
config,configuration|/reference/configuration/|configuration files and variables
json|/json-schema/|the JSON API
runners|/runners/|draw your own menu bar runner
troubleshooting|/troubleshooting/|when something goes wrong
decisions|/decisions/|why things are the way they are
roadmap|/roadmap/|what comes next
contributing|/contributing/|work on BenchBar"

# fl_docs_url [PATH]: the full URL of a docs path ("/" when empty)
fl_docs_url() { printf '%s%s' "${FL_DOCS_BASE%/}" "${1:-/}"; }

# fl_docs_check_url CHECK_ID: the doctor guide's anchor for one check
fl_docs_check_url() { fl_docs_url "/guides/doctor-and-repair/#$1"; }

# fl_docs_topic_path TOPIC: the path of a topic, or return 1
fl_docs_topic_path() {
  local want="$1" line names path
  while IFS= read -r line; do
    names="${line%%|*}"
    path="${line#*|}"; path="${path%%|*}"
    case ",${names}," in *",${want},"*) printf '%s' "$path"; return 0 ;; esac
  done <<<"$FL_DOCS_TOPICS"
  return 1
}

fl_docs_topics_print() {
  local line names path desc
  printf 'Topics:\n'
  while IFS= read -r line; do
    names="${line%%|*}"
    path="${line#*|}"; desc="${path#*|}"; path="${path%%|*}"
    printf '  %-24s %s\n' "$(printf '%s' "$names" | sed 's/,/, /g')" "$desc"
  done <<<"$FL_DOCS_TOPICS"
}

fl_docs_usage() {
  cat <<USAGE
Usage: benchbar docs [TOPIC] [--print]

Opens the documentation at ${FL_DOCS_BASE%/}/ in your browser, or the page
of TOPIC. --print prints the URL instead of opening it.

USAGE
  fl_docs_topics_print
}

# fl_docs_status URL: the HTTP code of a HEAD request, 000 when there is no answer
fl_docs_status() {
  local code
  code="$(curl -s -I -o /dev/null -L --max-time "$FL_DOCS_CHECK_SECS" -A "benchbar/${FL_VERSION:-0}" -w '%{http_code}' "$1" 2>/dev/null || true)"
  printf '%s' "${code:-000}"
}

# fl_cmd_docs [TOPIC] [--print]
fl_cmd_docs() {
  local arg topic="" print=0 path url code
  for arg in "$@"; do
    case "$arg" in
      --print) print=1 ;;
      -h|--help|help) fl_docs_usage; return 0 ;;
      -*) fl_die "Unknown docs option: ${arg}" "Usage: benchbar docs [TOPIC] [--print]" ;;
      *) [[ -z "$topic" ]] || fl_die "benchbar docs takes one topic, got '${topic}' and '${arg}'" "Run: benchbar docs --help"
         topic="$arg" ;;
    esac
  done
  path="/"
  if [[ -n "$topic" ]]; then
    if ! path="$(fl_docs_topic_path "$(printf '%s' "$topic" | tr '[:upper:]' '[:lower:]')")"; then
      fl_fail "Unknown docs topic: ${topic}"
      fl_docs_topics_print >&2
      return 1
    fi
  fi
  url="$(fl_docs_url "$path")"
  if [[ "$print" == "1" ]]; then
    printf '%s\n' "$url"
    return 0
  fi
  code="$(fl_docs_status "$url")"
  if [[ "$code" == "404" && "$path" != "/" ]]; then
    fl_warn "${url} is not there (404); opening the start page instead"
    url="$(fl_docs_url /)"
  fi
  command -v open >/dev/null 2>&1 || { printf '%s\n' "$url"; return 0; }
  open "$url" || fl_die "could not open ${url}" "Open it in your browser by hand."
  printf '%s\n' "$url"
}
