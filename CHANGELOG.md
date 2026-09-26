# Changelog

All notable changes to the RTRFM plugin are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each version's section is
also the text of its GitHub Release (see [RELEASING.md](RELEASING.md)).

## [Unreleased]

## [1.0.0] - 2026-09-26

### Added

- Track lists: opening an episode shows **Play episode**, the episode notes (when there are any)
  and **Track list (N)**, one row per track with its approximate time into the show, for example
  `23:00 · Ella Fitzgerald & Louis Armstrong – Isn't This a Lovely Day`.
- Now Playing for **RTRFM 92.1 Live**: the show on air as the title, with its artwork, its time
  slot and the next show. It updates by itself about a minute after each show change. The song
  info menu has **Show info** with the show on air, its description and the next show.
- **RTRFM Infinite Mix** shows its name and the station logo in Now Playing instead of a blank
  title.
- **Programs** lists RTRFM's current line-up from rtrfm.com.au, with the station's program names,
  artwork and time slots. Shows that are no longer on air are left out. If rtrfm.com.au can't be
  reached, the list falls back to RTRFM's Airnet program guide.
- A program's page starts with its description, time slot and hosts, and its episodes use the
  show's artwork, in the menus and in Now Playing.
- Current track during episode playback: Now Playing shows the track playing at that point in
  the episode, from the track list's approximate times. It changes at each track boundary and
  straight after a seek. Song info for an episode has **Episode notes** and **Track list (N)**.
- Daily and weekday shows list every episode of the last 28 days, not just the last 11.
- Just-aired episodes are listed about 10 minutes after the show ends, before RTRFM's program
  guide has their details. Until the track list is published, the episode shows
  "Track list not yet available".
- Episodes whose audio RTRFM no longer has are left out of the list. If that check fails, the
  episode stays listed with "· Availability unknown".
- README: how to use every menu, what Now Playing shows and its limits, troubleshooting and
  compatibility, with screenshots.
- `scripts/smoke.sh`: a one-command acceptance test for a running LMS (see the README's
  Self-test section).
- `docs/official-repository.md`: how the plugin could later be listed in the official LMS plugin
  repository.
- This changelog. GitHub Releases now take their notes from it.

### Changed

- The release workflow's `repo.xml` commits are authored by the repository owner instead of
  `github-actions[bot]`.
- Opening today's episode no longer logs a warning when RTRFM's program guide has no track list
  for it yet (the expected HTTP 400 is now logged at debug level).

### Known limitations

- There are no track titles for the live streams: RTRFM doesn't publish what track is playing
  live, only the show.
- RTRFM keeps episode audio for 28 days. Older episodes aren't listed, and an older favourite
  shows "This episode is no longer available".
- A new episode's audio is available about 6 minutes after the show ends. Its details and track
  list come from RTRFM's Airnet program guide, which usually publishes them later, often the
  next day.
- The current track during an episode is based on approximate times, so it can change a little
  early or late.
- A daily show's older episodes are found from its regular weekly time slots. A weekday on
  which the show appeared only once in its recent episodes may not be listed for older weeks.
- The first time a program is opened it can take several seconds (up to about 12 s on a slow
  connection) while the show page loads and the episodes' audio is checked; after that it is
  cached for 24 hours.
- Tested on LMS 9.1 with the Default web skin and squeezelite. LMS 8.x, the Material skin and
  hardware players are expected to work but haven't been tested.

## [0.1.0] - 2026-09-26

### Added

- **RTRFM 92.1** in the LMS Radio menu, with **RTRFM 92.1 Live** (the FM simulcast) and
  **RTRFM Infinite Mix** (the second stream). The live item shows the show on air and the next
  show.
- **Programs**: RTRFM's programs from its Airnet program guide. Opening one lists its episodes
  from the last 28 days, newest first, named with their date and title.
- Episodes play, seek and can be saved as favourites, which keep working after a restart. When
  RTRFM has deleted an episode's audio, the player shows "This episode is no longer available".
- Installation from a repository URL in Settings → Manage Plugins, with automated releases.

[unreleased]: https://github.com/wilsonwaters/SqueezeRTRFM/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/wilsonwaters/SqueezeRTRFM/compare/v0.1.0...v1.0.0
[0.1.0]: https://github.com/wilsonwaters/SqueezeRTRFM/releases/tag/v0.1.0
