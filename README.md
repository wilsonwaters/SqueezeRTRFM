# SqueezeRTRFM

A [Lyrion Music Server](https://lyrion.org/) (LMS, formerly Logitech Media Server) plugin for
[RTRFM 92.1](https://rtrfm.com.au/), Perth's independent community radio station.

## About

The plugin adds **RTRFM 92.1** to the LMS Radio menu. Inside it, **RTRFM 92.1 Live** plays
the station's live stream (the FM simulcast) on your Squeezebox players.

On-demand programs and episode track lists are in development.

## Disclaimer

This is an **unofficial** plugin. It is **not affiliated with RTRFM** or endorsed by the
station. The RTRFM name and logo belong to RTRFM 92.1; they are used here only to identify
the station. For the station itself, visit <https://rtrfm.com.au/>.

## Requirements

- Lyrion Music Server (or Logitech Media Server) **8.0 or later**. Tested on LMS 9.1.x.

## Installation

1. In the LMS web interface, open **Settings → Manage Plugins** and scroll down to
   **Additional Repositories**.
2. Paste this URL into the empty field and click **Save**:

   ```
   https://raw.githubusercontent.com/wilsonwaters/SqueezeRTRFM/main/repo.xml
   ```

3. A new section, **SqueezeRTRFM plugin repository**, appears in the plugin list. Tick
   **RTRFM 92.1** and click **Save** (or **Apply**).
4. LMS downloads the plugin, checks it, and asks you to restart. Restart LMS when prompted.
5. Open **Radio → RTRFM 92.1** on any player or in the web interface.

## Updating

When a new version is released, **Settings → Manage Plugins** shows an update notice for
RTRFM 92.1: tick it, save, and restart LMS. If you have turned on automatic plugin updates
on that page, LMS installs new versions by itself and only needs a restart.

## Uninstalling

1. In **Settings → Manage Plugins**, untick **RTRFM 92.1** and click **Save** (or **Apply**).
2. Restart LMS when prompted.
3. Optionally, delete the repository URL from **Additional Repositories** and save again.

## Manual installation

If your server can't use the repository (for example, it has no internet access):

1. Download `RTRFM-<version>.zip` from the
   [Releases page](https://github.com/wilsonwaters/SqueezeRTRFM/releases).
2. Create a folder named `RTRFM` in your LMS `Plugins` folder and extract the zip into it,
   so that `install.xml` ends up at `Plugins/RTRFM/install.xml`. Common locations:
   - Debian, Ubuntu and Raspberry Pi OS packages: `/usr/share/squeezeboxserver/Plugins/`
   - Red Hat, Fedora and similar packages: `/usr/share/lyrionmusicserver/Plugins/`
   - Docker (official image) and piCorePlayer: the `Plugins` folder in the LMS cache folder,
     e.g. `/config/cache/Plugins/` in Docker

   **Settings → Information** lists your server's plugin folders.
3. Restart LMS.

Don't install the plugin both manually and from the repository: remove the manual copy
first if you switch to the repository.

## Development

- `scripts/check.sh` runs every check: compile check, unit tests (`prove`), XML validation,
  strings lint, package checks and shellcheck. CI runs the same script on every pull request.
- `scripts/build.sh` builds `dist/RTRFM-<version>.zip` and its `.sha1` from `RTRFM/`.
- `scripts/lms-repo-install.sh` installs the plugin on an LMS from a repository URL without a
  browser (used for testing).
- Releases are automated: see [RELEASING.md](RELEASING.md).

## License

[Apache License 2.0](LICENSE).
