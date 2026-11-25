### For contributors

- The runners' timing and log settings (`BENCHBAR_PING_TRIES`, `BENCHBAR_HEARTBEAT_EVERY`, `BENCHBAR_STATE_LOG`, `BENCHBAR_SHARE_POLL` and the others) and the Linux file settings `FL_PROC_DIR`, `FL_PROC_VERSION`, `FL_OS_RELEASE` and `FL_USER_RUN_BASE` count only when `FL_TESTING=1`. A service run ignores them (#142).
