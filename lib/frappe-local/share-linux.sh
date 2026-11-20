#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# share-linux.sh: the Linux half of a share's lifetime (share-run.sh has the macOS half and the callers).
# Sourced after the rest; on macOS it does nothing. It redefines, with the same names, the functions
# share-run.sh defines for launchd, so no caller branches:
#
#   job        a systemd --user unit, benchbar-share-gateway.service, written into the user manager's
#              runtime folder ($XDG_RUNTIME_DIR/systemd/user, a tmpfs) and never into ~/.config, so the bench
#              unit's globs (doctor, uninstall-service) never see it and a reboot or a logout forgets it, as
#              launchd forgets the bootstrapped job. The runner deletes the file when it ends (ExecStopPost),
#              and CollectMode forgets the unit even when it failed.
#   Bonjour    avahi-publish when it is installed, else no advertising (the runner says so, and share start
#              says so once); the room is then joined by its address and code.
#   caffeinate none yet: nothing keeps a laptop from suspending while a room is on.
#   lsof       ss, which names the owner of a listening socket.
#   the label  the host name, where macOS has a ComputerName.
#
# Seams for the tests, read only under FL_TESTING=1: FL_SHARE_DNS_SD (the advertiser; set and empty means
# none) and FL_SHARE_LSOF (the tool that names a port's owner).

fl_is_linux || return 0

FL_SHARE_UNIT=benchbar-share-gateway.service

fl_share_job_unit_dir() { printf '%s/systemd/user' "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"; }
fl_share_job_target() { printf '%s' "$FL_SHARE_UNIT"; }
fl_share_job_manager() { printf 'systemd'; }
fl_share_job_bootout_hint() { printf 'systemctl --user stop %s' "$FL_SHARE_UNIT"; }

# loaded: the unit is running, starting or stopping (a failed or gone one is not)
fl_share_job_loaded() {
  case "$(systemctl --user show -p ActiveState --value "$FL_SHARE_UNIT" 2>/dev/null)" in
    active|activating|deactivating|reloading) return 0 ;;
  esac
  return 1
}

# fl_share_job_stop: stops the unit (the call returns once the runner's trap has run), forgets its file,
# and says whether it is gone
fl_share_job_stop() {
  fl_log "systemctl --user stop ${FL_SHARE_UNIT}"
  systemctl --user stop "$FL_SHARE_UNIT" >/dev/null 2>&1 || true
  rm -f "$(fl_share_job_unit_dir)/${FL_SHARE_UNIT}"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  ! fl_share_job_loaded
}

# fl_share_job_start FILE: FILE (the unit text) goes into the runtime folder, systemd reads it, the unit starts
fl_share_job_start() {
  local dir dest="" rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  if [[ ! -d "$rt" ]]; then
    fl_fail "there is no user session folder (${rt}), so systemd --user cannot run the sharing job"
    return 1
  fi
  dir="$(fl_share_job_unit_dir)"
  dest="${dir}/${FL_SHARE_UNIT}"
  if ! { (umask 077; mkdir -p "$dir") && cp "$1" "$dest"; }; then fl_fail "could not write ${dest}"; return 1; fi
  fl_log "systemctl --user daemon-reload; start ${FL_SHARE_UNIT}"
  if ! systemctl --user daemon-reload >/dev/null 2>&1 || ! systemctl --user start "$FL_SHARE_UNIT" >/dev/null 2>&1; then
    rm -f "$dest"
    fl_fail "systemd did not start ${FL_SHARE_UNIT}: $(fl_user_manager_msg 2>/dev/null || printf 'is the user manager running (loginctl enable-linger)?')"
    return 1
  fi
}

fl_share_job_text() {
  fl_template_render share.service "RUNNER=${1}/share-run.sh" "SHARE_DIR=${1}" "PATH=$(fl_launchd_path_value)" "LOG=${1}/share.log" \
    "UNIT_FILE=$(fl_share_job_unit_dir)/${FL_SHARE_UNIT}"
}

# the advertiser: avahi-publish, or empty
fl_share_dns_sd_bin() {
  if [[ "${FL_TESTING:-}" == "1" && -n "${FL_SHARE_DNS_SD+x}" ]]; then printf '%s' "$FL_SHARE_DNS_SD"
  elif [[ -x /usr/bin/avahi-publish ]]; then printf '/usr/bin/avahi-publish'; fi
}
fl_share_caffeinate_bin() { :; }
fl_share_lsof_bin() {
  local p
  if [[ "${FL_TESTING:-}" == "1" && -n "${FL_SHARE_LSOF:-}" ]]; then printf '%s' "$FL_SHARE_LSOF"; return 0; fi
  for p in /usr/bin/ss /bin/ss /usr/sbin/ss /sbin/ss; do [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }; done
  printf '/usr/bin/ss'
}

# once, when share start writes the job: no advertiser is no failure, and the person should know
fl_share_start_note() {
  [[ -n "$(fl_share_dns_sd_bin)" ]] || fl_info "avahi-publish is not installed, so this room is not listed on the network: people join with this computer's address and the code (sudo apt install avahi-utils lists it)"
}

fl_share_computer_name() { printf '%s' "${HOSTNAME%%.*}"; }
