---
title: "Doctor checks"
description: "Every check of benchbar doctor by id, in four groups: system, bench, service and site. Each id links to what the check looks at and its fix."
---

`benchbar doctor` prints one line per check. A failure or a warning names the check by its id and links here. Each id is a heading on one of three pages.

The checks run in four groups, in this order: system, bench, service and site. `benchbar service` and `adopt` look only at the service group.

To read a report, use [Doctor and repair](../guides/doctor-and-repair.md). The commands and flags are in the [CLI reference](cli/doctor.md).

## System checks

On the Mac or the Linux machine: Homebrew, MariaDB config, the PDF engine, Redis, the clock under WSL, cleanup tools. The details are on [Doctor checks: the system](doctor/system-checks.md).

- [`brew`](doctor/system-checks.md#brew), [`formula_dates`](doctor/system-checks.md#formula_dates), [`python_leaves`](doctor/system-checks.md#python_leaves), [`mariadb_bind`](doctor/system-checks.md#mariadb_bind), [`mariadb_utf8`](doctor/system-checks.md#mariadb_utf8), [`pdf_engine`](doctor/system-checks.md#pdf_engine), [`redis_6379`](doctor/system-checks.md#redis_6379), [`wsl_time_sync`](doctor/system-checks.md#wsl_time_sync), [`cleanmymac`](doctor/system-checks.md#cleanmymac), [`mole`](doctor/system-checks.md#mole), [`app_copies`](doctor/system-checks.md#app_copies), [`full_disk_access`](doctor/system-checks.md#full_disk_access)

## Bench checks

On the bench folder: the env, the toolchain, assets, apps, the lockfile and profile, logs, kept backups. The details are on [Doctor checks: the bench](doctor/bench-checks.md).

- [`env_python`](doctor/bench-checks.md#env_python), [`env_setuptools`](doctor/bench-checks.md#env_setuptools), [`bench_version`](doctor/bench-checks.md#bench_version), [`toolchain_node`](doctor/bench-checks.md#toolchain_node), [`toolchain_yarn`](doctor/bench-checks.md#toolchain_yarn), [`toolchain_uv`](doctor/bench-checks.md#toolchain_uv), [`mariadb_version`](doctor/bench-checks.md#mariadb_version), [`toolchain_pkgconfig`](doctor/bench-checks.md#toolchain_pkgconfig), [`socketio`](doctor/bench-checks.md#socketio), [`assets`](doctor/bench-checks.md#assets), [`apps_txt`](doctor/bench-checks.md#apps_txt), [`app_branch_policy`](doctor/bench-checks.md#app_branch_policy), [`app_update_pending`](doctor/bench-checks.md#app_update_pending), [`app_add_pending`](doctor/bench-checks.md#app_add_pending), [`dependency_behind`](doctor/bench-checks.md#dependency_behind), [`apps_behind`](doctor/bench-checks.md#apps_behind), [`lock_parse`](doctor/bench-checks.md#lock_parse), [`lock_drift`](doctor/bench-checks.md#lock_drift), [`profile_outdated`](doctor/bench-checks.md#profile_outdated), [`logs`](doctor/bench-checks.md#logs), [`kept_backups`](doctor/bench-checks.md#kept_backups)

## Service checks

On the background service: ports, honcho, `Procfile.lean`, the runner, the agent, the stop flag, the shell helpers, `/etc/hosts`. The details are on [Doctor checks: the service and the site](doctor/service-checks.md).

- [`port_block`](doctor/service-checks.md#port_block), [`bench_path`](doctor/service-checks.md#bench_path), [`honcho`](doctor/service-checks.md#honcho), [`honcho_setuptools`](doctor/service-checks.md#honcho_setuptools), [`procfile`](doctor/service-checks.md#procfile), [`bench_listen`](doctor/service-checks.md#bench_listen), [`runner`](doctor/service-checks.md#runner), [`agent`](doctor/service-checks.md#agent), [`runner_heartbeat`](doctor/service-checks.md#runner_heartbeat), [`fork_safety`](doctor/service-checks.md#fork_safety), [`scheduler`](doctor/service-checks.md#scheduler), [`share_scheduler`](doctor/service-checks.md#share_scheduler), [`stop_flag`](doctor/service-checks.md#stop_flag), [`helpers`](doctor/service-checks.md#helpers), [`cli_link`](doctor/service-checks.md#cli_link), [`cli_duplicate`](doctor/service-checks.md#cli_duplicate), [`legacy_agents`](doctor/service-checks.md#legacy_agents), [`dead_agents`](doctor/service-checks.md#dead_agents), [`hosts`](doctor/service-checks.md#hosts), [`port_clash`](doctor/service-checks.md#port_clash), [`orphans`](doctor/service-checks.md#orphans)

## Site checks

On the site: the ping, and whether the running bench serves every site. The details are on [Doctor checks: the service and the site](doctor/service-checks.md).

- [`ping`](doctor/service-checks.md#ping), [`site_not_served`](doctor/service-checks.md#site_not_served)
