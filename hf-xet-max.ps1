#Requires -Version 5.1
# ==============================================================================
# hf-xet-max.ps1 - Download a Hugging Face model at maximum speed (Xet protocol)
#
# Windows port of hf-xet-max.sh. Prompts for a download link, then downloads
# into the directory the script is executed in. Uses the official 'hf' CLI
# (huggingface_hub >= 0.32 with the Rust 'hf_xet' Xet engine):
#   - adaptive concurrency (1->64 streams; 16->124 with HF_XET_HIGH_PERFORMANCE)
#   - parallel file downloads via --max-workers
#   - Xet HIGH_PERFORMANCE mode auto-enabled on machines with >= 64 GB RAM
#   - hf_xet is installed explicitly (older hub versions had a bug where it
#     was NOT auto-installed on Windows, because platform.machine() == 'AMD64')
#
# How to run:
#   powershell -ExecutionPolicy Bypass -File .\hf-xet-max.ps1
#
# Protocol ref: https://huggingface.co/docs/xet/download-protocol
# ==============================================================================

$ErrorActionPreference = 'Stop'

function Die([string]$msg) {
    Write-Host "ERROR: $msg" -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------- 1. Ask for link
Write-Host '=== Hugging Face Xet max-speed downloader ==='
$LINK = Read-Host 'Download link (repo URL, file URL, or org/repo)'
$LINK = $LINK.Trim()
if (-not $LINK) { Die 'no link provided.' }

$DEST = (Get-Location).Path
Write-Host "Saving to: $DEST"
Write-Host ''

# ------------------------------------------------------------- 2. Parse the link
$TYPE = 'model'
$REPO_ID = ''
$REVISION = ''
$FILE = ''
$URI_MODE = 0
$QUERY_FILE = ''

function Unescape([string]$s) { return [System.Uri]::UnescapeDataString($s) }

if ($LINK -like 'hf://*') {
    $URI_MODE = 1
    $REPO_ID = $LINK                       # hf:// URI encodes type/revision/file itself
} else {
    $path = $LINK
    if ($path -match '^[a-z]+://(.*)$') { $path = $Matches[1] }
    $path = $path -replace '^www\.huggingface\.co/', ''
    $path = $path -replace '^huggingface\.co/', ''

    # --- extract the query string FIRST (file-info modal links use ?show_file_info=<file>)
    $query = ''
    $qIdx = $path.IndexOf('?')
    if ($qIdx -ge 0) {
        $query = $path.Substring($qIdx + 1)
        $path  = $path.Substring(0, $qIdx)
    }
    $fIdx = $path.IndexOf('#')
    if ($fIdx -ge 0) { $path = $path.Substring(0, $fIdx) }
    while ($path.Length -gt 0 -and $path.EndsWith('/')) {
        $path = $path.Substring(0, $path.Length - 1)
    }
    if (-not $path) { Die "could not parse '$LINK' as a Hugging Face link" }

    if ($query) {
        foreach ($pair in ($query -split '&')) {
            if ($pair -like 'show_file_info=*') {
                $QUERY_FILE = $pair.Substring('show_file_info='.Length)
            }
        }
    }

    if ($path -like 'datasets/*') { $TYPE = 'dataset'; $path = $path.Substring('datasets/'.Length) }
    elseif ($path -like 'spaces/*') { $TYPE = 'space';   $path = $path.Substring('spaces/'.Length) }

    $SEG = $path -split '/'
    if ($SEG.Count -lt 2) { Die "'$LINK' does not look like a repo link (expected org/repo)" }
    $REPO_ID = "$($SEG[0])/$($SEG[1])"

    # org/repo/<tree|resolve|raw|blobs|commit>/<revision>[/file/.../path]
    if ($SEG.Count -ge 4) {
        $action = $SEG[2]
        if ($action -eq 'tree' -or $action -eq 'resolve' -or $action -eq 'raw' -or $action -eq 'blobs' -or $action -eq 'commit') {
            $REVISION = Unescape $SEG[3]
            if ($SEG.Count -gt 4) {
                $FILE = [string]::Join('/', $SEG[4..($SEG.Count - 1)])
                $FILE = Unescape $FILE
            }
        } else {
            Die "unrecognized link format: $LINK"
        }
    }

    # ?show_file_info=<file> points at a single file (URL-encoded name supported)
    if ($QUERY_FILE -and -not $FILE) {
        $FILE = Unescape $QUERY_FILE
    }
}

if ($REPO_ID -notmatch '^[^/]+/[^/]+$') { Die "invalid repo id: $REPO_ID" }

# ------------------------------------------------------------- 3. Token (optional)
$secure = Read-Host 'Hugging Face token (only needed for gated/private repos; Enter to skip)' -AsSecureString
$TOKEN = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
Write-Host ''

$VENV = $null
try {

    # ------------------------------------------------------------- 4. Get the hf CLI
    $HF_BIN = ''
    $hfCmd = Get-Command 'hf' -ErrorAction SilentlyContinue
    if ($hfCmd) {
        & $hfCmd.Source download --help *> $null
        if ($LASTEXITCODE -eq 0) {
            $HF_BIN = $hfCmd.Source
            # upgrade if the existing CLI predates Xet support (huggingface_hub < 0.32)
            $hubOut = (& $hfCmd.Source version 2>&1 | Out-String)
            if ($hubOut -match 'huggingface_hub\D*?([0-9]+)\.([0-9]+)') {
                $hubMaj = [int]$Matches[1]; $hubMin = [int]$Matches[2]
                if ($hubMaj -eq 0 -and $hubMin -lt 32) {
                    $pipCmd = Get-Command 'pip' -ErrorAction SilentlyContinue
                    if ($pipCmd) {
                        Write-Host "Found old huggingface_hub ($hubMaj.$hubMin) - upgrading for Xet support..."
                        & $pipCmd.Source install --quiet --user --upgrade "huggingface_hub>=0.32" "hf_xet"
                    }
                }
            }
        }
    }

    if (-not $HF_BIN) {
        $pyCmd = Get-Command 'python' -ErrorAction SilentlyContinue
        if (-not $pyCmd) { $pyCmd = Get-Command 'python3' -ErrorAction SilentlyContinue }
        if ($pyCmd) {
            $ver = (& $pyCmd.Source --version 2>&1 | Out-String)
            if ($ver -notmatch 'Python 3\.') {
                Die "found 'python' but it is not Python 3 (got: '$($ver.Trim())'). Install Python 3 from python.org and re-run."
            }
            $VENV = Join-Path $env:TEMP ("hf-xet-venv-" + [guid]::NewGuid().ToString('N'))
            Write-Host "Installing 'hf' CLI (huggingface_hub >= 0.32 + Xet engine) into a temp venv..."
            & $pyCmd.Source -m venv $VENV
            if ($LASTEXITCODE -ne 0) {
                Die 'venv creation failed. Use the official python.org Windows build (it includes venv).'
            }
            $venvPy = Join-Path $VENV 'Scripts\python.exe'
            & $venvPy -m pip install --quiet --upgrade pip
            # hf_xet installed EXPLICITLY: guarantees the Xet engine on Windows
            & $venvPy -m pip install --quiet --upgrade "huggingface_hub>=0.32" "hf_xet"
            $HF_BIN = Join-Path $VENV 'Scripts\hf.exe'
            if (-not (Test-Path $HF_BIN)) { Die "'hf.exe' missing after install" }
        } else {
            Die "need the 'hf' CLI or Python 3. Install Python 3 from python.org and re-run."
        }
    }
    Write-Host "CLI: $HF_BIN"

    # ------------------------------------------------------------- 5. Max-speed Xet tuning
    if ($env:HF_HUB_ENABLE_HF_TRANSFER) { Remove-Item Env:HF_HUB_ENABLE_HF_TRANSFER }
    # ^ hf_transfer would bypass Xet - we want Xet
    $env:HF_HUB_DOWNLOAD_TIMEOUT = '60'      # default 10 s read timeout is tight for big files

    $RAM_GB = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    if ($RAM_GB -ge 64) {
        $env:HF_XET_HIGH_PERFORMANCE = '1'   # 16->124 concurrent streams + large buffers
        Write-Host "Xet high-performance mode: adaptive concurrency 16->124 streams ($RAM_GB GB RAM)"
    } else {
        Write-Host "Xet adaptive concurrency: 1->64 streams, auto-tuned to the network ($RAM_GB GB RAM)"
    }

    $CPUS = [Environment]::ProcessorCount
    $WORKERS = 8
    if ($CPUS -ge 8) { $WORKERS = 16 }
    if ($env:HF_WORKERS) { $WORKERS = [int]$env:HF_WORKERS }
    # ^ override: set $env:HF_WORKERS='32' before running
    $env:HF_XET_DATA_MAX_CONCURRENT_FILE_DOWNLOADS = "$WORKERS"
    Write-Host "Parallel file downloads: $WORKERS workers"
    Write-Host ''

    # ------------------------------------------------------------- 6. Download
    if ($URI_MODE -eq 1) {
        Write-Host "Target: $REPO_ID"
    } else {
        Write-Host "Repository : $REPO_ID"
        if ($REVISION) { Write-Host "Revision   : $REVISION" }
        if ($FILE)     { Write-Host "File       : $FILE" }
    }
    Write-Host "Destination: $DEST"
    Write-Host ''

    $hfArgs = @('download')
    if ($URI_MODE -eq 0) {
        $hfArgs += @('--repo-type', $TYPE)
        if ($REVISION) { $hfArgs += @('--revision', $REVISION) }
    }
    if ($TOKEN) { $hfArgs += @('--token', $TOKEN) }
    $hfArgs += @('--local-dir', $DEST, '--max-workers', "$WORKERS", $REPO_ID)
    if ($FILE) { $hfArgs += $FILE }

    Write-Host ("Running: " + $HF_BIN + ' ' + ($hfArgs -join ' '))
    Write-Host ''
    & $HF_BIN @hfArgs
    if ($LASTEXITCODE -ne 0) { Die "hf download failed with exit code $LASTEXITCODE" }

    Write-Host ''
    Write-Host "Done. Files are in: $DEST"

} finally {
    # clean up the temp venv no matter how the script ended
    if ($VENV -and (Test-Path $VENV)) {
        Remove-Item -Recurse -Force $VENV -ErrorAction SilentlyContinue
    }
}
