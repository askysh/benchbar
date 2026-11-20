#!/usr/bin/env bash
#
# stats.sh: benchbar stats, the CPU and memory of a running bench's own
# processes, for the tray (the Windows tray cannot sample processes inside WSL)
# and for agents. The set is the one `benchbar down` stops (fl_bench_process_pids:
# honcho, serve, worker, schedule, socketio and the bench's listeners) plus every
# descendant of those (node watch, Redis children, anything a worker starts).
# Reading it is separate from status on purpose: status is polled for every
# bench and its process count is pinned (tests/test-status-cost.sh).

# Speed, as the Mac app computes it (macos/BenchBar/Speed/SpeedSource.swift):
# raw = clamp(1 + cpu_percent / 10, 1, 12), then the client smooths it with an
# exponential moving average, value = alpha * raw + (1 - alpha) * value.
FL_SPEED_MIN=1
FL_SPEED_MAX=12
FL_SPEED_ALPHA=0.35

# fl_proc_closure_v VAR TABLE ROOT...: the roots and every descendant, one pid
# per line, from TABLE ("PID PPID" lines). Sparse arrays only (bash 3.2).
fl_proc_closure_v() {
  local var="$1" table="$2" pid ppid queue="" seen=" " kids=() c out=""
  shift 2
  while read -r pid ppid; do
    [[ -n "$pid" && -n "$ppid" ]] || continue
    kids[ppid]="${kids[ppid]:-} ${pid}"
  done <<<"$table"
  for pid in "$@"; do queue="${queue} ${pid}"; done
  while [[ -n "${queue# }" ]]; do
    queue="${queue# }"; pid="${queue%% *}"
    if [[ "$queue" == *" "* ]]; then queue=" ${queue#* }"; else queue=""; fi
    [[ "$seen" != *" ${pid} "* ]] || continue
    seen="${seen}${pid} "
    out="${out}${pid}"$'\n'
    for c in ${kids[pid]:-}; do queue="${queue} ${c}"; done
  done
  printf -v "$var" '%s' "$out"
}

# fl_stats_resources_v VAR: the resources object, or null when no process serves the site
fl_stats_resources_v() {
  local var="$1" roots table pids measured line pid cpu rss n=0 cpu_sum=0 rss_sum=0 speed100 now window
  if ! fl_bench_is_serving; then printf -v "$var" '%s' "null"; return 0; fi
  # the roots are the matcher's, one pid per line
  roots="$(fl_bench_process_pids | tr '\n' ' ')"
  if [[ -z "${roots// /}" ]]; then printf -v "$var" '%s' "null"; return 0; fi
  fl_proc_table_v table
  # shellcheck disable=SC2086  # the roots are pids
  fl_proc_closure_v pids "$table" $roots
  # shellcheck disable=SC2086
  fl_proc_measure_v measured $pids
  while read -r pid cpu rss; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    n=$((n + 1)); cpu_sum=$((cpu_sum + cpu)); rss_sum=$((rss_sum + rss))
  done <<<"$measured"
  if [[ "$n" == "0" ]]; then printf -v "$var" '%s' "null"; return 0; fi
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  speed100=$((100 + cpu_sum))
  [[ "$speed100" -ge $((FL_SPEED_MIN * 100)) ]] || speed100=$((FL_SPEED_MIN * 100))
  [[ "$speed100" -le $((FL_SPEED_MAX * 100)) ]] || speed100=$((FL_SPEED_MAX * 100))
  window="null"; [[ -z "${FL_PROC_WINDOW_MS:-}" ]] || window="$FL_PROC_WINDOW_MS"
  line="$(printf '{"cpu_percent":%d.%d,"memory_bytes":%d,"processes":%d,"sampled_at":"%s","cpu_source":"%s","window_ms":%s,"speed":{"raw":%d.%02d,"min":%d,"max":%d,"smoothing_alpha":%s,"formula":"clamp(1 + cpu_percent / 10, min, max)"}}' \
    $((cpu_sum / 10)) $((cpu_sum % 10)) $((rss_sum * 1024)) "$n" "$now" "$FL_PROC_CPU_SOURCE" "$window" \
    $((speed100 / 100)) $((speed100 % 100)) "$FL_SPEED_MIN" "$FL_SPEED_MAX" "$FL_SPEED_ALPHA")"
  printf -v "$var" '%s' "$line"
}

# benchbar stats [--json]: read only, no lock, no log
fl_cmd_stats() {
  local res
  fl_require_bench
  fl_stats_resources_v res
  if [[ "${OPT_JSON:-0}" == "1" ]]; then
    printf '{"schema_version":%d,"bench_dir":%s,"running":%s,"resources":%s}\n' \
      "$FL_SCHEMA_VERSION" "$(fl_json_str "$FL_BENCH_DIR")" "$([[ "$res" == "null" ]] && printf false || printf true)" "$res"
    return 0
  fi
  if [[ "$res" == "null" ]]; then
    fl_info "bench ${FL_BENCH_NAME} is not running: no processes to sample"
    return 0
  fi
  local cpu mem n src
  cpu="$(fl_stats_field "$res" cpu_percent)"; mem="$(fl_stats_field "$res" memory_bytes)"
  n="$(fl_stats_field "$res" processes)"; src="$(fl_stats_field "$res" cpu_source)"
  fl_table "bench|${FL_BENCH_DIR}" "cpu|${cpu}% of one core (${src})" "memory|$((mem / 1048576)) MiB" "processes|${n}"
}

# fl_stats_field JSON KEY: a number or word of a flat key in the object above,
# without a JSON tool (the keys it is asked for are simple)
fl_stats_field() {
  local rest="${1#*\""$2"\":}"
  rest="${rest%%[,\}]*}"
  printf '%s' "${rest//\"/}"
}
