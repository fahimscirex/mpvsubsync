# mpvsubsync

Automatic subtitle synchronization for [mpv](https://mpv.io/) — match misaligned subtitles to audio using [`ffsubsync`](https://github.com/smacke/ffsubsync) or [`alass`](https://github.com/kaegi/alass).

> Forked from [`joaquintorres/autosubsync-mpv`](https://github.com/joaquintorres/autosubsync-mpv) with substantial rework: async job manager, persistent cache, ASS progress bar, centered OSD menu, hardened parsers, and Windows/macOS support.

---

## Features

- **Two backends** — [ffsubsync](https://github.com/smacke/ffsubsync) (more accurate) or [alass](https://github.com/kaegi/alass) (faster). Pick per-mode, or be asked each time.
- **Async job manager** — non-blocking subprocess execution with stop, restart, and reset controls. The video keeps playing while sync runs in the background.
- **Persistent cache** — extracted audio and retimed subtitles live in a configurable cache directory and survive across mpv sessions. Same media + sub pair is re-synced from cache in milliseconds.
- **ASS progress bar** — determinate fill for audio extraction, animated indeterminate bar for retiming, with elapsed time and percentage badge. Renders centered over the video.
- **Auto-centered OSD menu** — semi-transparent backdrop, sizes to its content, readable over any video.
- **Fault-tolerant parsers** — handles non-standard SRT (mixed separators, optional spaces, trailing data) and malformed ASS entries without crashing.
- **Cross-platform** — Linux, macOS, Windows. Auto-discovers executables in PATH and common install locations.
- **Clean track list** — retimed sub loads as a track titled `retimed`. Reset removes it and switches back to your original. The original sub file on disk is never touched unless you explicitly save.
- **First-run config** — writes a default `script-opts/mpvsubsync.conf` the first time the script loads so the options are visible and editable.

---

## Installation

### Prerequisites

- **mpv** ≥ 0.33
- **FFmpeg** in `PATH`
- One retiming backend (or both):
  ```bash
  pip install ffsubsync          # recommended — better accuracy
  ```
  `alass` — [build from source](https://github.com/kaegi/alass), or `trizen -S alass-git` on Arch.

### Install

```bash
git clone https://github.com/fahimscirex/mpvsubsync ~/.config/mpv/scripts/mpvsubsync
```

| OS            | Scripts directory          |
| ------------- | -------------------------- |
| Linux / macOS | `~/.config/mpv/scripts/`   |
| Windows       | `%APPDATA%\mpv\scripts\`   |

---

## Usage

| Shortcut   | Action                |
| ---------- | --------------------- |
| `n`        | Open the mpvsubsync menu |
| `Ctrl + r` | Reset / cancel        |

You can also trigger reset from `input.conf` or another script:
```
script-message mpvsubsync-reset
```

### Menu navigation

| Key                              | Action          |
| -------------------------------- | --------------- |
| `j` / `k`, `↑` / `↓`, scroll     | Move selection  |
| `l`, `Enter`, left-click         | Confirm         |
| `h`, `ESC`, right-click, `n`     | Close           |

### Menu options

| Option                         | Description |
| ------------------------------ | ----------- |
| **Sync to audio**              | Retime the active sub against the audio track. Extracted audio is cached. |
| **Sync to another subtitle**   | Retime the active sub against a different loaded sub track (no audio extraction). |
| **Stop current sync**          | Cancel the running job. Visible only while a sync is in progress. |
| **Restart last sync**          | Re-run the previous sync. Wipes its cache first so the engine actually re-runs. |
| **Reset current sync/cache**   | Stop any running job. Remove the retimed sub from mpv's track list, switch back to the original, and delete the cached audio + retimed sub from disk. The original sub file is never deleted. |
| **Save current timings**       | Persist the current sub (retimed result and/or manual `z`/`x` delay shift) over the original file on disk. The original is preserved as `<name>.bak.<ext>` on the first save. |
| **Cancel**                     | Close the menu. |

---

## Configuration

The script writes a default config to `~/.config/mpv/script-opts/mpvsubsync.conf` on first load. Edit it directly, or delete it to regenerate.

```ini
# --- Backends (leave empty to auto-discover in PATH) ---
# ffmpeg_path=
# ffsubsync_path=
# alass_path=

# Preferred tool per mode: ffsubsync, alass, or ask
audio_subsync_tool=ask
altsub_subsync_tool=ask

# --- Caching ---
cache_enabled=yes
cache_dir=~/.cache/mpvsubsync/         # Linux/macOS default
# cache_dir=%LOCALAPPDATA%/mpvsubsync/cache/   # Windows default

# --- Performance ---
fast_stream_mode=no         # disable for best accuracy; enable for faster streaming
fast_stream_percent=30      # % of stream duration to extract in fast mode

# --- Debug ---
debug_logging=no
```

> On Windows, paths must use `/` or `\\`, e.g. `C:/Program Files/ffmpeg/bin/ffmpeg.exe`.

---

## How it works

1. Resolves the subtitle source: external file, internal track (extracted via ffmpeg), or remote stream.
2. Extracts the reference audio (`reference-<hash>.wav` in the cache dir; reused on subsequent runs against the same media).
3. Runs the chosen backend to produce the retimed sub (`retimed-<hash>.srt` in the cache dir).
4. Loads the retimed sub into mpv as a track titled `retimed`. Your original sub stays loaded alongside it.
5. The retimed sub stays as a cache file — it never lands next to your source sub on disk. Use **Save current timings** if you want to commit the result over the original (with a `.bak` backup).

---

## Credits

- Original project: [joaquintorres/autosubsync-mpv](https://github.com/joaquintorres/autosubsync-mpv)
- Earlier upstream maintainers: Ren Tatsumoto, nairyosangha, dyphire, and other contributors listed in the git history
- Sync engines: [ffsubsync](https://github.com/smacke/ffsubsync), [alass](https://github.com/kaegi/alass)
