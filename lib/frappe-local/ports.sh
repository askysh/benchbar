#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# ports.sh: one port block per bench, so benches run side by side.
#
#   block n   web 8000+n, socketio 9000+n, redis_queue 11000+n,
#             redis_cache 13000+n (redis_socketio is kept equal to
#             redis_cache, as bench itself does; frappe v15 and v16 never
#             connect to it)
#
# "bench init" already picks max+1 among benches in the same parent folder.
# benchbar checks every bench it knows, wherever it lives, and the listeners
# on the machine, and moves a clashing bench with "bench set-config -g" and
# "bench setup redis", the way bench writes them itself.

FL_PORT_BASE_WEB=8000
FL_PORT_BASE_SOCKETIO=9000
FL_PORT_BASE_QUEUE=11000
FL_PORT_BASE_CACHE=13000
FL_PORT_MAX_OFFSET="${FL_PORT_MAX_OFFSET:-50}"

# fl_port_block N: "web socketio redis_queue redis_cache"
fl_port_block() {
  printf '%s %s %s %s' $((FL_PORT_BASE_WEB + $1)) $((FL_PORT_BASE_SOCKETIO + $1)) $((FL_PORT_BASE_QUEUE + $1)) $((FL_PORT_BASE_CACHE + $1))
}

# The offset of the current bench's ports when they form a block, else nothing.
fl_port_offset_current() {
  local n=$((FL_WEB_PORT - FL_PORT_BASE_WEB))
  [[ "$n" -ge 0 && "$(fl_port_block "$n")" == "${FL_WEB_PORT} ${FL_SOCKETIO_PORT} ${FL_REDIS_QUEUE_PORT} ${FL_REDIS_CACHE_PORT}" ]] && printf '%s' "$n"
  return 0
}

# Ports of a bench folder from its common_site_config.json, space separated.
fl_ports_of_bench() {
  local f="$1/sites/common_site_config.json" v out=""
  [[ -f "$f" ]] || return 0
  for v in webserver_port socketio_port redis_queue redis_cache; do
    v="$(sed -n "s/^[[:space:]]*\"${v}\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}[[:space:]]*$/\1/p" "$f" | head -n1)"
    v="${v##*:}"
    [[ "$v" =~ ^[0-9]+$ ]] && out="${out} ${v}"
  done
  printf '%s' "${out# }"
}

# Every port another known bench uses, one per line, as "port bench".
fl_ports_taken_by_others() {
  local d p
  while IFS= read -r d; do
    [[ -n "$d" && "$d" != "$FL_BENCH_DIR" ]] || continue
    for p in $(fl_ports_of_bench "$d"); do printf '%s %s\n' "$p" "$d"; done
  done < <(fl_known_benches)
}

# fl_port_block_conflicts N: why block N cannot be this bench's, one reason
# per line ("8001 used by <bench>", "8001 has a listener: pid cmd"), or nothing.
# A listener that is this bench's own process does not count.
fl_port_block_conflicts() {
  local n="$1" p taken who mine
  taken="$(fl_ports_taken_by_others)"
  mine=" $(fl_bench_process_pids | tr '\n' ' ') "
  for p in $(fl_port_block "$n"); do
    if printf '%s\n' "$taken" | grep -q "^${p} "; then
      printf '%s used by %s\n' "$p" "$(printf '%s\n' "$taken" | awk -v p="$p" '$1 == p {print $2; exit}')"
      continue
    fi
    who="$(fl_port_listener_summary "$p")"
    if [[ -n "$who" && "$mine" != *" ${who%% *} "* ]]; then
      printf '%s has a listener: pid %s\n' "$p" "$who"
    fi
  done
}

# The first block with no conflicts, starting at 0.
fl_port_next_free_offset() {
  local n=0
  while [[ "$n" -le "$FL_PORT_MAX_OFFSET" ]]; do
    [[ -z "$(fl_port_block_conflicts "$n")" ]] && { printf '%s' "$n"; return 0; }
    n=$((n + 1))
  done
  return 1
}

# The ports of this bench another known bench also uses, "port bench" lines.
fl_port_clashes_with_benches() {
  local p taken
  taken="$(fl_ports_taken_by_others)"
  for p in "$FL_WEB_PORT" "$FL_SOCKETIO_PORT" "$FL_REDIS_QUEUE_PORT" "$FL_REDIS_CACHE_PORT"; do
    printf '%s\n' "$taken" | awk -v p="$p" '$1 == p {print}'
  done
}

# fl_ports_apply N: writes block N into common_site_config.json with bench
# itself and regenerates config/redis_*.conf. The caller re-renders the
# service files (Procfile.lean and the runner carry the ports).
fl_ports_apply() {
  local n="$1" web sio queue cache
  read -r web sio queue cache <<<"$(fl_port_block "$n")"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: cd ${FL_BENCH_DIR} && bench set-config -g -p webserver_port ${web} (and socketio_port ${sio}, redis_queue :${queue}, redis_cache and redis_socketio :${cache})"
    fl_info "dry-run: cd ${FL_BENCH_DIR} && bench setup redis"
    return 0
  fi
  fl_bench_env_exports
  fl_backup_file "${FL_BENCH_DIR}/sites/common_site_config.json"
  (
    cd "$FL_BENCH_DIR" || exit 1
    bench set-config -g -p webserver_port "$web" &&
    bench set-config -g -p socketio_port "$sio" &&
    bench set-config -g redis_queue "redis://127.0.0.1:${queue}" &&
    bench set-config -g redis_cache "redis://127.0.0.1:${cache}" &&
    bench set-config -g redis_socketio "redis://127.0.0.1:${cache}" &&
    bench setup redis
  ) >>"${FL_LOG_FILE:-/dev/null}" 2>&1 || { fl_fail "could not write the port block with bench set-config (log: ${FL_LOG_FILE:-none})"; return 1; }
  fl_ports_detect
  fl_bstate_set PORT_OFFSET "$n"
  fl_render_all
  fl_ok "ports: web ${web}, socketio ${sio}, redis queue ${queue}, redis cache ${cache} (block ${n})"
}

# True when DIR has a benchbar agent or is the default bench: its ports are
# settled, and a newcomer moves out of its way, never the other way round.
fl_bench_established() {
  local dir="$1"
  [[ "$(fl_state_get BENCH_DIR 2>/dev/null || true)" == "$dir" ]] && return 0
  [[ -f "$HOME/Library/LaunchAgents/com.benchbar.$(fl_bench_name_of "$dir").plist" ]]
}

# True when the current bench is the default bench or becomes it now.
fl_bench_is_or_becomes_default() {
  local cur
  cur="$(fl_state_get BENCH_DIR 2>/dev/null || true)"
  [[ -z "$cur" || "$cur" == "$FL_BENCH_DIR" || ! -d "$cur" || "${FL_MAKE_DEFAULT:-0}" == "1" ]]
}

# fl_ports_assign [OFFSET]: used by install, adopt and service. With an
# offset, that block (refused when another bench or a listener has it).
# Without one, the bench keeps its ports unless an established bench uses
# them; then it moves to the next free block. The default bench never moves
# on its own. Returns 1 on a refusal.
fl_ports_assign() {
  local want="${1:-}" cur conflicts running=0 clashes established=0 _p d
  cur="$(fl_port_offset_current)"
  if [[ -z "$want" ]]; then
    clashes="$(fl_port_clashes_with_benches)"
    [[ -z "$clashes" ]] && return 0
    fl_bench_is_or_becomes_default && return 0
    while read -r _p d; do
      [[ -n "$d" ]] && fl_bench_established "$d" && established=1
    done <<<"$clashes"
    [[ "$established" == "1" ]] || return 0
    want="$(fl_port_next_free_offset)" || { fl_fail "no free port block between 0 and ${FL_PORT_MAX_OFFSET}"; return 1; }
    fl_warn "ports ${FL_WEB_PORT}/${FL_SOCKETIO_PORT} are used by another bench: $(fl_port_clashes_with_benches | awk '{print $2}' | sort -u | tr '\n' ' ')"
  else
    [[ "$want" =~ ^[0-9]+$ && "$want" -le "$FL_PORT_MAX_OFFSET" ]] || { fl_fail "--port-offset takes a number from 0 to ${FL_PORT_MAX_OFFSET}"; return 1; }
    [[ "$want" == "$cur" ]] && { fl_ok "ports already use block ${want} (web ${FL_WEB_PORT})"; return 0; }
    conflicts="$(fl_port_block_conflicts "$want")"
    if [[ -n "$conflicts" ]]; then
      fl_fail "port block ${want} is not free: $(printf '%s' "$conflicts" | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
      fl_fix "benchbar service --port-offset $(fl_port_next_free_offset || printf 'N') --bench-dir ${FL_BENCH_DIR}"
      return 1
    fi
  fi
  fl_bench_is_running && running=1
  fl_info "moving ${FL_BENCH_NAME} to port block ${want}: web $(fl_port_block "$want" | awk '{print $1}')"
  if [[ "${FL_DRY_RUN:-0}" != "1" ]] && ! fl_confirm "Write port block ${want} into ${FL_BENCH_DIR}/sites/common_site_config.json with bench set-config?"; then
    fl_warn "ports left as they are (${FL_WEB_PORT}/${FL_SOCKETIO_PORT})"
    return 0
  fi
  fl_ports_apply "$want" || return 1
  [[ "$running" == "1" && "${FL_DRY_RUN:-0}" != "1" ]] && fl_warn "the bench is running on its old ports; run: benchbar restart --bench-dir ${FL_BENCH_DIR}"
  return 0
}
