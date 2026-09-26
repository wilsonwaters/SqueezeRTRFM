# RUNBOOK: local LMS dev environment

This container runs a local **Lyrion Music Server 9.1.1** and a headless **squeezelite** player
called "DevPlayer". We use it to load the plugin straight from the repo, browse its menus
(web UI and JSON-RPC) and check that remote streams really play. The user's own LMS (pi14) can't
be reached from here, so this is our only runtime test bed.

## TL;DR

```bash
dev/setup.sh                      # one-time install (idempotent, re-run safe)
dev/start.sh                      # start egress-proxy + LMS + DevPlayer, wait until ready
dev/rpc.sh - '["players",0,10]'   # should list DevPlayer (00:00:00:00:00:01)
dev/link-plugin.sh --restart      # load <repo>/RTRFM into LMS (symlink), restart LMS
dev/restart-lms.sh                # reload plugin Perl code after edits
dev/logs.sh -n 50                 # last 50 lines of LMS server.log
dev/stop.sh                       # stop everything
```

Web UI: <http://localhost:9000/> · JSON-RPC: `http://localhost:9000/jsonrpc.js` · CLI port 9090.

## What is installed where

| Thing | Location / detail |
|---|---|
| LMS 9.1.1 (full "src" tarball, which bundles CPAN for every arch incl. perl 5.38 x86_64) | `/opt/lms-dev/lyrionmusicserver-9.1.1`, symlinked as `/opt/lms-dev/server` |
| Tarball cache | `/opt/lms-dev/dl/lyrionmusicserver-9.1.1.tgz` (md5 `11a05b8a79515fb4dfb303c5e0abc6e1`, from `latest.xml`) |
| LMS prefs / cache | `/opt/lms-dev/prefs` (`server.prefs`, `plugin/*.prefs`, `log.conf`), `/opt/lms-dev/cache` |
| PID files | `/opt/lms-dev/run/{lms,squeezelite,egress-proxy}.pid` |
| proxychains config (generated on every start) | `/opt/lms-dev/proxychains.conf` |
| Logs (git-ignored) | `<repo>/dev/logs/` (see [Logs](#logs-and-debugging)) |
| Plugin dev link | `/opt/lms-dev/server/Plugins/RTRFM -> <repo>/RTRFM` (created by `dev/link-plugin.sh`) |
| apt packages | `squeezelite` (1.9.9-1449), `proxychains4` (4.17), `pv`, `jq`, `libio-socket-ssl-perl`, `libnet-ssleay-perl` (LMS does not bundle the SSL modules) |
| Perl | system `/usr/bin/perl` 5.38 |
| Headless browser helper | `<repo>/dev/browser/` (`playwright@1.56.1`, pinned to match `/opt/pw-browsers/chromium-1194`) |

All settings live in `dev/common.sh` and can be overridden with environment variables
(`LMS_PORT`, `PLAYER_NAME`, `PLAYER_MAC`, `PLUGIN_SRC`, `LMS_EXTRA_ARGS`, ...).

LMS runs **in the foreground, not as a daemon**, detached with `setsid`, as root with `--user root`.
Without `--user root`, LMS refuses to run as root and switches to `nobody`, which can't write our
directories. Because of that it logs a harmless "must not be run as root" warning. The first-run
wizard is turned off: `start.sh` sets the `wizardDone` pref through JSON-RPC every time it runs.
LMS 9 needs no online account.

## Scripts (`dev/`)

| Script | Purpose |
|---|---|
| `setup.sh` | Installs apt packages, downloads, verifies and extracts LMS, creates dirs, runs `npm install` in `dev/browser`. Starts nothing. |
| `start.sh` | Starts `egress-proxy.mjs`, then LMS (wrapped in proxychains4), then squeezelite. Waits for JSON-RPC and for DevPlayer to connect. Idempotent: anything already running is left alone. |
| `stop.sh` | Stops squeezelite, LMS and egress-proxy. Uses SIGTERM, then SIGKILL, then sweeps each process group. |
| `restart-lms.sh` | Restarts LMS only, to reload plugin code. squeezelite reconnects by itself within a few seconds. |
| `rpc.sh` | `dev/rpc.sh [--raw] <playerid\|-\|dev> '<json array>'` prints `.result`. `dev` is short for DevPlayer's MAC. |
| `link-plugin.sh` | `[--restart] [--unlink] [src_dir [name]]` symlinks the plugin dir into `<LMS>/Plugins/<name>`. The default is `<repo>/RTRFM`. |
| `logs.sh` | `[server\|stdout\|squeezelite\|egress] [-n N] [-f\|--no-follow]`. Follows only when run on a TTY. |
| `egress-proxy.mjs` | The local CONNECT helper described below. Dev tooling only. |
| `common.sh` | Shared settings and functions, sourced by all the scripts. |

To run with extra LMS options, e.g. debug logging from startup:
`LMS_EXTRA_ARGS="--debug plugin.rtrfm=DEBUG" dev/restart-lms.sh`

## How outgoing network access works, and why

### What the sandbox allows (measured)

- **Direct TCP egress works, but it's transparently intercepted by an Envoy egress gateway.** TLS is
  re-terminated with the "Anthropic Egress Gateway" CA, and **every HTTP/1.0 request gets
  `426 Upgrade Required`**, over plain HTTP and over intercepted TLS alike.
- **LMS speaks HTTP/1.0 everywhere.** `Slim::Networking::Async::HTTP` forces 1.0, and
  `Slim::Player::Protocols::HTTP::requestString` hardcodes `HTTP/1.0`. squeezelite sends the request
  string LMS gives it. So with no proxy set up at all, LMS fails: 426 on every radio, update or
  metadata fetch. We saw this on the first start.
- **`$HTTPS_PROXY` CONNECT tunnels:**
  - Tunnels to **:443** carry TLS untouched. We saw the origin's real certificate, e.g. Cloudflare's,
    and HTTP/1.0 inside works.
  - Tunnels to **:80** are inspected. HTTP/1.0 gets a 426, and the proxy returns
    `403 Host header does not match CONNECT target` if you CONNECT to an IP and then send a
    hostname in `Host:`.
  - When a request is upgraded to HTTP/1.1, the gateway re-frames bodies of unknown length as
    `Transfer-Encoding: chunked`, which HTTP/1.0 clients can't parse.
  - Plain forward-proxy requests (`GET http://…` sent to the proxy) get 405.

### Options considered

- **LMS `webproxy` pref: rejected.** It only applies to `http://` URLs; `use_proxy` skips https.
  It sends plain forward-proxy requests, which the upstream proxy answers with 405. It also has a
  bug: with `webproxy` set, `crackURL` produces `GET http://host:443/path` request lines for
  **https** streams, sent inside TLS to the origin. **Keep `webproxy` empty.**
- **proxychains4 straight to `$HTTPS_PROXY`: not enough on its own.** HTTPS would work, but plain
  HTTP would still hit 426, and CONNECT-by-IP to :80 gets a 403.
- **Chosen: proxychains4 plus a local helper.** Both LMS and squeezelite run under `proxychains4`
  (LD_PRELOAD, which works with the system perl). Every non-local TCP `connect()` becomes a
  `CONNECT <ip>:<port>` sent to `dev/egress-proxy.mjs` on `127.0.0.1:3129`. The helper:
  1. Answers `200` straight away, so LMS's single-threaded event loop never blocks on remote connects.
  2. Sniffs the first bytes the client sends:
     - **TLS** (0x16): reads the SNI and opens an upstream tunnel to `<sni>:<port>` through
       `$HTTPS_PROXY`, then pipes the bytes through unchanged.
     - **HTTP**: parses the request and re-sends it as **HTTP/1.1** (`Connection: close`) through a
       tunnel to `<Host header>:<port>`. It **de-chunks** the response and returns it without a
       length, closing the connection to mark the end, which HTTP/1.0 clients understand. `Range`,
       `Icy-MetaData` and all other end-to-end headers pass through.
     - **Anything else**: a raw tunnel.

  If `$HTTPS_PROXY` isn't set, the helper connects directly instead.
- **DNS:** `proxy_dns` is deliberately **off**. LMS resolves names itself through
  `AnyEvent::DNS`, IPv4 only. Fake proxychains IPs would break direct streaming, because LMS passes
  the resolved IP to squeezelite. The helper recovers the hostname from SNI or the Host header.
- **TLS verification stays on** (`insecureHTTPS: 0`). The Ubuntu `IO::Socket::SSL` uses the system
  trust store, which includes the Anthropic proxy and gateway CAs, and :443 tunnels carry the real
  certificates anyway.
- The proxychains `localnet` entries exclude 127/8, the RFC1918 ranges and the container's own IPs
  (`hostname -I`). So LMS can still reach local services, e.g. a local `repo.xml` server.

The helper logs one line per connection to `dev/logs/egress-proxy.log`. It's the quickest way to see
what LMS and the plugin are fetching, and whether any fetch failed.

## Audio output (squeezelite)

There's no sound card: no `/dev/snd`, and `snd-dummy` can't be loaded. The ALSA `null` device
doesn't keep real time either: 10 s of audio "played" in 6 ms, which would make LMS's elapsed time
meaningless. So squeezelite runs like this:

```
proxychains4 … squeezelite -n DevPlayer -m 00:00:00:00:00:01 -s 127.0.0.1 -o - -a 16 \
    -r 44100-44100 -u mX -Z 192000 -d all=info -f dev/logs/squeezelite.log | pv -q -L 176400 >/dev/null
```

- `-o - -a 16` writes 16-bit PCM to stdout.
- `-r 44100-44100 -u mX` allows only 44.1 kHz output and async-resamples everything to it. A
  48 kHz stream is logged as `resampling from 48000 -> 44100`.
- `pv -L 176400` throttles the pipe to exactly real time (44100 × 2 ch × 2 bytes).
- `-Z 192000` makes squeezelite still advertise a realistic max sample rate. Without it, LMS rejects
  48 kHz streams such as RTRFM's HE-AAC with "Unsupported sample-rate" / "Couldn't create command line".

Measured: over 12.17 s of wall clock, LMS `time` advanced 12.17 s on RTRFM stream1.

### Direct versus proxied streaming

LMS's default is **direct streaming**: squeezelite fetches the stream URL itself, using the IP LMS
resolved. squeezelite is also under proxychains, so this works for both http and https. Both modes
have been tested with https and plain http streams. To make LMS fetch the stream and relay it to the
player instead:

```bash
dev/rpc.sh dev '["playerpref","mp3StreamingMethod","1"]'   # 1 = proxied via LMS
dev/rpc.sh dev '["playerpref","mp3StreamingMethod","0"]'   # back to default (direct)
```

To see which mode was used, look at `dev/logs/squeezelite.log`. You'll see either
`connecting to 127.0.0.1:9000` + `GET /stream.mp3?player=…` (proxied), or
`connecting to <remote ip>:<port>` (direct).

## Loading the plugin under development

On Unix, LMS scans `<LMS>/Plugins/` (`$Bin/Plugins`, from `Slim::Utils::OS::Unix::dirsFor`) for
`install.xml`. `File::Next` follows symlinks and `$Bin` is on `@INC`, so a symlink named after the
namespace is enough. LMS then reads the code straight from the repo working tree:

```bash
dev/link-plugin.sh --restart      # /opt/lms-dev/server/Plugins/RTRFM -> /home/user/SqueezeRTRFM/RTRFM
# ...edit RTRFM/*.pm...
dev/restart-lms.sh                # Perl code is only loaded at startup
dev/link-plugin.sh --unlink       # remove the dev link
```

- The name under `Plugins/` must match the namespace: `Plugins::RTRFM::Plugin` means `Plugins/RTRFM`.
- New plugins default to **enabled**. Check with `dev/rpc.sh - '["pref","plugin.state:RTRFM","?"]'`.
- The plugin manifest cache (`/opt/lms-dev/cache/plugin-data.yaml`) is rebuilt automatically when
  the number of `install.xml` files or their mtimes change.
- `--restart` also prints `server.log` lines mentioning the plugin since the restart. Load errors show
  up as `Couldn't load RTRFM` / perl compile errors in `server.log`, with `lms-stdout.log` as a backup.
- **Don't** also install the plugin through the Extension Manager: a copy in
  `/opt/lms-dev/cache/InstalledPlugins/Plugins/RTRFM` would clash, and `link-plugin.sh` warns about it.
- **Logging gotcha:** a brand-new log category only gets its level after LMS re-inits logging, which
  happens after the plugins have loaded. So `warn`/`info`/`debug` calls made **during `initPlugin`**
  are dropped, and only `error` gets through. Messages logged later, from callbacks and requests,
  appear normally. To see init-time logs, start LMS with the category preset:
  `LMS_EXTRA_ARGS="--debug plugin.rtrfm=DEBUG" dev/restart-lms.sh` (verified).
- Verified with a throwaway `Plugins::DevProbe` plugin, kept in a scratch dir outside the repo and
  since deleted along with its leftover state pref. It loaded from the symlink, and its OPML menu
  showed in the web UI and in `["apps",0,50]`. `["devprobe","items",0,10]` returned its items, and
  `["devprobe","playlist","play","item_id:<id>"]` played an http stream. `SimpleAsyncHTTP` fetches
  from plugin code worked: `https://rtrfm.com.au/` returned 200 (431 KB) and `http://example.com/`
  returned 200.

### Testing the "install from repository" flow (not yet tried)

Serve the build output locally, e.g. `python3 -m http.server 8765 --bind 127.0.0.1 -d dist`. Then
add `http://127.0.0.1:8765/repo.xml` under *Settings → Manage Plugins → Additional Repositories*.
Run `dev/link-plugin.sh --unlink` first so the two copies don't clash. Downloaded zips are extracted
into `/opt/lms-dev/cache/InstalledPlugins/Plugins/` on the next restart.

## JSON-RPC cheat sheet

```bash
dev/rpc.sh - '["serverstatus",0,10]'                         # version, player count
dev/rpc.sh - '["players",0,10]'                              # list players
dev/rpc.sh dev '["playlist","play","https://ice1.somafm.com/groovesalad-128-mp3"]'
dev/rpc.sh dev '["status","-",1,"tags:aluKo"]'               # mode/time/current_title/remoteMeta
dev/rpc.sh dev '["stop"]'        # also: ["pause"], ["power",0|1], ["mixer","volume",50]
dev/rpc.sh dev '["playlist","clear"]'
dev/rpc.sh - '["apps",0,50]'                                 # plugin menus under My Apps
dev/rpc.sh - '["radios",0,50]'                               # plugin menus under Radio
dev/rpc.sh dev '["rtrfm","items",0,50]'                      # the plugin's OPML top level (tag = rtrfm)
dev/rpc.sh dev '["rtrfm","items",0,50,"item_id:<id>"]'      # drill down
dev/rpc.sh dev '["rtrfm","playlist","play","item_id:<id>"]'  # play an OPML item
dev/rpc.sh - '["debug","plugin.rtrfm","DEBUG"]'              # runtime log level (see gotcha above)
dev/rpc.sh - '["pref","wizardDone","?"]'                     # read/write server prefs
```

Raw curl equivalent:
`curl -s -H 'Content-Type: application/json' -d '{"id":1,"method":"slim.request","params":["00:00:00:00:00:01",["status","-",1]]}' http://localhost:9000/jsonrpc.js`

A small playback check. `time` should grow by about 3 s per sample while `mode` stays `play`:

```bash
dev/rpc.sh dev '["playlist","play","https://live.rtrfm.com.au/stream1"]' >/dev/null
for i in 1 2 3 4; do sleep 3; dev/rpc.sh dev '["status","-",1]' | jq -c '{mode,time,current_title}'; done
```

## Headless browser screenshots

```bash
node dev/browser/screenshot.mjs http://localhost:9000/ /tmp/lms.png [--full] [--wait-ms 3000] [--width 1280 --height 900]
# prints {"url","status","title","out","pageErrors"}; works from any cwd
```

It uses the Chromium in `$PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers`. **Never run
`playwright install`.** If you ever bump the playwright version, it has to match the installed
`chromium-1194`, which means playwright 1.56.x.

The Default skin is at `/`. Material skin is **not** installed (it's a third-party plugin), so
`/material/` returns 404. Plugin OPML menus appear in the Default skin under *My Apps* or *Radio*,
depending on the `menu`/`is_app` settings. Deep links such as
`http://localhost:9000/plugins/RTRFM/settings/basic.html` also work once the plugin exists.

## Logs and debugging

| Log | What |
|---|---|
| `dev/logs/server.log` | Main LMS log (`dev/logs.sh`) |
| `dev/logs/lms-stdout.log` | LMS stdout/stderr (perl warnings, startup failures) (`dev/logs.sh stdout`) |
| `dev/logs/squeezelite.log` | squeezelite at info level: stream connects, headers, resampling (`dev/logs.sh squeezelite`) |
| `dev/logs/egress-proxy.log` | Every outbound connection LMS/squeezelite makes, with status codes (`dev/logs.sh egress`) |
| `dev/logs/perfmon.log` | LMS perf monitor (usually empty) |

For more detail from LMS subsystems:
`dev/rpc.sh - '["debug","player.streaming.remote","DEBUG"]'`, or `player.source` (transcoding
decisions), `network.asynchttp`, `plugin.rtrfm`. Set them back to `WARN` afterwards. Set
`EGRESS_DEBUG=1` before `start.sh` for more detail from the helper.

## Known limitations and gotchas

- **Processes don't survive a container restart.** Run `dev/start.sh` again. If `/opt/lms-dev` is
  gone (fresh container), run `dev/setup.sh` first; it re-downloads about 118 MB.
- `start.sh` must run in an environment where `$HTTPS_PROXY` is set, because the helper reads it at
  startup. Without it the helper connects directly: plain HTTP still works thanks to the 1.1 upgrade,
  but HTTPS then hits the intercepting gateway's 426.
- The helper handles one HTTP request per tunnel (`Connection: close`). That's fine for LMS; there's
  no HTTP/2 and no WebSockets. The upstream proxy may block TLS on ports other than 443. Plain HTTP
  on other ports worked (e.g. `http://ice2.somafm.com:8080/…`).
- proxychains does its CONNECT handshake with the local helper synchronously inside `connect()`.
  That's harmless because the helper replies at once, but a hung helper would freeze LMS. If LMS
  seems frozen, check `dev/logs.sh egress` and restart with `dev/stop.sh && dev/start.sh`.
- Don't set LMS's `webproxy` pref (see above). Leave `insecureHTTPS` at 0 so we test with real
  certificate checks, like a user's server.
- LMS runs as root (`--user root`). It's fine for this sandbox, but it isn't how users run it.
- Audio is discarded, so we can prove streams decode and advance in real time but can't judge audio
  quality. Output is always resampled to 44.1 kHz/16-bit; squeezelite reports 192 kHz max to LMS.
- The media library is empty (no music folder). The "Fulltext index missing" lines in `server.log`
  are normal.
- On startup LMS contacts `lyrion.org`, `lms-community.github.io`, `api.lms-community.org` and
  `opml.radiotime.com` (TuneIn) through the helper. That's normal and all of them work.

## Verification record (2026-09-26)

- `dev/rpc.sh - '["players",0,10]'` returns DevPlayer `00:00:00:00:00:01`, connected, model squeezelite.
- HTTPS MP3, `https://ice1.somafm.com/groovesalad-128-mp3`:
  `03:24:10 {"mode":"play","time":0.96,…"type":"MP3 Radio"}` →
  `03:24:15 {"mode":"play","time":6.02}` → `03:24:20 {"mode":"play","time":11.11}`.
- Plain HTTP MP3, `http://ice1.somafm.com/dronezone-128-mp3`: played in both direct and proxied
  modes, with time advancing about 3 s per 3 s.
- RTRFM live `https://live.rtrfm.com.au/stream1` (HE-AAC, 48 kHz): played with time advancing
  exactly in step with wall clock.
- `server.log` had no errors after the proxy setup. Before it, LMS got 426 on every outbound request.
- Throwaway plugin loaded from the symlink, played, fetched HTTPS/HTTP, and was then removed.
- Headless Chromium screenshot of `http://localhost:9000/` returned 200, title "Lyrion Music Server",
  with DevPlayer selected and no wizard.

## Sharing the test bed between agents

There is exactly one LMS + DevPlayer. Any agent that re-links the plugin, restarts LMS or plays audio must hold the
test-bed lock, and must run the dev scripts from the **main checkout** (`/home/user/SqueezeRTRFM/dev/…`) so logs/pids
resolve to the running instance, pointing `PLUGIN_SRC` at its own worktree:

```bash
/home/user/SqueezeRTRFM/dev/testbed-lock.sh acquire <TASK-ID>          # waits (default 30 min) if busy
PLUGIN_SRC=<worktree>/RTRFM /home/user/SqueezeRTRFM/dev/link-plugin.sh --restart
# ... runtime checks via dev/rpc.sh, dev/browser/screenshot.mjs, dev/logs.sh ...
/home/user/SqueezeRTRFM/dev/rpc.sh 00:00:00:00:00:01 '["stop"]'
/home/user/SqueezeRTRFM/dev/link-plugin.sh --restart                   # back to the main checkout
/home/user/SqueezeRTRFM/dev/testbed-lock.sh release <TASK-ID>
```

Stale locks (> 60 min) are broken automatically. Keep lock hold times short.
