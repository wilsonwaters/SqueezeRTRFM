#!/usr/bin/env bash
# smoke.sh - acceptance test for the RTRFM plugin on a running LMS, over JSON-RPC.
#
# Usage: scripts/smoke.sh [-h|--help] [LMS_URL] [PLAYER_MAC]
#   LMS_URL     the server; default $LMS_URL, else http://localhost:9000 (https and other ports work)
#   PLAYER_MAC  the player to play on; default $PLAYER, else the only connected player
# Environment: LMS_USER and LMS_PASS for a password-protected server (HTTP basic auth).
#
# WARNING: the test plays audio on the chosen player. It replaces the player's queue; at the end
# (also on failure or Ctrl-C) it stops the player, clears the queue and switches the player off
# again if it was off.
#
# Checks, one line each ("PASS|FAIL  <n>. <name> — <detail>"), then "SMOKE: <passed>/9 passed":
#   1. Server reachable     2. Player connected      3. Plugin enabled
#   4. Radio menu lists RTRFM                        5. Top level (Live, Infinite Mix, Programs)
#   6. Live plays (time advances >= 5 s in 6 s)      7. Programs non-empty
#   8. An episode plays and seeks                    9. An episode has a track list
# Menus are walked by item name, always with the ids from the latest response.
# Exit codes: 0 all checks passed, 1 a check failed, 2 usage, dependency or connectivity error.
# Needs bash 4+, curl and jq.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "smoke: needs bash 4 or later" >&2
  exit 2
fi
case "$BASH_VERSION" in
  [0-3].*) echo "smoke: needs bash 4 or later (this is bash $BASH_VERSION)" >&2; exit 2 ;;
esac

set -uo pipefail

# Menu item names, matched by prefix: the EN values of these RTRFM/strings.txt tokens.
# t/18-smoke-strings.t checks that they are equal; change both together.
STR_LIVE='RTRFM 92.1 Live'                            # PLUGIN_RTRFM_LIVE
STR_INFINITE_MIX='RTRFM Infinite Mix'                 # PLUGIN_RTRFM_INFINITE_MIX
STR_PROGRAMS='Programs'                               # PLUGIN_RTRFM_PROGRAMS
STR_TRACKLIST='Track list'                            # PLUGIN_RTRFM_TRACKLIST
STR_NO_TRACKLIST='No track list available'            # PLUGIN_RTRFM_NO_TRACKLIST
STR_TRACKLIST_PENDING='Track list not yet available'  # PLUGIN_RTRFM_TRACKLIST_PENDING

LIVE_START_S=20     # the live stream must be playing within this
LIVE_WINDOW_S=6     # ... and advance at least LIVE_ADVANCE_S over this window
LIVE_ADVANCE_S=5
EPISODE_START_S=30  # an episode must be playing within this
SEEK_MAX_S=600      # seek target: min(SEEK_MAX_S, duration / 2)
SEEK_WAIT_S=15      # within this, time must reach the target and then play on for 1 s
MAX_PROGRAMS=15     # programs probed for episodes
MAX_ATTEMPTS=5      # episodes tried for playback, and probed for a track list

usage() { sed -n '4,20p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "smoke: $*" >&2; exit 2; }

case "${1:-}" in
  -h | --help) usage; exit 0 ;;
esac
if [[ $# -gt 2 ]]; then usage >&2; exit 2; fi

missing=()
for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
[[ ${#missing[@]} -eq 0 ]] || die "missing: ${missing[*]} (needs bash 4+, curl and jq)"

lms="${1:-${LMS_URL:-http://localhost:9000}}"
lms="${lms%/}"
[[ "$lms" =~ ^https?://[^[:space:]/]+(/[^[:space:]]*)?$ ]] || die "LMS_URL must look like http://host:9000, got '$lms'"
player="${2:-${PLAYER:-}}"
player="${player,,}"

tmp="$(mktemp -d)" || die "can't create a temporary directory"
curl_opts=(-sS -m 15 -H 'Content-Type: application/json')
[[ -n "${LMS_USER:-}" ]] && curl_opts+=(-u "$LMS_USER:${LMS_PASS:-}")

touched=""    # set once the player has been changed: cleanup then stops it
was_power=1   # the player's power state before the test
passed=0

# ---- JSON-RPC ----

# rpc PLAYER COMMAND_JSON: R = the result object; on failure returns 1 with rpc_error set
# (rpc_rc = curl's exit code, 0 when LMS answered)
rpc() {
  local body code
  R="" rpc_error="" rpc_rc=0
  body="$(jq -cn --arg p "$1" --argjson c "$2" '{id: 1, method: "slim.request", params: [$p, $c]}' 2>/dev/null)" ||
    { rpc_error="bad command: $2"; return 1; }
  code="$(curl "${curl_opts[@]}" -o "$tmp/body" -w '%{http_code}' -d "$body" "$lms/jsonrpc.js" 2>"$tmp/err")"
  rpc_rc=$?
  if [[ $rpc_rc -ne 0 ]]; then
    rpc_error="no answer to $2 (curl exit $rpc_rc: $(head -n 1 "$tmp/err" | sed 's/^curl: ([0-9]*) //'))"
    return 1
  fi
  case "$code" in
    200) ;;
    401) rpc_error="$lms asks for a password: set LMS_USER and LMS_PASS"; return 1 ;;
    *) rpc_error="HTTP $code for $2"; return 1 ;;
  esac
  if ! R="$(jq -ce 'if type == "object" and has("result") then .result // {} else error end' "$tmp/body" 2>/dev/null)"; then
    rpc_error="unexpected answer to $2: $(head -c 200 "$tmp/body")"
    R=""
    return 1
  fi
}

# items [ITEM_ID]: R = the plugin menu level (["rtrfm","items",0,100,"item_id:<id>"]). A first,
# uncached open can take longer than curl's 15 s; the plugin finishes it in the background and
# caches it, so a timed-out call is tried once more.
items() {
  local cmd='["rtrfm","items",0,100]'
  [[ -n "${1:-}" ]] && cmd="$(jq -cn --arg id "item_id:$1" '["rtrfm","items",0,100,$id]')"
  rpc "$player" "$cmd" && return 0
  [[ $rpc_rc -eq 28 ]] || return 1
  rpc "$player" "$cmd"
}

# find_item JSON PREFIX: the id of the first item whose name starts with PREFIX
find_item() {
  jq -r --arg p "$2" 'first(.loop_loop[]? | select((.name // "") | startswith($p))) | .id // empty' <<<"$1"
}

# item_list JSON FILTER: "<id><US><name>" for each item matching the jq FILTER, one per line
item_list() {
  jq -r ".loop_loop[]? | select($2)"' | [(.id | tostring), (.name // "" | gsub("\\s+"; " "))] | join("\u001f")' <<<"$1"
}

# number: $1 if it is a JSON number, else 0
num() { if [[ "${1:-}" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then echo "$1"; else echo 0; fi; }

# is EXPR: true if the jq expression over numbers is true, e.g. is "3.5 >= 2"
is() { jq -en "$1" >/dev/null 2>&1; }

# secs N: N rounded to 0.1, for messages
secs() { jq -n "$(num "$1") * 10 | round / 10"; }

# status: S_MODE, S_TIME, S_DURATION, S_TITLE of the player (S_TIME/S_DURATION are 0 if unknown)
status() {
  local line
  S_MODE="" S_TIME=0 S_DURATION=0 S_TITLE=""
  rpc "$player" '["status","-",1,"tags:u"]' || return 1
  line="$(jq -r '[.mode // "", (.time // 0 | tostring), (.duration // 0 | tostring), (.current_title // "" | gsub("\\s+"; " "))] | join("\u001f")' <<<"$R")"
  IFS=$'\x1f' read -r S_MODE S_TIME S_DURATION S_TITLE <<<"$line"
  S_TIME="$(num "$S_TIME")"
  S_DURATION="$(num "$S_DURATION")"
}

status_text() { echo "mode=${S_MODE:-?} time=$(secs "$S_TIME") current_title='$S_TITLE'"; }

# play ITEM_ID: power on and play a plugin item, replacing the queue
play() {
  touched=1
  rpc "$player" '["power",1]' || return 1
  rpc "$player" "$(jq -cn --arg id "item_id:$1" '["rtrfm","playlist","play",$id]')"
}

# wait_playing TIMEOUT: until mode is play and time > 0. why = the reason on failure. A player
# that has stopped again after 5 s has given up (e.g. an episode that is no longer available).
wait_playing() {
  local start=$SECONDS
  why=""
  while ((SECONDS - start < $1)); do
    sleep 1
    if ! status; then why="$rpc_error"; continue; fi
    if [[ "$S_MODE" == play ]] && is "$S_TIME > 0"; then return 0; fi
    if [[ "$S_MODE" == stop ]] && ((SECONDS - start >= 5)); then
      why="stopped after $((SECONDS - start)) s ($(status_text))"
      return 1
    fi
  done
  why="not playing within $1 s ($(status_text))"
  return 1
}

# ---- output and cleanup ----

result() {
  printf '%s  %s. %s — %s\n' "$1" "$2" "$3" "$4"
  [[ "$1" == PASS ]] && passed=$((passed + 1))
  return 0
}

restore_player() {
  [[ -n "$touched" ]] || return 0
  touched=""
  rpc "$player" '["stop"]'
  rpc "$player" '["playlist","clear"]'
  [[ "$was_power" == 0 ]] && rpc "$player" '["power",0]'
  return 0
}

# shellcheck disable=SC2317  # only called from the EXIT trap
cleanup() {
  local rc=$?
  restore_player
  rm -rf "$tmp"
  exit "$rc"
}
trap cleanup EXIT
trap 'echo "smoke: interrupted" >&2; exit 130' INT TERM

finish() {
  restore_player
  echo "SMOKE: $passed/9 passed"
  [[ $passed -eq 9 ]] && exit 0
  exit 1
}

echo "smoke: testing the RTRFM plugin on $lms"

# ---- 1. server reachable ----
if rpc "" '["serverstatus",0,0]'; then
  result PASS 1 "Server reachable" "LMS $(jq -r '.version // "?"' <<<"$R") at $lms"
else
  result FAIL 1 "Server reachable" "$rpc_error"
  die "can't talk to LMS at $lms"
fi

# ---- 2. player connected ----
rpc "" '["players",0,99]' || { result FAIL 2 "Player connected" "$rpc_error"; die "can't list the players"; }
players="$R"
list_players() {
  jq -r '.players_loop[]? | "  \(.playerid)  \(.name // "?")  connected=\(.connected // 0)"' <<<"$players" >&2
}
connected="$(jq -r '[.players_loop[]? | select((.connected | tostring) == "1") | .playerid | ascii_downcase] | join(" ")' <<<"$players")"
if [[ -z "$player" ]]; then
  read -r -a ids <<<"$connected"
  if [[ ${#ids[@]} -eq 1 ]]; then
    player="${ids[0]}"
  else
    result FAIL 2 "Player connected" "${#ids[@]} players connected and none chosen"
    echo "smoke: pass the MAC of one of these players (or set PLAYER):" >&2
    list_players
    exit 2
  fi
fi
if [[ " $connected " == *" $player "* ]]; then
  name="$(jq -r --arg p "$player" 'first(.players_loop[]? | select((.playerid | ascii_downcase) == $p)) | .name // "?"' <<<"$players")"
  was_power="$(jq -r --arg p "$player" 'first(.players_loop[]? | select((.playerid | ascii_downcase) == $p)) | .power // 1 | tostring' <<<"$players")"
  result PASS 2 "Player connected" "$name ($player)"
else
  result FAIL 2 "Player connected" "$player is not a connected player"
  echo "smoke: players known to $lms:" >&2
  list_players
  exit 2
fi

# ---- 3. plugin enabled ----
if rpc "" '["pref","plugin.state:RTRFM","?"]'; then
  state="$(jq -r '._p2 // "unset"' <<<"$R")"
  if [[ "$state" == enabled ]]; then
    result PASS 3 "Plugin enabled" "plugin.state:RTRFM = enabled"
  else
    result FAIL 3 "Plugin enabled" "plugin.state:RTRFM = $state (install or enable RTRFM in Settings → Manage Plugins, then restart LMS)"
  fi
else
  result FAIL 3 "Plugin enabled" "$rpc_error"
fi

# ---- 4. Radio menu lists RTRFM ----
if rpc "$player" '["radios",0,100]'; then
  entry="$(jq -r 'first(.radioss_loop[]? | select(.cmd == "rtrfm")) | .name // empty' <<<"$R")"
  if [[ -n "$entry" ]]; then
    result PASS 4 "Radio menu lists RTRFM" "\"$entry\" (cmd rtrfm)"
  else
    result FAIL 4 "Radio menu lists RTRFM" "no entry with cmd rtrfm in the Radio menu (is the plugin loaded? restart LMS)"
  fi
else
  result FAIL 4 "Radio menu lists RTRFM" "$rpc_error"
fi

# ---- 5. top level ----
live_id="" programs_id=""
if items; then
  live_id="$(find_item "$R" "$STR_LIVE")"
  mix_id="$(find_item "$R" "$STR_INFINITE_MIX")"
  programs_id="$(find_item "$R" "$STR_PROGRAMS")"
  absent=()
  [[ -n "$live_id" ]] || absent+=("\"$STR_LIVE\"")
  [[ -n "$mix_id" ]] || absent+=("\"$STR_INFINITE_MIX\"")
  [[ -n "$programs_id" ]] || absent+=("\"$STR_PROGRAMS\"")
  if [[ ${#absent[@]} -eq 0 ]]; then
    result PASS 5 "Top level" "\"$STR_LIVE\", \"$STR_INFINITE_MIX\", \"$STR_PROGRAMS\""
  else
    got="$(jq -r '[.loop_loop[]? | .name // "" | gsub("\\s+"; " ")] | join(" | ")' <<<"$R")"
    result FAIL 5 "Top level" "missing ${absent[*]}; got: ${got:-nothing}"
  fi
else
  result FAIL 5 "Top level" "$rpc_error"
fi

# ---- 6. live plays ----
if [[ -z "$live_id" ]]; then
  result FAIL 6 "Live plays" "skipped: no \"$STR_LIVE\" item"
elif ! play "$live_id"; then
  result FAIL 6 "Live plays" "play command failed: $rpc_error"
elif ! wait_playing "$LIVE_START_S"; then
  result FAIL 6 "Live plays" "$why"
else
  t0="$S_TIME"
  sleep "$LIVE_WINDOW_S"
  if ! status; then
    result FAIL 6 "Live plays" "$rpc_error"
  elif [[ "$S_MODE" == play ]] && is "$S_TIME - $t0 >= $LIVE_ADVANCE_S"; then
    result PASS 6 "Live plays" "time $(secs "$t0") → $(secs "$S_TIME") s in ${LIVE_WINDOW_S} s, now playing '$S_TITLE'"
  else
    result FAIL 6 "Live plays" "time $(secs "$t0") → $(secs "$S_TIME") s in ${LIVE_WINDOW_S} s, needs +$LIVE_ADVANCE_S s ($(status_text))"
  fi
fi

# ---- 7. programs non-empty ----
prog_ids=() prog_names=()
programs_ok=""
if [[ -z "$programs_id" ]]; then
  result FAIL 7 "Programs non-empty" "skipped: no \"$STR_PROGRAMS\" item"
elif ! items "$programs_id"; then
  result FAIL 7 "Programs non-empty" "$rpc_error"
else
  while IFS=$'\x1f' read -r id name; do
    prog_ids+=("$id")
    prog_names+=("$name")
  done < <(item_list "$R" '.type == "link"')
  if [[ ${#prog_ids[@]} -gt 0 ]]; then
    programs_ok=1
    result PASS 7 "Programs non-empty" "${#prog_ids[@]} programs"
  else
    got="$(jq -r '[.loop_loop[]? | .name // "" | gsub("\\s+"; " ")] | join(" | ")' <<<"$R")"
    result FAIL 7 "Programs non-empty" "no programs (got: ${got:-nothing}); the RTRFM site or API may be down, try again later"
  fi
fi

# episodes JSON: "<id><US><name>" of the episode rows of an opened program (playable links)
episodes() { item_list "$1" '(.isaudio | tostring) == "1" and (.type == "link" or .type == "audio")'; }

# ---- 8. an episode plays and seeks ----
played_prog=-1 played_ep=-1
try_episode() { # try_episode ID: plays it, checks progress and a seek; why = the result
  local id="$1" t0 target
  play "$id" || { why="play command failed: $rpc_error"; return 1; }
  wait_playing "$EPISODE_START_S" || return 1
  is "$S_DURATION > 0" || { why="playing, but no duration ($(status_text))"; return 1; }
  t0="$S_TIME"
  sleep 3
  status || { why="$rpc_error"; return 1; }
  is "$S_TIME > $t0" || { why="time not advancing: $(secs "$t0") → $(secs "$S_TIME") s in 3 s ($(status_text))"; return 1; }
  target="$(jq -n "[$SEEK_MAX_S, ($S_DURATION / 2 | floor)] | min")"
  rpc "$player" "[\"time\",$target]" || { why="seek failed: $rpc_error"; return 1; }
  local start=$SECONDS landed=""
  while ((SECONDS - start < SEEK_WAIT_S)); do
    sleep 1
    status || continue
    if [[ -z "$landed" ]]; then
      is "$S_TIME >= $target - 2" && landed="$S_TIME"
    elif is "$S_TIME >= $landed + 1"; then
      why="duration $(secs "$S_DURATION") s, seek to $target s: time $(secs "$landed") → $(secs "$S_TIME") s"
      return 0
    fi
  done
  if [[ -n "$landed" ]]; then
    why="seek to $target s: time reached $(secs "$landed") s but did not advance ($(status_text))"
  else
    why="seek to $target s: not reached within $SEEK_WAIT_S s ($(status_text))"
  fi
  return 1
}

if [[ -z "$programs_ok" ]]; then
  result FAIL 8 "Episode plays and seeks" "skipped: no programs"
else
  attempts=0 last=""
  for ((p = 0; p < ${#prog_ids[@]} && p < MAX_PROGRAMS && attempts < MAX_ATTEMPTS; p++)); do
    if ! items "${prog_ids[p]}"; then
      last="${prog_names[p]}: $rpc_error"
      continue
    fi
    ep_ids=() ep_names=()
    while IFS=$'\x1f' read -r id name; do
      ep_ids+=("$id")
      ep_names+=("$name")
    done < <(episodes "$R")
    for ((e = 0; e < ${#ep_ids[@]} && attempts < MAX_ATTEMPTS; e++)); do
      attempts=$((attempts + 1))
      if try_episode "${ep_ids[e]}"; then
        played_prog=$p played_ep=$e
        break 2
      fi
      last="${prog_names[p]} › ${ep_names[e]}: $why"
    done
  done
  if [[ $played_prog -ge 0 ]]; then
    result PASS 8 "Episode plays and seeks" "${prog_names[played_prog]} › ${ep_names[played_ep]}: $why"
  else
    result FAIL 8 "Episode plays and seeks" "no episode played in $attempts attempt(s) over $p program(s)${last:+; last: $last}"
  fi
fi

# ---- 9. track list ----
# Starts with the episode that played (or the first program), then the ones after it; recent
# episodes may not have a track list yet. Walks again from the top level, so every id comes
# from the latest response.
if [[ -z "$programs_ok" ]]; then
  result FAIL 9 "Track list" "skipped: no programs"
else
  probed=0 found="" last=""
  first_prog=$((played_prog >= 0 ? played_prog : 0))
  first_ep=$((played_ep >= 0 ? played_ep : 0))
  if items && programs_id="$(find_item "$R" "$STR_PROGRAMS")" && [[ -n "$programs_id" ]] && items "$programs_id"; then
    prog_ids=() prog_names=()
    while IFS=$'\x1f' read -r id name; do
      prog_ids+=("$id")
      prog_names+=("$name")
    done < <(item_list "$R" '.type == "link"')
  else
    last="couldn't open $STR_PROGRAMS again: ${rpc_error:-not found}"
    prog_ids=()
  fi
  for ((p = first_prog; p < ${#prog_ids[@]} && p < MAX_PROGRAMS && probed < MAX_ATTEMPTS; p++)); do
    items "${prog_ids[p]}" || { last="${prog_names[p]}: $rpc_error"; continue; }
    ep_ids=() ep_names=()
    while IFS=$'\x1f' read -r id name; do
      ep_ids+=("$id")
      ep_names+=("$name")
    done < <(episodes "$R")
    for ((e = (p == first_prog ? first_ep : 0); e < ${#ep_ids[@]} && probed < MAX_ATTEMPTS; e++)); do
      probed=$((probed + 1))
      where="${prog_names[p]} › ${ep_names[e]}"
      items "${ep_ids[e]}" || { last="$where: $rpc_error"; continue; }
      tl_id="$(jq -r --arg t "$STR_TRACKLIST" --arg pending "$STR_TRACKLIST_PENDING" \
        'first(.loop_loop[]? | select(.type == "link" and ((.name // "") | startswith($t)) and (((.name // "") | startswith($pending)) | not))) | .id // empty' <<<"$R")"
      if [[ -z "$tl_id" ]]; then
        last="$where: no \"$STR_TRACKLIST\" item ($(jq -r '[.loop_loop[]? | .name // "" | gsub("\\s+"; " ") | .[0:40]] | join(" | ")' <<<"$R"))"
        continue
      fi
      tl_name="$(jq -r --arg id "$tl_id" 'first(.loop_loop[]? | select(.id == $id)) | .name' <<<"$R")"
      items "$tl_id" || { last="$where › $tl_name: $rpc_error"; continue; }
      rows="$(jq -r --arg none "$STR_NO_TRACKLIST" '[.loop_loop[]? | select((.name // "") != $none and (.name // "") != "")] | length' <<<"$R")"
      if [[ "$rows" -ge 1 ]]; then
        first_row="$(jq -r --arg none "$STR_NO_TRACKLIST" 'first(.loop_loop[]? | select((.name // "") != $none and (.name // "") != "")) | .name | gsub("\\s+"; " ")' <<<"$R")"
        found="$where › $tl_name: $rows rows, first '$first_row'"
        break 2
      fi
      last="$where › $tl_name: no track rows"
    done
  done
  if [[ -n "$found" ]]; then
    result PASS 9 "Track list" "$found"
  else
    result FAIL 9 "Track list" "no track list in $probed episode(s)${last:+; last: $last}"
  fi
fi

finish
