# VLC YouTube Prefetch Queue

Play a queue of YouTube videos in VLC, on Windows, without a browser tab and
without the buffering/audio-desync problems that come from streaming
high-resolution video live. Each video is fully downloaded to disk first,
then played back locally — which sidesteps the sync issues that show up when
VLC has to merge two live network streams (YouTube serves video and audio
separately at higher resolutions).

## How it works

Everything runs from one script, `vlc-queue.ps1`. Each time it runs, it checks
whether a VLC instance it launched is already listening on the RC port, and
picks a mode from that:

**VLC not running → fresh session**

1. Checks for a newer yt-dlp (at most once every 24 hours, via winget).
2. Deletes downloads older than the retention window (default 24 hours).
3. Downloads the first video in `queue.m3u` with
   [yt-dlp](https://github.com/yt-dlp/yt-dlp) and launches
   [VLC](https://www.videolan.org/vlc/) on it. If that video fails, it moves
   on to the next one until something succeeds.
4. Downloads the rest of the queue while that plays, enqueueing each finished
   file into VLC through its RC (remote control) interface, so playback never
   stops to wait.

**VLC running → add mode**

Append new URLs to `queue.m3u` and run the script again. It downloads only the
lines added since the last run and feeds them into the running VLC. Current
playback isn't interrupted. This works even while the first run is still
downloading.

Downloaded files are named by their line number in `queue.m3u`
(`001_Title.mp4`, `002_...`), so the two modes never collide.

## Prerequisites

- **Windows** with PowerShell (7.x recommended)
- **[VLC media player](https://www.videolan.org/vlc/)**. The default install
  path is assumed: `C:\Program Files\VideoLAN\VLC\vlc.exe`
- **[yt-dlp](https://github.com/yt-dlp/yt-dlp)** and **[ffmpeg](https://ffmpeg.org/)**
  on your PATH. ffmpeg is required: YouTube serves high-resolution video and
  audio separately, and ffmpeg merges them into a single mp4.

  ```powershell
  winget install --id yt-dlp.yt-dlp -e
  winget install --id Gyan.FFmpeg -e
  winget install --id VideoLAN.VLC -e
  ```

  Use the exact IDs. A bare `winget install yt-dlp` prompts you to choose
  between it and an unrelated Microsoft Store app. After installing, **close
  and reopen your terminal** (all of VS Code, if you use its terminal) so the
  new PATH is picked up.

The script checks for yt-dlp and ffmpeg on startup and stops with a clear
message if either is missing.

### Optional: browser cookies

Most videos download without signing in. Age-restricted videos, or a "Sign in
to confirm you're not a bot" error, need your YouTube cookies. The script
passes them to yt-dlp through `-CookieArgs` (see [Configuration](#configuration)).

- **Firefox and Firefox-based browsers (Zen, LibreWolf, etc.)** work reliably.
  For a fork, point yt-dlp at its profiles folder, e.g.
  `--cookies-from-browser firefox:$env:APPDATA\zen\Profiles`.
- **Chrome and Edge** generally don't work with `--cookies-from-browser` on
  Windows; their cookie encryption blocks yt-dlp. Export a `cookies.txt`
  with a browser extension instead and use `--cookies <path>`. Treat that file
  like a password, and keep it outside the download folder or the cleanup
  will delete it.
- Set `-CookieArgs ""` to turn cookies off entirely.

### Optional: Lua scripts for pasting links directly into VLC

`vlc-queue.ps1` doesn't need these; it hands VLC local files. They're only
useful if you also paste YouTube URLs straight into VLC.

- **`youtube.lua`**, from [FalloNero/yt-dlp4vlc](https://github.com/FalloNero/yt-dlp4vlc).
  Replaces VLC's built-in YouTube parser with one that asks yt-dlp for the
  stream URLs. Place it in `C:\Program Files\VideoLAN\VLC\lua\playlist\`.
  Streaming this way still has the buffering/desync problems described
  [below](#why-not-just-stream-it-live), and YouTube serves the highest bitrate
  available whether or not your connection can keep up.
- **`dkjson.lua`**, from [dkolf.de](https://dkolf.de/dkjson-lua/). VLC 3.x
  ships an old, buggy dkjson. FalloNero's `youtube.lua` doesn't use it, but
  JSON-based resolvers such as
  [mjasny/vlc-youtubeDL](https://github.com/mjasny/vlc-youtubeDL) do. Place it
  in `C:\Program Files\VideoLAN\VLC\lua\modules\`.

## Setup

1. Clone or download this repo.
2. Copy `queue.m3u.example` to `queue.m3u` and replace the sample URLs with
   your own, one per line. Lines starting with `#` are ignored.
3. If you get an "unsigned script" error the first time you run it, either
   unblock it or relax your execution policy:
   ```powershell
   Unblock-File .\vlc-queue.ps1
   # or, more permanently for your user account:
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```

## Usage

Start the queue:

```powershell
.\vlc-queue.ps1
```

Add more videos without interrupting what's playing: append URLs to
`queue.m3u`, then run the same command again.

```powershell
.\vlc-queue.ps1
```

Add mode only works with the VLC instance the script launched, because it
talks to it over the RC socket. A VLC you opened yourself doesn't have that
socket.

**To start over with a new list,** close VLC first, then edit `queue.m3u` and
run the script. If VLC is still open, the script assumes you're adding to the
current session.

## Configuration

The script accepts parameters, so you don't need to edit it:

| Parameter | Default | Purpose |
|---|---|---|
| `-UrlsFile` | `.\queue.m3u` | Playlist file to read |
| `-DownloadDir` | `D:\vlc_dump` | Where downloaded videos are stored |
| `-Quality` | `bestvideo[height<=2160]+bestaudio/best[height<=2160]` | yt-dlp format selector (4K cap by default) |
| `-RcPort` | `4212` | Local port for VLC's RC interface |
| `-VlcPath` | `C:\Program Files\VideoLAN\VLC\vlc.exe` | Path to vlc.exe |
| `-RetentionHours` | `24` | *(fresh session only)* Delete downloads older than this before starting |
| `-StateFile` | `<DownloadDir>\.queue_state` | Tracks how many lines of `queue.m3u` have been processed |
| `-CookieArgs` | `--cookies-from-browser firefox:$env:APPDATA\zen\Profiles` | Cookie options passed to yt-dlp; `""` to disable |

Example with a custom quality cap and download folder:

```powershell
.\vlc-queue.ps1 -DownloadDir "E:\queue" -Quality "bestvideo[height<=1080]+bestaudio/best[height<=1080]"
```

### Files the script creates

| File | Location | Purpose |
|---|---|---|
| `NNN_Title.mp4` | download folder | The downloaded videos |
| `yt-dlp.log` | download folder | yt-dlp's errors. **Check this first when a download fails.** |
| `.queue_state` | download folder | Line count for add mode. Kept by the cleanup. |
| `.ytdlp_last_update` | script folder | When yt-dlp was last updated. Ignored by git. |

## Why not just stream it live?

At 1080p and above, YouTube serves video and audio as two separate live
streams that VLC has to merge in real time. Any network jitter on either
stream causes drift between them. That's audio/video desync, and it's a
network/synchronization problem that more CPU or a bigger `network-caching`
buffer doesn't fully fix. Downloading first turns playback into local file
playback, where the problem doesn't exist.

## Known quirks / troubleshooting

Every failed download writes its reason to `yt-dlp.log` in the download
folder:

```powershell
Get-Content D:\vlc_dump\yt-dlp.log -Tail 30
```

- **`ffmpeg is not installed. The formats won't be merged`.** Install ffmpeg
  (see [Prerequisites](#prerequisites)), then delete any leftover
  `NNN_*.f###.*` fragment files from the download folder.
- **Installed ffmpeg/yt-dlp but the script still can't find it.** Your
  terminal has the old PATH. Restarting a terminal tab inside VS Code isn't
  enough; quit VS Code completely and reopen it. Or reload PATH in the current
  session:
  ```powershell
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
  ```
- **`could not find firefox cookies database`.** Firefox isn't installed, or
  you use a fork in a non-standard location. Point `-CookieArgs` at your
  browser's profiles folder, or set it to `""`. See
  [browser cookies](#optional-browser-cookies).
- **`nsig extraction failed` or `Requested format is not available`.** yt-dlp
  is out of date. The script updates it once a day, but the winget package
  can lag a release behind. Run `yt-dlp -U` to update immediately. If that
  doesn't help, run `where.exe yt-dlp`; an older copy may be earlier in your
  PATH than the one winget updates.
- **Some videos fail with `HTTP Error 403: Forbidden`.** Usually YouTube
  throttling a single extraction attempt, not a script bug. Failed downloads
  are listed at the end of each run but not retried automatically. Move the
  URL to the bottom of `queue.m3u` and run the script again to retry it.
- **`Start-Process` failing with "filename or extension is too long".** This
  happens when `-FilePath` is a bare command name (`vlc`) instead of a full
  path, because `Start-Process` doesn't resolve PATH the same way calling a
  command directly does. Use the full path to `vlc.exe`, as the script does by
  default.
- **VLC's RC interface console window.** VLC's `rc` interface normally opens a
  visible console for local interaction. The `--rc-quiet` flag (already
  included) suppresses it while keeping the RC socket open.

## License

MIT — see [LICENSE](LICENSE).
