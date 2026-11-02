#!/usr/bin/pwsh
#
# download_xet.ps1 — Download a model / GGUF file using the Xet protocol.
#
# What this script does:
#   1. Creates a Python virtual environment (.venv_xet) next to this script.
#   2. Installs the Xet-capable dependencies inside that venv:
#        huggingface_hub  (Hub client)
#        hf_xet           (Rust-backed Xet client, wired into huggingface_hub)
#   3. Prompts the user for a link to a model file or GGUF file.
#   4. Creates an output folder (named after the file) in the folder where
#      this script lives and downloads the file into it.
#
# The Xet protocol is used under the hood by huggingface_hub whenever hf_xet
# is installed, so downloads from the Hugging Face Hub route through Xet
# (chunked, deduplicated, content-addressed storage).
#
# The download logic lives in download_xet_client.py next to this script; this
# PowerShell wrapper handles venv setup, dependency install, and invocation.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$SCRIPT_DIR = $PSScriptRoot
$VENV_DIR = Join-Path $SCRIPT_DIR ".venv_xet"
$PYTHON_BIN = Join-Path $VENV_DIR "Scripts\python.exe"
$CLIENT_PY = Join-Path $SCRIPT_DIR "download_xet_client.py"
$REQUIREMENTS = @("huggingface_hub", "hf_xet")

Write-Host "[*] Script directory: $SCRIPT_DIR"
Write-Host "[*] Virtual environment: $VENV_DIR"

# --- 1. Create / refresh the virtual environment ---------------------------
if (-not (Test-Path $VENV_DIR)) {
    Write-Host "[*] Creating virtual environment..."
    python -m venv $VENV_DIR
} else {
    Write-Host "[*] Virtual environment already exists."
}

# --- 2. Install dependencies into the venv ---------------------------------
Write-Host "[*] Installing dependencies into the venv: $($REQUIREMENTS -join ', ')"
# pip's cache-deserialization warning is non-fatal; isolate it so it doesn't
# trip $ErrorActionPreference = 'Stop'.
$oldEA = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
& $PYTHON_BIN -m pip install --upgrade pip > $null 2>&1
& $PYTHON_BIN -m pip install $REQUIREMENTS > $null 2>&1
$ErrorActionPreference = $oldEA

# --- 3. Run the download client inside the venv ----------------------------
# Forward any URL argument to the Python client. The client's stdin is
# inherited from the console so that the interactive prompt (input()) reads
# from the user.
$URL_ARG = if ($args.Count -gt 0) { $args[0] } else { "" }
$env:XET_SCRIPT_DIR = $SCRIPT_DIR
$pythonArgs = @($CLIENT_PY)
if ($URL_ARG -ne "") { $pythonArgs += $URL_ARG }
& $PYTHON_BIN @pythonArgs
