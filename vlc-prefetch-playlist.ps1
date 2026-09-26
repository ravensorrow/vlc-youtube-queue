<#
    vlc-prefetch-playlist.ps1

    Downloads YouTube videos (via yt-dlp) fully to disk before playback,
    eliminating live-stream buffering/desync issues. Starts VLC as soon as
    the first video is ready, then downloads the rest in the background and
    enqueues each one into the already-running VLC instance as it finishes.

    USAGE:
      1. Put your YouTube URLs, one per line, in a file named queue.m3u
         next to this script (or pass -UrlsFile to point elsewhere).
      2. Run: .\vlc-prefetch-playlist.ps1
#>

param(
    [string]$UrlsFile   = "$PSScriptRoot\queue.m3u",
    [string]$DownloadDir = "D:\vlc_dump",
    [string]$Quality    = "bestvideo[height<=2160]+bestaudio/best[height<=2160]",
    [int]$RcPort        = 4212,
    [string]$VlcPath    = "C:\Program Files\VideoLAN\VLC\vlc.exe",
    [int]$RetentionHours = 24
)

if (-not (Test-Path $UrlsFile)) {
    Write-Error "URL list not found: $UrlsFile"
    exit 1
}

New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null

# --- Cleanup: remove downloaded files older than the retention window ---
$cutoff = (Get-Date).AddHours(-$RetentionHours)
$oldFiles = Get-ChildItem -Path $DownloadDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cutoff }

if ($oldFiles) {
    Write-Host "Cleaning up $($oldFiles.Count) file(s) older than $RetentionHours hours..."
    $oldFiles | Remove-Item -Force -ErrorAction SilentlyContinue
}

$urls = Get-Content $UrlsFile | Where-Object { $_.Trim() -ne "" -and -not $_.Trim().StartsWith("#") }

if ($urls.Count -eq 0) {
    Write-Error "No URLs found in $UrlsFile"
    exit 1
}

function Download-Video {
    param([string]$Url, [int]$Index)

    $prefix = "{0:D3}" -f $Index
    $outTemplate = Join-Path $DownloadDir "$prefix`_%(title)s.%(ext)s"

    & yt-dlp -f $Quality --merge-output-format mp4 -o $outTemplate $Url *> $null

    # Return the path to whatever file was actually created for this index
    $result = Get-ChildItem -Path $DownloadDir -Filter "$prefix`_*" |
        Select-Object -First 1 -ExpandProperty FullName

    if ($result) {
        Write-Host "  -> Done: $result"
    } else {
        Write-Host "  -> Download failed for $Url"
    }

    return $result
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
    } catch {
        Write-Warning "Could not reach VLC RC interface on port $RcPort. Is VLC still running?"
    }
}

# --- Step 1: download the first video and wait for it ---
Write-Host "Downloading video 1 of $($urls.Count)..."
$firstFile = Download-Video -Url $urls[0] -Index 1

if (-not $firstFile) {
    Write-Error "First download failed - nothing to play."
    exit 1
}

# --- Step 2: launch VLC on the first file, with the RC control interface enabled ---
Write-Host "Starting VLC..."
Start-Process -FilePath $VlcPath -ArgumentList @(
    "`"$firstFile`"",
    "--extraintf", "rc",
    "--rc-host", "localhost:$RcPort",
    "--rc-quiet"
)

Start-Sleep -Seconds 3   # give VLC a moment to open the RC socket

# --- Step 3: download the rest in the background, enqueuing each as it finishes ---
for ($i = 1; $i -lt $urls.Count; $i++) {
    $n = $i + 1
    Write-Host "Downloading video $n of $($urls.Count)..."
    $file = Download-Video -Url $urls[$i] -Index $n

    if ($file) {
        Send-RcCommand "enqueue `"$file`""
        Write-Host "Queued: $file"
    } else {
        Write-Warning "Skipping video $n - download failed."
    }
}

Write-Host "`nAll videos downloaded and queued in VLC."
