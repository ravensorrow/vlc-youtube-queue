# VLC YouTube Prefetch Queue

Play a queue of YouTube videos in VLC, on Windows, without a browser tab and
without the buffering/audio-desync problems that come from streaming
high-resolution video live. Each video is fully downloaded to disk first,
then played back locally — which sidesteps the sync issues that show up when
VLC has to merge two live network streams (YouTube serves video and audio
separately at higher resolutions).

## How it works

1. `vlc-prefetch-playlist.ps1` downloads the first video in your queue with
   [yt-dlp](https://github.com/yt-dlp/yt-dlp), then launches VLC to play it
   locally.
2. While that plays, it downloads the rest of the queue in the background and
   enqueues each finished file into the already-running VLC instance via
   VLC's RC (remote control) interface — so playback never stops to wait.
3. `vlc-add-to-queue.ps1` lets you append more videos to the queue *while
   VLC is still playing*, without interrupting anything.
4. Old downloaded files are automatically cleaned up after a configurable
   retention window (default 24 hours).

## Prerequisites

- **Windows** with PowerShell (7.x recommended)
- **[VLC media player](https://www.videolan.org/vlc/)** — default install
  path assumed: `C:\Program Files\VideoLAN\VLC\vlc.exe`
- **[yt-dlp](https://github.com/yt-dlp/yt-dlp)** on your PATH:
  ```powershell
  winget install yt-dlp.yt-dlp
  ```
  (Use the exact ID above — a bare `winget install yt-dlp` will prompt you to
  disambiguate against an unrelated Microsoft Store app.)

## Setup

1. Clone or download this repo.
2. Copy `queue.m3u.example` to `queue.m3u` and replace the sample URLs with
   your own — one per line. Lines starting with `#` are ignored.
3. If you get an "unsigned script" error the first time you run a script,
   either unblock it or relax your execution policy:
   ```powershell
   Unblock-File .\vlc-prefetch-playlist.ps1
   # or, more permanently for your user account:
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```

## Usage

Start the queue:
```powershell
.\vlc-prefetch-playlist.ps1
```

Add more videos later, without interrupting what's playing — just append new
URLs to `queue.m3u`, then:
```powershell
.\vlc-add-to-queue.ps1
```
This only works while the VLC instance the first script launched is still
open, since it talks to it over a local RC socket.

## Configuration

Both scripts accept parameters instead of requiring you to edit the file:

| Parameter | Default | Purpose |
|---|---|---|
| `-UrlsFile` | `.\queue.m3u` | Playlist file to read |
| `-DownloadDir` | `D:\vlc_dump` | Where downloaded videos are stored |
| `-Quality` | `bestvideo[height<=2160]+bestaudio/best[height<=2160]` | yt-dlp format selector (4K cap by default) |
| `-RcPort` | `4212` | Local port for VLC's RC interface |
| `-VlcPath` | `C:\Program Files\VideoLAN\VLC\vlc.exe` | Path to vlc.exe |
| `-RetentionHours` | `24` | *(prefetch script only)* Delete downloaded files older than this before each run |

Example with a custom quality cap and download folder:
```powershell
.\vlc-prefetch-playlist.ps1 -DownloadDir "E:\queue" -Quality "bestvideo[height<=1080]+bestaudio/best[height<=1080]"
```

## Why not just stream it live?

At 1080p and above, YouTube serves video and audio as two separate live
streams that VLC has to merge in real time. Any network jitter on either
stream causes drift between them — that's audio/video desync, and it's a
network/synchronization problem, not something more CPU or a bigger
`network-caching` buffer fully fixes. Downloading first turns playback into
local file playback, where this problem doesn't exist.

## Known quirks / troubleshooting

- **Stale yt-dlp binary shadowing a newer one in PATH.** If downloads start
  failing with `nsig extraction failed` or `Requested format is not
  available`, run `where yt-dlp` (Command Prompt, not PowerShell) — you may
  have an old copy earlier in your PATH than a newer one you just installed.
  Update or remove the stale one.
- **`Start-Process` failing with "filename or extension is too long".** This
  happens when `-FilePath` is a bare command name (`vlc`) instead of a full
  path — `Start-Process` doesn't resolve PATH the same way calling a command
  directly does. Use the full path to `vlc.exe`, as this script does by
  default.
- **VLC's RC interface console window.** VLC's `rc` interface normally opens
  a visible console box for local interaction. The `--rc-quiet` flag (already
  included here) suppresses it while keeping the RC socket open.
- **Some individual videos fail with `HTTP Error 403: Forbidden`.** This is
  usually YouTube throttling a specific extraction attempt, not a script bug.
  It tends to succeed on a retry.

## License

MIT — see [LICENSE](LICENSE).
