<#
    vlc-add-to-queue.ps1

    Run this any time while vlc-prefetch-playlist.ps1's VLC instance is still
    open. It detects lines you've added to queue.m3u since the last run,
    downloads just those new videos, and enqueues them into the already-
    running VLC via its RC interface -- current playback is untouched.

    USAGE:
      1. Add new YouTube URLs to the bottom of queue.m3u.
      2. Run: .\vlc-add-to-queue.ps1
#>

param(
    [string]$UrlsFile    = "$PSScriptRoot\queue.m3u",
    [string]$DownloadDir = "D:\vlc_dump",
    [string]$Quality     = "bestvideo[height<=2160]+bestaudio/best[height<=2160]",
    [int]$RcPort         = 4212,
    [string]$StateFile   = "$DownloadDir\.queue_state"
)

if (-not (Test-Path $UrlsFile)) {
    Write-Error "URL list not found: $UrlsFile"
    exit 1
}

New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null

$allUrls = Get-Content $UrlsFile | Where-Object { $_.Trim() -ne "" -and -not $_.Trim().StartsWith("#") }

$processedCount = 0
if (Test-Path $StateFile) {
    $raw = (Get-Content $StateFile -Raw).Trim()
    if ($raw) { $processedCount = [int]$raw }
}

if ($allUrls.Count -le $processedCount) {
    Write-Host "No new URLs found in $UrlsFile."
    exit 0
}

$newUrls = $allUrls[$processedCount..($allUrls.Count - 1)]
Write-Host "Found $($newUrls.Count) new URL(s) to add."

# Continue numbering from whatever files already exist, to avoid collisions
$existingCount = (Get-ChildItem -Path $DownloadDir -Filter "*.mp4" -File -ErrorAction SilentlyContinue).Count
$nextIndex = $existingCount + 1

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

foreach ($url in $newUrls) {
    $prefix = "{0:D3}" -f $nextIndex
    $outTemplate = Join-Path $DownloadDir "$prefix`_%(title)s.%(ext)s"

    Write-Host "Downloading: $url"
    & yt-dlp -f $Quality --merge-output-format mp4 -o $outTemplate $url *> $null

    $file = Get-ChildItem -Path $DownloadDir -Filter "$prefix`_*" |
        Select-Object -First 1 -ExpandProperty FullName

    if ($file) {
        if (Send-RcCommand "enqueue `"$file`"") {
            Write-Host "  -> Queued: $file"
        }
    } else {
        Write-Host "  -> Download failed: $url"
    }

    $nextIndex++
}

# Remember how many lines we've processed so next run only picks up newer ones
Set-Content -Path $StateFile -Value $allUrls.Count

Write-Host "`nDone -- current VLC playback was not interrupted."
