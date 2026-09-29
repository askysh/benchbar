#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# consoles.sh: interactive shells into a site.
#
#   benchbar console [--site S]   bench --site S console (IPython with frappe)
#   benchbar db [--site S]        bench --site S mariadb (the site's own
#                                 database user, from its site_config.json)
#
# Both replace this process (exec), so the terminal belongs to bench; no
# lock is taken and nothing is written. db never sees the MariaDB root
# password: bench reads the site's own credentials itself.

fl_console_prepare() {
  fl_require_bench
  fl_site_require "$FL_SITE"
  if [[ ! -t 0 ]]; then
    fl_warn "not a terminal: ${1} is interactive and may exit at once"
  fi
  # frappe.cache and background jobs need the bench's Redis
  if [[ -z "$(fl_port_listener_pid "$FL_REDIS_CACHE_PORT")" ]]; then
    fl_note "the bench is stopped: calls that need Redis (frappe.cache, enqueue) fail until benchup"
  fi
  fl_bench_env_exports
  cd "$FL_BENCH_DIR" || fl_die "Cannot enter ${FL_BENCH_DIR}."
}

fl_cmd_console() {
  [[ "$#" == 0 ]] || fl_die "Unknown argument for console: $1" "Use: benchbar console [--site NAME]"
  fl_console_prepare console
  fl_info "bench --site ${FL_SITE} console   (exit with Ctrl-D)"
  exec bench --site "$FL_SITE" console
}

fl_cmd_db() {
  [[ "$#" == 0 ]] || fl_die "Unknown argument for db: $1" "Use: benchbar db [--site NAME]"
  fl_console_prepare db
  fl_info "bench --site ${FL_SITE} mariadb   (the site's own database user; exit with \\q)"
  exec bench --site "$FL_SITE" mariadb
}
