# =============================================================================
# download_mpv.ps1 — unduh build mpv (Windows x64) ke folder `mpv/` project ini.
# -----------------------------------------------------------------------------
# Setelah folder `mpv/` terisi (mpv.exe + DLL), `flutter build windows --release`
# otomatis menyalinnya ke `<Release>/mpv/` (lihat windows/CMakeLists.txt),
# sehingga device baru cukup copy folder Release.
#
# Pemakaian:
#   powershell -ExecutionPolicy Bypass -File tools/download_mpv.ps1
#
# Opsi:
#   -Url  <url .7z>   Pakai URL khusus (lewati pencarian otomatis di GitHub).
#   -Dest <folder>    Folder tujuan (default: <project>/mpv).
#   -Force            Timpa walau mpv.exe sudah ada.
#
# Sumber: build Windows resmi-compatible dari GitHub:
#   - https://github.com/zhongfly/mpv-winbuild        (utama)
#   - https://github.com/shinchiro/mpv-winbuild-cmake (cadangan)
# =============================================================================
[CmdletBinding()]
param(
    [string]$Url = "",
    [string]$Dest = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # Invoke-WebRequest lebih cepat tanpa progress bar

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "OK  $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "!!  $Message" -ForegroundColor Yellow }

# --- Folder tujuan -----------------------------------------------------------
if (-not $Dest) {
    $root = Split-Path -Parent $PSScriptRoot      # ...\purplehat-flutter
    $Dest = Join-Path $root "mpv"
}
New-Item -ItemType Directory -Force -Path $Dest | Out-Null

if ((Test-Path (Join-Path $Dest "mpv.exe")) -and -not $Force) {
    Write-Ok "mpv.exe sudah ada di '$Dest'. Pakai -Force untuk menimpa."
    exit 0
}

# --- Cari URL build terbaru (GitHub Releases) --------------------------------
if (-not $Url) {
    Write-Step "Mencari build mpv x86_64 terbaru di GitHub ..."

    # Utamakan build biasa (x86_64) yang kompatibel luas, bukan varian -v3 (butuh AVX2).
    $assetPattern = '^mpv-x86_64-\d+-git-[0-9a-fA-F]+\.7z$'
    $repos = @(
        "zhongfly/mpv-winbuild",
        "shinchiro/mpv-winbuild-cmake"
    )

    $headers = @{
        "User-Agent" = "purplehat-mpv-downloader"
        "Accept"     = "application/vnd.github+json"
    }

    $pick = $null
    foreach ($repo in $repos) {
        $api = "https://api.github.com/repos/$repo/releases/latest"
        try {
            $release = Invoke-RestMethod -Uri $api -Headers $headers -UseBasicParsing
        } catch {
            Write-Warn "Gagal membaca rilis '$repo': $($_.Exception.Message)"
            continue
        }

        $asset = $release.assets |
            Where-Object { $_.name -match $assetPattern } |
            Select-Object -First 1

        if ($asset) {
            $pick = [pscustomobject]@{
                Repo     = $repo
                Tag      = $release.tag_name
                Name     = $asset.name
                Url      = $asset.browser_download_url
                SizeMB   = [math]::Round($asset.size / 1MB, 1)
            }
            break
        }
        Write-Warn "Rilis '$repo' tidak punya aset $assetPattern (tag: $($release.tag_name))."
    }

    if (-not $pick) {
        throw "Tidak menemukan build mpv x86_64 . Unduh manual (mis. https://github.com/zhongfly/mpv-winbuild/releases) lalu jalankan ulang dengan -Url <url .7z>."
    }

    $Url = $pick.Url
    Write-Ok "Build: $($pick.Name)  ($($pick.SizeMB) MB, dari $($pick.Repo) @ $($pick.Tag))"
}

# --- Alat ekstrak (.7z): 7z terpasang, atau 7zr portable ---------------------
function Get-Extractor {
    $candidates = @(
        (Join-Path $env:ProgramFiles "7-Zip\7z.exe")
    )
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} "7-Zip\7z.exe")
    }
    $candidates += (Join-Path $env:LOCALAPPDATA "Programs\7-Zip\7z.exe")
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }

    # 7zr.exe standalone (mendukung format .7z) — diunduh sekali ke TEMP.
    $sevenZr = Join-Path $env:TEMP "7zr.exe"
    if (-not (Test-Path $sevenZr)) {
        Write-Step "Mengunduh 7zr.exe (untuk mengekstrak .7z) ..."
        Invoke-WebRequest -Uri "https://www.7-zip.org/a/7zr.exe" -OutFile $sevenZr -UseBasicParsing
    }
    return $sevenZr
}

# --- Unduh arsip -------------------------------------------------------------
$archive = Join-Path $env:TEMP ("ph_mpv_" + [guid]::NewGuid().ToString("N") + ".7z")
Write-Step "Mengunduh mpv ... (bisa puluhan MB)"
Invoke-WebRequest -Uri $Url -OutFile $archive -UseBasicParsing
Write-Ok "Terunduh: $archive"

# --- Ekstrak -----------------------------------------------------------------
$tmp = Join-Path $env:TEMP ("ph_mpv_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$extractor = Get-Extractor
Write-Step "Mengekstrak (pakai '$extractor') ..."
& $extractor x $archive "-o$tmp" -y | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Ekstraksi gagal (kode $LASTEXITCODE)."
}

# Cari file mpv.exe hasil ekstraksi (arsip bisa berisi subfolder).
$mpv = Get-ChildItem -Path $tmp -Recurse -Filter "mpv.exe" -File | Select-Object -First 1
if (-not $mpv) { throw "mpv.exe tidak ditemukan dalam arsip." }

# Salin SELURUH isi folder yang memuat mpv.exe ke $Dest (mpv.exe, mpv.com, DLL, dll).
Write-Step "Menyalin ke '$Dest' ..."
Get-ChildItem -Path $mpv.DirectoryName -Force | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $Dest -Recurse -Force
}

# --- Bersihkan -------------------------------------------------------------
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Remove-Item -Force $archive -ErrorAction SilentlyContinue

if (-not (Test-Path (Join-Path $Dest "mpv.exe"))) {
    throw "mpv.exe belum ada di '$Dest'. Periksa isi arsip."
}

Write-Ok "Selesai. mpv siap di '$Dest'."
Write-Host ""
Write-Host "Langkah berikutnya:" -ForegroundColor White
Write-Host "    flutter build windows --release"
Write-Host "  -> mpv ikut tersalin ke build\windows\x64\runner\Release\mpv\"
Write-Host ""
Write-Host "Pastikan backend/.env punya MPV_IPC_PIPE yang sama dengan lib/config.dart" -ForegroundColor White
Write-Host "  (default: \\.\pipe\purplehat-mpv)."
