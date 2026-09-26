#!/usr/bin/env bash
# restart-lms.sh - restart only LMS (e.g. to reload plugin Perl code after edits).
# squeezelite and the egress-proxy keep running; squeezelite reconnects by itself.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_installed
start_egress            # no-op if already running
stop_lms
start_lms
if pid_alive "$SQZ_PIDFILE"; then
  wait_until 45 player_connected && log "$PLAYER_NAME reconnected" || log "WARNING: $PLAYER_NAME has not reconnected yet"
else
  start_player || true
fi
