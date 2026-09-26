#!/usr/bin/env bash
# rpc.sh - run an LMS JSON-RPC (slim.request) command and print the result as JSON.
# Usage: dev/rpc.sh [--raw] <playerid|-|dev> '<json array command>'
#   playerid : a player MAC, "-" for server-level commands, "dev" = DevPlayer's MAC
#   --raw    : print the whole JSON-RPC response instead of just .result
# Examples:
#   dev/rpc.sh - '["players",0,10]'
#   dev/rpc.sh dev '["playlist","play","https://ice1.somafm.com/groovesalad-128-mp3"]'
#   dev/rpc.sh dev '["status","-",1,"tags:aluK"]'
#   dev/rpc.sh dev '["rtrfm","items",0,20]'      # plugin menu (once the plugin exists)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
raw=0
if [[ "${1:-}" == "--raw" ]]; then raw=1; shift; fi
[[ $# -eq 2 ]] || { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
player="$1"; cmd="$2"
[[ "$player" == "dev" ]] && player="$PLAYER_MAC"
echo "$cmd" | jq -e 'type == "array"' >/dev/null 2>&1 || die "command must be a JSON array, got: $cmd"
resp="$(rpc_raw "$player" "$cmd")" || die "no response from $LMS_RPC_URL (is LMS running? dev/start.sh)"
if [[ $raw -eq 1 ]]; then echo "$resp" | jq .; else echo "$resp" | jq '.result // .'; fi
