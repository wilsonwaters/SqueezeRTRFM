# RTRFM 92.1 — how the site delivers audio and metadata (research notes)

Researched 2026-09-26 (Perth time ~11:00 AWST, Saturday). Every URL below was tried with curl from a server-side context, with no JS execution.
Perth is UTC+8 with no DST. All station-side times are **Australia/Perth local time**.

---

## 1. Summary and recommended approach for a server-side Perl plugin

| Capability | Best source | Format | Verified |
|---|---|---|---|
| Live stream (main FM simulcast) | `https://live.rtrfm.com.au/stream1` | SHOUTcast 2.5 / AAC+ (ADTS), 64 kbps, 24 kHz core | yes |
| Second stream "RTRFM – Infinite Mix" (RTR2 mixes) | `https://live.rtrfm.com.au/stream2` | SHOUTcast / AAC+ (ADTS), 96 kbps | yes |
| Now playing (current + next **show**) | `GET https://rtrfm.com.au/wp-admin/admin-ajax.php?action=get_current_and_next_show` | JSON | yes |
| Now playing (current **track**) | **None available.** ICY StreamTitle and SHOUTcast `songtitle` are empty, and Airnet has no playlist for the current day until later | — | shown not to exist |
| Program list | **Airnet** `https://airnet.org.au/rest/stations/6RTR/programs` (JSON). Enrich from WP `filter_shows` (HTML fragment in JSON) or the show page for images, descriptions and schedule | JSON / HTML | yes |
| Schedule per show | WP `https://rtrfm.com.au/wp-json/rtrfm/v1/show-times/{postId}` (JSON), or infer it from Airnet episode start times | JSON | yes |
| Episode list per show | Airnet `.../programs/{slug}/episodes` (JSON, **last 11 episodes only**, no paging). Keep only those inside the **28-day audio window** | JSON | yes |
| Episode audio (MP3) | `GET https://restreams.rtrfm.com.au/rzz?n={slug}&d={YYYY-MM-DD}` returns `{"u":"<signed mp3 url>"}` | JSON, then MP3 | yes |
| Tracklist per episode | Airnet `.../programs/{slug}/episodes/{YYYY-MM-DD}+{HH}%3A{MM}%3A00/playlists` (JSON). The fallback is WP `get_episode` (HTML fragment) | JSON | yes |

**Recommended strategy**

1. **Live:** play `https://live.rtrfm.com.au/stream1` (HTTPS, HTTP/1.1 is fine). It is AAC. LMS must decode AAC or transcode it (faad) for players without native AAC. Do not rely on ICY metadata, because it is always empty. Build the title and artwork by polling `get_current_and_next_show` (current show name, time slot, thumbnail). The JS polls again at `next.startTime`, and retries every 30 s on error or every 5 min when there is no `next`.
2. **Program menu:** `GET airnet .../programs`. Keep entries with a non-null `slug` and `archived == false`. For friendlier data, use WP `filter_shows` (4 pages × 12 = 47 current shows, with image, weekday/time text, hosts and genres), or intersect the Airnet list with the slugs from WP `filter_shows` / `show-sitemap.xml` so you only show shows that are currently on air.
3. **Episodes:** `GET airnet .../programs/{slug}/episodes` gives the last 11 episodes (start, end, duration, title, HTML description). Keep only `start` ≥ today − 28 days, because older audio is gone. Daily shows (Breakfast, Drivetime, OTL, Full Frequency, On The Record run Mon–Fri) have more episodes in the 28-day window than Airnet's 11. Fill the gap by generating dates from the weekly slot (from `show-times` or earlier Airnet starts), or accept about 2 weeks for those shows.
4. **Play an episode:** resolve lazily, just before playback, with `rzz?n={slug}&d={date}`. If the returned `u` ends in `.mp3?`, it exists. If it ends in `.mp4?`, the episode is **not available** (that URL 404s). The MP3 is 128 kbps CBR, 48 kHz, supports byte ranges, and has Content-Length, so LMS can seek. The `e=` expiry is set to now + 10 s but in practice **was not enforced** (still 206 after 7 minutes). The `st=` hash **is** enforced.
5. **Tracklist:** Airnet `playlists` JSON for the episode. Use `approximateTime` (full `YYYY-MM-DD HH:MM:SS`, 24 h). **Do not use `time`**, which is 12-hour with no am/pm, e.g. `05:01:00` for 5:01 pm. Offset into the MP3 = `approximateTime − episode.start` in seconds. This is exactly what the site does (`play(180)` for a track at 09:03 in a 09:00 show).
6. **HTTP client:** do **not** send a `libwww-perl/...` User-Agent. Cloudflare returns **403** for it on rtrfm.com.au and airnet.org.au. LMS's standard UA (`iTunes/4.7.1 … Logitech Media Server/…`), `Lyrion Music Server/x`, or an empty UA all work.

---

## 2. Platform

- **rtrfm.com.au**: WordPress 7.x behind Cloudflare. The custom theme is `startdigital` (agency "Start Digital"). The frontend uses Alpine.js, Swup page transitions, Howler.js for audio and GSAP, all in one bundle at `/wp-content/themes/startdigital/static/site.js?ver=…` (~430 KB).
  - The theme's dynamic data comes from **`/wp-admin/admin-ajax.php`** actions: `get_current_and_next_show`, `get_episode`, `filter_shows`, `filter_posts`, `filter_podcasts`, `filter_podcast_episodes`, `filter_mixes`, `filter_videos`, `filter_business`, `search_playlists`, `load_more_past_events`, `load_more_previous_weeks_featured`. Most return JSON that **wraps rendered HTML fragments**.
  - WP REST (`/wp-json/`) does **not** expose the `show` custom post type. The only custom namespace is `rtrfm/v1` with `GET /show-times/{id}` (read-only JSON) and `GET /update-show-times`. I did not call `update-show-times` because it looks like a cron trigger with side effects.
  - Yoast sitemaps: `/show-sitemap.xml` (67 URLs: base show pages plus per-weekday sub-pages such as `/shows/drivetime/monday/`), `/presenter-sitemap.xml`, `/podcast-sitemap.xml`, and others.
  - Podcasts (`/podcasts/…`) and "mixes" are separate content (Mixcloud/SoundCloud embeds). `/podcasts/feed/` is RSS with **no enclosures**. They are out of scope for show on-demand.
- **Program, episode and playlist data**: the **CBAA Airnet** platform (`airnet.org.au`, the community radio "radiopages" backend, station callsign **6RTR**). It is a public, unauthenticated REST JSON API (PHP 5.6 behind Cloudflare, `cache-control: max-age=300, public`). The WP server itself proxies Airnet: `get_episode` returns Airnet fields plus `url: https://6RTR.radiopages.info/...`, and that radiopages URL 404s.
- **Audio**:
  - Live: SHOUTcast DNAS v2.5.5.733 behind nginx 1.21 at `live.rtrfm.com.au` (2 streams).
  - On demand ("restreams"): nginx 1.14 at `restreams.rtrfm.com.au`, serving static MP3s protected by nginx `secure_link` (`st` = md5 token, `e` = expiry).
- Airnet's own audio features are disabled for 6RTR: `channels/fm` returns `enableAudioServer:false, enableOnDemandRecording:false, liveStreamUrl:null`. Airnet has **no audio URLs**.

---

## 3. Live streams

| Name (site label) | URL | Codec / container | Bitrate | Sample rate | ICY metaint | StreamTitle | Notes |
|---|---|---|---|---|---|---|---|
| RTRFM 92.1 live (FM simulcast) | `https://live.rtrfm.com.au/stream1` | `audio/aacp`, raw ADTS AAC (LC core, likely SBR/HE-AAC) | 64 kbps (measured 63.9) | 24000 Hz core, stereo | 16384 (when `Icy-MetaData: 1` is sent) | **always empty** | `icy-genre: Alternative`, `icy-name` empty |
| RTRFM – Infinite Mix (RTR2) | `https://live.rtrfm.com.au/stream2` | `audio/aacp`, ADTS AAC | 96 kbps | 24000 Hz | 16384 | **always empty** | `icy-genre: Misc` |
| same, plain HTTP port 80 | `http://live.rtrfm.com.au/stream1` (`/stream2`) | same | same | same | same | empty | works (tested over a CONNECT tunnel) |
| same, port 8000 (from PLS) | `http://live.rtrfm.com.au:8000/stream1` (`/stream2`) | — | — | — | — | — | listed in `https://live.rtrfm.com.au/listen.pls?sid=1` / `sid=2`. **Not testable here** (the proxy only allows 443/80) |

- HTTPS works (valid cert, HTTP/2 or HTTP/1.1). HTTP/1.1 responses use `Transfer-Encoding: chunked`, because nginx fronts SHOUTcast. `Accept-Ranges: none`, `Access-Control-Allow-Origin: *`, `Cache-Control: no-cache,no-store`.
- There is a burst on connect: about 20 s of audio arrives in the first ~6 s.
- No auth, referer or UA requirement: `libwww-perl` UA, empty UA and LMS UA all returned 200 on `live.` and `restreams.`.
- **SHOUTcast status endpoints** are public on the same host:
  - `https://live.rtrfm.com.au/statistics?json=1` (both streams: listeners, bitrate, samplerate, `songtitle` (empty), `streampath`, `streamstatus`)
  - `https://live.rtrfm.com.au/stats?sid=1&json=1`
  - `/currentsong?sid=1` (empty body)
  - `/played?sid=1&type=json` (`[]`)
  - `/7.html`
  - These confirm that **no track metadata is ever pushed** to the encoder.
- The site has a "streams down" kill switch: the homepage inline JS has `var startdigital_settings = {"streamsDown":""}`. When it is non-empty, the site shows "OUR LIVESTREAM IS DOWN" instead of playing. It can be scraped from any page's HTML if wanted.
- `get_current_and_next_show` also returns `"stream_url":"https://live.rtrfm.com.au/stream1"`. That is a good way to pick up any future URL change.

---

## 4. Now playing API

### 4a. Current and next show (works)

`GET https://rtrfm.com.au/wp-admin/admin-ajax.php?action=get_current_and_next_show` (POST also works). Response: `application/json`, no-cache.

```json
{"success":true,"data":{
  "current":{"time":"9.00am - 11.00am","name":"Saturday Jazz","startTime":"2026-09-26T09:00:00+08:00",
             "link":"https://rtrfm.com.au/shows/saturdayjazz/",
             "thumbnail":"https://rtrfm.com.au/wp-content/uploads/2012/12/SaturdayJazz.jpg","day":""},
  "next":{"time":"11.00am - 1.00pm","name":"Global Rhythm Pot","startTime":"2026-09-26T11:00:00+08:00","link":"…","thumbnail":"…","day":""},
  "stream_url":"https://live.rtrfm.com.au/stream1",
  "current_show":{"name":"Saturday Jazz","slug":"saturdayjazz","url":"…",
     "short_description":"Encompassing everything from classic traditional jazz to the genre's newest innovations.",
     "friendly_days":"Saturdays","friendly_times":"9.00am - 11.00am",
     "start_time":"2026-09-26T09:00:00+08:00","end_time":"2026-09-26T11:00:00+08:00"},
  "next_show":{ …same shape… }}}
```

- `current_show.slug` is the key that works with Airnet and `rzz`. For weekday shows, `day` is probably filled (e.g. "Monday"); it was `""` for a Saturday show.
- Browser polling logic, from site.js: when `data.current` is missing, retry in 30 s. Otherwise schedule a switch at `next.startTime`, then re-poll 1–6 min after it. Without `next`, re-poll in 5 min.

### 4b. Current track: NOT AVAILABLE

What I tried:
- ICY in-band metadata on both streams: every metadata block had length 0.
- SHOUTcast `songtitle`, `currentsong` and `played` history: all empty.
- The site's JS and HTML have no now-playing-track UI or endpoint (no "now playing", "last played" or similar anywhere).
- Airnet 404 routes: `/rest/stations/6RTR/nowplaying`, `/onair`, `/guides/fm/onair`, `/guides/fm/nowplaying`, `/channels/fm/nowplaying`, `/channels/fm/playlist`.
- `guides/fm` returns `[]`.
- Airnet episode for **today** returns `400 {"message":"No such episode"}`, even after the show ended (today's Saturday Jazz and the currently airing Global Rhythm Pot). Airnet episodes for a date seem to appear only later, probably in an overnight batch. Yesterday's episodes, including the Friday 23:00 show, were present.

So showing the live track in real time is not possible. The best available is show-level metadata.

---

## 5. Programs API

### 5a. Airnet program list (primary, JSON)

`GET https://airnet.org.au/rest/stations/6RTR/programs` returns an array of 86 entries (79 with non-null slug, including `archived:true` historical shows and junk entries like "Add Show Name Here").

```json
[{"slug":"saturdayjazz","name":"Saturday Jazz","broadcasters":"Ben Bartholomew, …","gridDescription":null,"archived":false,
  "programRestUrl":"https://airnet.org.au/rest/stations/6RTR/programs/saturdayjazz"}, …]
```

`GET https://airnet.org.au/rest/stations/6RTR/programs/{slug}`:

```json
{"url":null,"guideUrlOverride":null,"name":"Saturday Jazz","broadcasters":"Ben Bartholomew, Bridget Cleary, …",
 "description":null,"gridDescription":null,"twitterHandle":null,"podcastUrl":null,"podcastUrl2":null,
 "defaultFirstAiredGuide":"fm","slug":"saturdayjazz","bannerImageUrl":null,"bannerImageSmall":null,
 "profileImageUrl":null,"profileImageSmall":null,"facebookPage":null,
 "episodesRestUrl":"https://airnet.org.au/rest/stations/6RTR/programs/saturdayjazz/episodes"}
```

Airnet descriptions and images are mostly **null** for RTRFM. Use WP for images and descriptions. Name strings can contain HTML entities (`Black &amp; Blue`), so decode them. Some names are odd (`getupmorning` is called "GRP"), and the WP names are better.

Other station routes: `/rest/stations/6RTR` (station info), `/rest/stations/6RTR/channels`, `/rest/stations/6RTR/channels/fm`, `/rest/stations/6RTR/guides/fm` (empty `[]`).

### 5b. WP show list (current line-up with images, JSON wrapping HTML)

`POST https://rtrfm.com.au/wp-admin/admin-ajax.php` with form body `action=filter_shows&search=&postTypes[]=show&page={1..4}`

Response: `{"success":true,"data":{"items":"<html…>","postsPerPage":12}}`. The HTML contains `data-total-posts="47"`, and page 5 is empty. Each `div.tease-show` has:
- `a href="https://rtrfm.com.au/shows/{slug}/"`
- `img srcset="https://rtrfm.com.au/wp-content/uploads/…jpg 2000w, …-300x169.jpg 300w, …-768x432.jpg 768w, …"` (16:9 images)
- `<h5>` name
- a span with `"Fridays 11.00pm - 1.00am"` (or `"Weekdays …"` style text)
- "Hosted by:" `span.font-mono` names (max 4 plus a "+ N" span)
- genre chips (`span.midnight-border`, e.g. "Beats", "Hip Hop")

The 47 current slugs: allcity allthingsqueer ambientzone artbeat basscheck behindthemirror blackandblue breakfast burntheairwaves cloudwaves criticalmass difficultlistening drastic drivetime elritmo fullfrequency getupmorning giantsteps globalrhythmpot goldenapples homegrown indymedia jamdown looneychoons middleofnowhere moorditjmag ontherecord otl peer2peer pluckedstrings posted revolver rhythmtrippin rockrattle roots saturdayjazz siamesedream snoozebutton soulsides spoonful subterranea sundaymorning therounds training trainwreck uplate woodstock. (`training` is "Demo Playlists", so filter it out.)

### 5c. Show page (description, image, schedule, post id)

`GET https://rtrfm.com.au/shows/{slug}/` (multi-day shows also have `/shows/{slug}/{weekday}/`):
- `<body class="… postid-299 …">` gives the post id for `show-times`.
- `<meta property="og:image" content="https://rtrfm.com.au/wp-content/uploads/2012/12/SaturdayJazz.jpg">` (1920×1080).
- `<div class="post-description …">` contains the HTML description paragraphs.
- `<span class="supertitle no-brackets">Saturdays 9.00am - 11.00am</span>` and `<h1 class="is-h2">Saturday Jazz</h1>`.
- `<section x-data="restream" data-name="Saturday Jazz" data-slug="saturdayjazz" data-full-slug="" data-date="2026-09-19" data-duration="7200">` gives the latest episode date. The prev/next buttons carry `data-date`. The latest episode's tracklist HTML is embedded server-side.
- Multi-day example: `data-name="Drivetime (Monday)" data-slug="drivetime" data-full-slug="drivetime/monday"`. **The audio and Airnet slug is `data-slug` (`drivetime`), never the full slug.**

### 5d. Schedule JSON

`GET https://rtrfm.com.au/wp-json/rtrfm/v1/show-times/{postId}` returns the **next** occurrence(s):

```json
[{"fullShowName":"Saturday Jazz","shortShowName":"Saturday Jazz","startTimeIsoString":"2026-10-03T09:00:00+08:00",
  "endTimeIsoString":"2026-10-03T11:00:00+08:00","startTime":"9am","gridDayOfWeek":"Saturday","realDayOfWeek":"Saturday","durationMinutes":120}]
```

The parent post of a multi-day show returns one entry per weekday. For example, drivetime post 105054 returns Mon–Fri 17:00, and the Monday sub-post 105085 returns only Monday. `gridDayOfWeek` and `realDayOfWeek` differ for after-midnight slots.

The weekly grid is also at `https://rtrfm.com.au/program-guide/` (HTML; the `<li style="grid-row: a / b">` positions are awkward to parse, so prefer `show-times`).

---

## 6. Episodes API

### 6a. Airnet episode list

`GET https://airnet.org.au/rest/stations/6RTR/programs/{slug}/episodes`
- Returns the **last 11 episodes**, oldest first, **no paging**. `page`, `limit`, `count`, `offset`, `from/to`, `start/end`, `before`, `numEpisodes` and `perPage` were all ignored.
- Episodes only appear the day after airing. Today's episode was missing, while yesterday's evening shows were present.
- Weekly show: 11 weeks back (saturdayjazz 2026-07-11 … 2026-09-19). Weekday show: about 2 weeks (drivetime 2026-09-11 … 2026-09-25).

```json
[{"url":null,"start":"2026-09-19 09:00:00","end":"2026-09-19 11:00:00","duration":7200,"multipleEpsOnDay":false,
  "title":"Saturday Jazz with Laura Igglesden","description":"<p>Hosted by …</p>\n","imageUrl":null,"smallImageUrl":null,
  "episodeRestUrl":"https://airnet.org.au/rest/stations/6RTR/programs/saturdayjazz/episodes/2026-09-19+09%3A00%3A00"}]
```

`title` is often null, so fall back to "{Show} – {Day DD Mon}". `description` is HTML, often "Presented by X".

`GET …/episodes/{YYYY-MM-DD}+{HH}%3A{MM}%3A{SS}` (a single episode; this works for **old** episodes too, e.g. 2025-09-20):

```json
{"notes":"<p>…</p>","start":"2026-09-25 06:00:00","end":"2026-09-25 09:00:00","duration":10800,"url":null,"title":null,
 "imageUrl":null,"smallImageUrl":null,"playlistRestUrl":"…/episodes/2026-09-25+06%3A00%3A00/playlists"}
```

An unknown episode returns `400 {"message":"No such episode"}`.

### 6b. On-demand audio ("restreams"): the audio source

`GET https://restreams.rtrfm.com.au/rzz?n={slug}&d={YYYY-MM-DD}` returns `Content-Type: application/javascript`, body JSON:

```json
{"u":"https://restreams.rtrfm.com.au/shows/saturdayjazz_2026-09-19.mp3?st=KQyf5pVDjk6Ybv1y3uqTYA&e=1790391804"}
```

- The file is **one MP3 per episode**, named `shows/{slug}_{YYYY-MM-DD}.mp3`, where the date is the **Perth calendar date of the episode start**. For example, Up Late starting 01:00 on 2026-09-25 is `uplate_2026-09-25`, and All City Fri 23:00 is `allcity_2026-09-25`. It is not chunked by hour: a 3-hour show is one 172.8 MB file.
- **Availability:**
  - rzz always returns 200 JSON, even for an unknown slug.
  - When the MP3 does not exist, `u` points to `…_{date}.mp4?…`, which returns **404**. Treat a non-`.mp3` URL as "no audio".
  - The retention window is **28 days**. Checked on 2026-09-26: 2026-08-29 exists and 2026-08-22 does not (`.mp4` 404).
  - A new episode appears about **6 minutes after the show ends** (Saturday Jazz ended 11:00 and its file Last-Modified was 11:06 AWST).
- **Signing:** `st` is an nginx secure_link md5. A wrong `st`, a missing `st`, a missing `e`, or a changed `e` all return **403**. `e` = request time + ~10 s, but an "expired" URL still returned 206 seven minutes later, so the expiry is not enforced right now. Still, **resolve via rzz right before handing the URL to the player**, and re-resolve if you get a 403.
- Multiple episodes of one show on the same date (`multipleEpsOnDay`) cannot be addressed by rzz, which takes a date only. This is unverified because none were seen.
- The WP theme has another "episode" endpoint that wraps Airnet with extra flags:
  `POST https://rtrfm.com.au/wp-admin/admin-ajax.php` with body `action=get_episode&slug={slug}&date={YYYY-MM-DD}`

  ```json
  {"success":true,"data":{"hasNoAudio":false,"slug":"saturdayjazz",
    "pagination":{"current":"2026-09-19","prev":"2026-09-12","next":"2026-09-26"},
    "episode":{"notes":null,"start":"2026-09-19 09:00:00","end":"2026-09-19 11:00:00","earlierEpisodes":[],"laterEpisodes":[],
               "url":"https://6RTR.radiopages.info/saturdayjazz/2026-09-19","firstAiredGuide":"fm",
               "title":"Saturday Jazz with Laura Igglesden","imageUrl":null,"smallImageUrl":null,"dayOfWeek":"Saturday",
               "friendlyDate":"19th September","friendlyTime":"9am","duration":7200,"isRemoved":false},
    "notes":null,"startTime":"2026-09-19 09:00:00","endTime":"2026-09-19 11:00:00","isOnAir":false,
    "tracklist":"<div …>…</div>"}}
  ```

  - `hasNoAudio` is true outside the 28-day window.
  - `pagination.prev/next` step by a week, even for weekday shows.
  - **Caveat:** for a date with no episode (today, a wrong weekday), it returns the *nearest older* episode's data with `episode.start` = the requested date. The site's JS only trusts it when `date(startTime) == pagination.current`, and the plugin must apply the same check.
  - Unknown slug: `{"success":true,"data":[]}`.

**Recommended episode enumeration:** take Airnet `episodes` (metadata), keep `start` within the last 28 days (excluding today until the MP3 exists), then resolve with rzz on play. For weekday shows, add dates computed from the weekday slots going back 28 days (from `show-times` or earlier Airnet starts). Optionally check each with rzz and keep only those where `u` contains `.mp3?`. That is one cheap request each, and a HEAD on the MP3 is not needed.

---

## 7. Tracklists API

### 7a. Airnet playlist JSON (recommended)

`GET https://airnet.org.au/rest/stations/6RTR/programs/{slug}/episodes/{YYYY-MM-DD}+{HH}%3A{MM}%3A00/playlists` returns an array ordered by time. Only `type:"track"` items were seen across 6 episodes.

```json
[{"type":"track","id":11145135,"artist":"Chris Foster","title":"Looking Sideways","track":"Looking Sideways",
  "release":"In Motion","time":"09:03:00","notes":null,"twitterHandle":null,
  "contentDescriptors":{"isAustralian":true,"isLocal":true,"isFemale":false,"isGenderNonConforming":false,"isIndigenous":false,"isNew":null},
  "wikipedia":null,"image":null,"video":null,"url":null,
  "approximateTime":"2026-09-19 09:03:00",
  "testing":{"date":"2026-09-19 09:03:00.000000","timezone_type":3,"timezone":"Australia/Perth"},"thispart":"yeah"}]
```

- Fields: `artist`, `title` (= `track`), `release` (album, often null), `approximateTime` (Perth local, minute precision), and `contentDescriptors` (flags such as `isLocal`, which the site shows as a "WA" badge).
- **`time` is 12-hour without am/pm** (Drivetime 17:01 shows as `"05:01:00"`), so always use `approximateTime`.
- Offset in the MP3 = `approximateTime − episode.start`. Timestamps are entered by presenters and are approximate.
- Playlists are available for old episodes too (tested 2025-09-20), well beyond the 28-day audio window.
- Typical size is 15–35 tracks per episode.

### 7b. WP HTML tracklist (fallback)

This is `data.tracklist` from `get_episode` above, or embedded in the show page. It is a repeated block:

```html
<div x-data="{ id: $id('restream') }" …>
  <button aria-label="Play" … @click="play(180, id)">…</button>   <!-- 180 = offset seconds into MP3 -->
  <span> 00:03 </span>                                            <!-- HH:MM offset from start -->
  <div class="flex flex-col gap-0.5"><div …><span class="font-medium line-clamp-1">Looking Sideways</span>
      <span class="font-bold text-xs px-3 rounded-full border …">WA</span></div>
    <span class="text-sm">Chris Foster</span></div>
</div>
```

The regex-friendly parts are `play\((\d+)`, the title in `span.font-medium`, and the artist in `span.text-sm`. There is no album.

### 7c. Global track search (optional)

`POST admin-ajax.php` with body `action=search_playlists&query={text}` returns `{"success":true,"data":"<html>"}`. The HTML lists "Track | Show (Weekday), YYYY-MM-DD | Artist" across roughly the last 6+ months.

---

## 8. Audio file characteristics

### Episode MP3 (restreams)
- Resolved URL: `https://restreams.rtrfm.com.au/shows/saturdayjazz_2026-09-19.mp3?st=…&e=…`. There is **no redirect**; rzz returns the final URL directly.
- `HTTP/1.1 200` / `206`, `Server: nginx/1.14.0 (Ubuntu)`, `Content-Type: audio/mpeg`, `Content-Length: 115201065` (2 h), `Accept-Ranges: bytes`. `Range: bytes=0-1023` returns `206` with `Content-Range: bytes 0-1023/115201065`.
- Also sent: `ETag`, `Last-Modified` (≈ show end + 6 min), `Cache-Control: max-age=31536000`, `Expires` +1 year. HEAD works.
- Encoding: ID3v2.3 header (TSSE "LAME 32bits version 3.99.5", `TLEN=7200000` ms, empty TIT2/TPE1/TYER), then an Info (CBR Xing) frame. **MPEG-1 Layer III, 128 kbps CBR, 48 kHz, joint stereo.** Size ≈ duration × 16000 bytes, so 2 h = 115.2 MB and 3 h = 172.8 MB. Seek byte ≈ 16000 × seconds (+ ~1 KB of header).
- No referer, cookie or UA requirement (`libwww-perl` UA also worked here). Without `st` and `e`: 403.

### Live stream
- `https://live.rtrfm.com.au/stream1`: no redirect, `200`, `Server: nginx/1.21.0`, `Content-Type: audio/aacp`, `icy-br: 64`, `icy-sr: 24000`, `icy-metaint: 16384` (only when `Icy-MetaData: 1` is sent), `Accept-Ranges: none`, chunked over HTTP/1.1, and no Content-Length.
- The payload is ADTS AAC, profile LC, 24 kHz, stereo, measured 63.9 kbps over 481 frames. `file(1)`: "MPEG ADTS, AAC, v2 LC, 24 kHz, stereo". It is advertised as `aacp`, so expect HE-AAC with implicit SBR (48 kHz output).
- `stream2`: the same, but at 96 kbps.

---

## 9. Caveats and unknowns

- **Live track metadata:** does not exist (see §4b). Only show-level now-playing is possible.
- **Airnet current-day episodes:** today's episodes (even ones that finished) are missing from Airnet and give "No such episode" until later. The exact publish time is unknown; it looks like an overnight job. The MP3 is available ~6 min after the show ends, so a "just aired" episode can be played before its metadata and tracklist exist. Synthesise the metadata from the schedule.
- **Airnet list depth:** fixed at 11 episodes with no paging. Daily shows need date synthesis to cover the full 28-day audio window.
- **Signed URL expiry:** `e` is not enforced today but could be turned on. Resolve just in time and handle 403 by re-resolving. If LMS re-requests the same URL with a Range header to seek after 10 s, it might break if enforcement is enabled later.
- **Multiple episodes per day** (`multipleEpsOnDay`): rzz is keyed by slug and date only. How a second same-day episode is named is unknown.
- **Chunked live stream:** HTTPS/HTTP/1.1 delivery is `Transfer-Encoding: chunked`. Check that the LMS HTTP(S) protocol handler de-chunks it; recent LMS versions do. Port 8000 plain HTTP from the PLS could not be tested (proxy restriction). It is presumably the raw SHOUTcast port without chunking.
- **Cloudflare UA filter:** `User-Agent: libwww-perl/*` returns 403 on rtrfm.com.au and airnet.org.au. `Mozilla/5.0 libwww-perl`, `Perl LWP`, empty, and LMS UAs return 200. No rate limiting was seen with 12 quick requests (all 200). WP admin-ajax responses are `no-store` (uncached, hitting PHP each time), so cache on the plugin side: programs about daily, episodes about hourly, now-playing until `next.startTime`. Airnet sends `max-age=300`.
- **Robots and ToS:** `robots.txt` allows everything (`Disallow:` empty) and lists the Yoast sitemap. I found no public API terms. Airnet and admin-ajax are undocumented, unofficial interfaces and may change, especially the theme's HTML fragments. Be polite: low request rates, caching, and a descriptive UA. `rzz` and the restream files are what the official web player uses.
- **Browser capture:** a Playwright/Chromium network capture was attempted but failed with `ERR_CERT_AUTHORITY_INVALID` (the sandbox's TLS-intercepting proxy is not trusted by that Chromium build), and I did not bypass TLS verification. All endpoints were instead taken from the site JS bundle (`site.js`) and inline HTML, then verified with curl. The bundle covers every player path (livestream, infiniteMix, restream, audio, mixcloud), so this is unlikely to have missed a live-audio endpoint.
- The `rtrfm/v1/update-show-times` REST route was deliberately not called because it may have side effects.

---

## 10. Appendix: example requests (all verified 2026-09-26)

```sh
# --- Live
curl -sS -D - -o /dev/null --max-time 5 -H 'Icy-MetaData: 1' https://live.rtrfm.com.au/stream1
curl -sS https://live.rtrfm.com.au/statistics?json=1
curl -sS "https://live.rtrfm.com.au/listen.pls?sid=1"
#   [playlist] File1=http://live.rtrfm.com.au:8000/stream1 ...

# --- Now playing (show)
curl -sS "https://rtrfm.com.au/wp-admin/admin-ajax.php?action=get_current_and_next_show"

# --- Programs
curl -sS https://airnet.org.au/rest/stations/6RTR/programs
curl -sS https://airnet.org.au/rest/stations/6RTR/programs/saturdayjazz
curl -sS -X POST https://rtrfm.com.au/wp-admin/admin-ajax.php -d 'action=filter_shows&search=&postTypes[]=show&page=1'
curl -sS https://rtrfm.com.au/wp-json/rtrfm/v1/show-times/299          # 299 = saturdayjazz (body class postid-299)
curl -sS https://rtrfm.com.au/show-sitemap.xml

# --- Episodes
curl -sS https://airnet.org.au/rest/stations/6RTR/programs/saturdayjazz/episodes
curl -sS "https://airnet.org.au/rest/stations/6RTR/programs/saturdayjazz/episodes/2026-09-19+09%3A00%3A00"
curl -sS -X POST https://rtrfm.com.au/wp-admin/admin-ajax.php -d 'action=get_episode&slug=saturdayjazz&date=2026-09-19'

# --- Episode audio
curl -sS "https://restreams.rtrfm.com.au/rzz?n=saturdayjazz&d=2026-09-19"
#   {"u":"https://restreams.rtrfm.com.au/shows/saturdayjazz_2026-09-19.mp3?st=KQyf5pVDjk6Ybv1y3uqTYA&e=1790391804"}
curl -sS -D - -r 0-1023 -o head.bin "<u from above>"
#   HTTP/1.1 206 Partial Content / Content-Type: audio/mpeg / Content-Range: bytes 0-1023/115201065 / Accept-Ranges: bytes
curl -sS "https://restreams.rtrfm.com.au/rzz?n=saturdayjazz&d=2026-08-22"
#   {"u":"https://restreams.rtrfm.com.au/shows/saturdayjazz_2026-08-22.mp4?st=…"}   -> 404 (outside 28-day window)

# --- Tracklist
curl -sS "https://airnet.org.au/rest/stations/6RTR/programs/saturdayjazz/episodes/2026-09-19+09%3A00%3A00/playlists"
curl -sS -X POST https://rtrfm.com.au/wp-admin/admin-ajax.php --data-urlencode 'action=search_playlists' --data-urlencode 'query=Joni Mitchell'
```

Trimmed samples:

```text
# live headers (stream1)
HTTP/2 200 | server: nginx/1.21.0 | content-type: audio/aacp | icy-br: 64 | icy-sr: 24000 | icy-metaint: 16384
icy-genre: Alternative | icy-url: http://www.rtrfm.com.au | accept-ranges: none | access-control-allow-origin: *

# statistics?json=1 (trimmed)
{"totalstreams":2,"streams":[{"id":1,"streampath":"/stream1","bitrate":"64","samplerate":"24000","content":"audio/aacp","songtitle":"","currentlisteners":98},
                             {"id":2,"streampath":"/stream2","bitrate":"96","samplerate":"24000","content":"audio/aacp","songtitle":""}]}

# airnet channels/fm
{"enableAudioServer":false,"enableOnDemandRecording":false,"liveStreamUrl":null,"browserLiveStreamUrl":null,"browserReplayUrlTemplate":null,"replaySourceUrl":null}

# filter_shows (trimmed)
{"success":true,"data":{"postsPerPage":12,"items":"<div data-tease-loop data-posts-per-page=\"12\" data-total-posts=\"47\" data-page=\"1\"> <div class=\"tease-show\"><a href=\"https://rtrfm.com.au/shows/allcity/\"> <img srcset=\"https://rtrfm.com.au/wp-content/uploads/2012/12/all-city-banner-1-edit_.jpg 2000w, …-300x169.jpg 300w …\"> <h5>All City</h5> <span>Fridays 11.00pm - 1.00am</span> … <span class=\"font-mono\">Connor Kiss</span> … <span class=\"midnight-border …\">Beats</span> …"}}

# show-times (drivetime parent, trimmed)
[{"fullShowName":"Drivetime (Monday)","shortShowName":"Drivetime","startTimeIsoString":"2026-09-28T17:00:00+08:00","endTimeIsoString":"2026-09-28T19:00:00+08:00","gridDayOfWeek":"Monday","realDayOfWeek":"Monday","durationMinutes":120},
 {"fullShowName":"Drivetime (Tuesday)", … }]
```
