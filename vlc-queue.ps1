<#
    vlc-queue.ps1

    One script for both jobs. It decides what to do by checking whether
    VLC's RC interface is answering on $RcPort:

      VLC NOT running -> fresh session
        Updates yt-dlp (once per 24h), cleans downloads older than
        $RetentionHours, downloads the first URL, launches VLC on it, then
        downloads and enqueues the rest as each one finishes.

      VLC running -> add mode
        Downloads only the lines added to queue.m3u since the last run and
        enqueues them. Current playback is untouched.

    USAGE:
      1. Put YouTube URLs, one per line, in queue.m3u next to this script.
      2. Run: .\vlc-queue.ps1
      3. To add more while VLC is playing, append URLs to queue.m3u and
         run it again (even while the first run is still downloading).
      To start over with a new list, close VLC first.
#>

param(
    [string]$UrlsFile       = "$PSScriptRoot\queue.m3u",
    [string]$DownloadDir    = "D:\vlc_dump",
    [string]$Quality        = "bestvideo[height<=2160]+bestaudio/best[height<=2160]",
    [int]$RcPort            = 4212,
    [string]$VlcPath        = "C:\Program Files\VideoLAN\VLC\vlc.exe",
    [int]$RetentionHours    = 24,
    [string]$StateFile      = "$DownloadDir\.queue_state",
    [string]$CookieArgs     = "--cookies-from-browser firefox:$env:APPDATA\zen\Profiles"   # "" to disable
)

# --- Dependencies ---
foreach ($tool in 'yt-dlp','ffmpeg') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Error "$tool not found on PATH. Install it (winget) and reopen the terminal."
        exit 1
    }
}

if (-not (Test-Path $UrlsFile)) {
    Write-Error "URL list not found: $UrlsFile"
    exit 1
}

New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
$logFile = Join-Path $DownloadDir "yt-dlp.log"

# ---------------------------------------------------------------- functions

function Test-VlcRunning {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.ConnectAsync("localhost", $RcPort).Wait(500)
    } catch {
        $false
    } finally {
        $client.Close()
    }
}

function Save-Video {
    param([string]$Url, [int]$Index)

    $prefix      = "{0:D3}" -f $Index
    $outTemplate = Join-Path $DownloadDir "$prefix`_%(title)s.%(ext)s"

    # yt-dlp prints the final merged file path; errors go to the log
    $result = & yt-dlp -f $Quality --merge-output-format mp4 -o $outTemplate `
        --restrict-filenames --no-simulate --print after_move:filepath `
        $(if ($CookieArgs) { $CookieArgs -split ' ' }) $Url 2>> $logFile |
        Select-Object -Last 1

    if ($result -and (Test-Path -LiteralPath $result)) {
        Write-Host "  -> Done: $result"
        return $result
    }

    Write-Host "  -> Download failed for $Url (see $logFile)"
    return $null
}

function Send-RcCommand {
    param([string]$Command)

    try {
        $client = New-Object System.Net.Sockets.TcpClient("localhost", $RcPort)
        $stream = $client.GetStream()
        $writer = New-Object System.IO.StreamWriter($stream)
        $writer.AutoFlush = $true
        $writer.WriteLine($Command)
        Start-Sleep -Milliseconds 200
        $writer.Close()
        $client.Close()
        return $true
    } catch {
        Write-Warning "Could not reach VLC RC interface on port $RcPort. Is VLC still running?"
        return $false
    }
}

# --------------------------------------------------------------------- main

$urls = @(Get-Content $UrlsFile | Where-Object { $_.Trim() -ne "" -and -not $_.Trim().StartsWith("#") })

if ($urls.Count -eq 0) {
    Write-Error "No URLs found in $UrlsFile"
    exit 1
}

$failed = @()

if (Test-VlcRunning) {
    # ============================ ADD MODE ============================
    $processed = 0
    if (Test-Path $StateFile) {
        $raw = (Get-Content $StateFile -Raw).Trim()
        if ($raw -match '^\d+$') { $processed = [int]$raw }
    }

    if ($urls.Count -le $processed) {
        Write-Host "VLC is running and there are no new URLs in $UrlsFile."
        exit 0
    }

    # Claim these lines up front so an overlapping run won't grab them too
    Set-Content -Path $StateFile -Value $urls.Count

    Write-Host "VLC is running -- adding $($urls.Count - $processed) new URL(s)."
    $start = $processed
}
else {
    # =========================== FRESH MODE ===========================

    # Keep yt-dlp current (at most once per 24h; never fatal).
    # Fresh mode only: in add mode another run may be using yt-dlp.exe.
    $stamp = Join-Path $PSScriptRoot ".ytdlp_last_update"
    if (-not (Test-Path $stamp) -or (Get-Item $stamp).LastWriteTime -lt (Get-Date).AddHours(-24)) {
        Write-Host "Checking for yt-dlp updates..."
        winget upgrade --id yt-dlp.yt-dlp -e --silent `
            --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Host
        Set-Content -Path $stamp -Value (Get-Date -Format o)
    }

    # Remove downloads older than the retention window (dotfiles are kept)
    $cutoff = (Get-Date).AddHours(-$RetentionHours)
    $oldFiles = Get-ChildItem -Path $DownloadDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff -and -not $_.Name.StartsWith('.') }

    if ($oldFiles) {
        Write-Host "Cleaning up $($oldFiles.Count) file(s) older than $RetentionHours hours..."
        $oldFiles | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    Set-Content -Path $StateFile -Value $urls.Count

    # Download until one succeeds, then start VLC on it
    $firstFile = $null
    $start = 0
    while (-not $firstFile -and $start -lt $urls.Count) {
        $n = $start + 1
        Write-Host "Downloading video $n of $($urls.Count)..."
        $firstFile = Save-Video -Url $urls[$start] -Index $n
        if (-not $firstFile) { $failed += $urls[$start] }
        $start++
    }

    if (-not $firstFile) {
        Write-Error "Every download failed - nothing to play. See $logFile"
        exit 1
    }

    Write-Host "Starting VLC..."
    Start-Process -FilePath $VlcPath -ArgumentList @(
        "`"$firstFile`"",
        "--extraintf", "rc",
        "--rc-host", "localhost:$RcPort",
        "--rc-quiet"
    )

    Start-Sleep -Seconds 3   # give VLC a moment to open the RC socket
}

# ---------------------- download + enqueue the rest (both modes) ----------------------
# File prefix = the URL's line position in queue.m3u, so numbering never collides.
for ($i = $start; $i -lt $urls.Count; $i++) {
    $n = $i + 1
    Write-Host "Downloading video $n of $($urls.Count)..."
    $file = Save-Video -Url $urls[$i] -Index $n

    if ($file) {
        if (Send-RcCommand "enqueue `"$file`"") {
            Write-Host "  -> Queued"
        }
    } else {
        $failed += $urls[$i]
    }
}

if ($failed.Count -gt 0) {
    Write-Warning "$($failed.Count) download(s) failed and won't be retried automatically:"
    $failed | ForEach-Object { Write-Host "  $_" }
}

Write-Host "`nDone."
