#!/usr/bin/env bash
# ==============================================================================
# hf-xet-max.sh — download a Hugging Face model at maximum speed (Xet protocol)
#
# Prompts for a download link, then downloads into the directory the script
# is executed in. Uses the official `hf` CLI (huggingface_hub >= 0.32, which
# bundles the Rust `hf_xet` Xet engine):
#   - adaptive concurrency (1→64 streams; 16→124 with HF_XET_HIGH_PERFORMANCE)
#   - parallel file downloads via --max-workers
#   - Xet HIGH_PERFORMANCE mode auto-enabled on machines with >= 64 GB RAM
#
# Protocol ref: https://huggingface.co/docs/xet/download-protocol
# ==============================================================================
set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
urldecode() { printf '%b' "${1//%/\\x}"; }

# ------------------------------------------------------------- 1. Ask for link
printf '=== Hugging Face Xet max-speed downloader ===\n'
read -r -p 'Download link (repo URL, file URL, or org/repo): ' LINK || die 'no input received'
LINK="${LINK//[$'\t\r\n ']/}"
[ -n "$LINK" ] || die 'no link provided.'

DEST="$(pwd)"
printf 'Saving to: %s\n\n' "$DEST"

# ------------------------------------------------------------- 2. Parse the link
TYPE="model"; REPO_ID=""; REVISION=""; FILE=""; URI_MODE=0

if [[ "$LINK" == hf://* ]]; then
    URI_MODE=1
    REPO_ID="$LINK"                       # hf:// URI encodes type/revision/file itself
else
    path="${LINK#*://}"                  # strip scheme (no-op if absent)
    path="${path#huggingface.co/}"
    path="${path#www.huggingface.co/}"

    # --- extract query string FIRST (file-info modal links use ?show_file_info=<file>)
    query=""
    if [[ "$path" == *\?* ]]; then
        query="${path#*\?}"
        path="${path%%\?*}"
    fi
    path="${path%%#*}"
    while [ "$path" != "${path%/}" ]; do path="${path%/}"; done
    [ -n "$path" ] || die "could not parse '$LINK' as a Hugging Face link"

    QUERY_FILE=""
    if [ -n "$query" ]; then
        IFS='&' read -r -a QPAIRS <<< "$query"
        for p in "${QPAIRS[@]}"; do
            if [[ "$p" == show_file_info=* ]]; then
                QUERY_FILE="${p#show_file_info=}"
            fi
        done
    fi

    case "$path" in
        datasets/*) TYPE="dataset"; path="${path#datasets/}" ;;
        spaces/*)   TYPE="space";   path="${path#spaces/}"   ;;
    esac

    IFS='/' read -r -a SEG <<< "$path"
    if [ "${#SEG[@]}" -lt 2 ]; then
        die "'$LINK' does not look like a repo link (expected org/repo)"
    fi
    REPO_ID="${SEG[0]}/${SEG[1]}"

    # org/repo/<tree|resolve|raw|blobs|commit>/<revision>[/file/.../path]
    if [ "${#SEG[@]}" -ge 4 ]; then
        case "${SEG[2]}" in
            tree|resolve|raw|blobs|commit)
                REVISION="$(urldecode "${SEG[3]}")"
                if [ "${#SEG[@]}" -gt 4 ]; then
                    FILE="${SEG[4]}"
                    for ((i = 5; i < ${#SEG[@]}; i++)); do FILE+="/${SEG[i]}"; done
                    FILE="$(urldecode "$FILE")"
                fi
                ;;
            *) die "unrecognized link format: $LINK" ;;
        esac
    fi

    # ?show_file_info=<file> points at a single file (URL-encoded name supported)
    if [ -n "$QUERY_FILE" ] && [ -z "$FILE" ]; then
        FILE="$(urldecode "$QUERY_FILE")"
    fi
fi

[[ "$REPO_ID" =~ ^[^/]+/[^/]+$ ]] || die "invalid repo id: $REPO_ID"

# ------------------------------------------------------------- 3. Token (optional)
printf 'Hugging Face token (only needed for gated/private repos; Enter to skip): '
read -rs TOKEN || true
printf '\n'

# ------------------------------------------------------------- 4. Get the hf CLI
VENV=""
cleanup() { if [ -n "$VENV" ]; then rm -rf "$VENV"; fi; }
trap cleanup EXIT

HF_BIN=""
if command -v hf >/dev/null 2>&1 && hf download --help >/dev/null 2>&1; then
    HF_BIN="$(command -v hf)"
    # upgrade if the existing CLI predates Xet support (huggingface_hub < 0.32)
    HUB_VER="$(hf version 2>/dev/null | awk -F': ' '/huggingface_hub/ {print $2}' | tr -d '[:space:]')"
    if [[ "$HUB_VER" =~ ^0\.([0-9]+) ]] && [ "${BASH_REMATCH[1]}" -lt 32 ] && command -v pip3 >/dev/null 2>&1; then
        echo "Found old huggingface_hub $HUB_VER — upgrading for Xet support..."
        pip3 install --quiet --upgrade "huggingface_hub>=0.32" || true
    fi
elif command -v python3 >/dev/null 2>&1; then
    VENV="$(mktemp -d /tmp/hf-xet-venv.XXXXXX)"
    echo "Installing 'hf' CLI (huggingface_hub >= 0.32 + Xet engine) into a temp venv..."
    python3 -m venv "$VENV" || die 'venv creation failed (Debian/Ubuntu: apt install python3-venv)'
    "$VENV/bin/python" -m pip install --quiet --upgrade pip
    "$VENV/bin/python" -m pip install --quiet --upgrade "huggingface_hub>=0.32"
    [ -x "$VENV/bin/hf" ] || die "'hf' missing after install"
    HF_BIN="$VENV/bin/hf"
else
    die "need the 'hf' CLI or python3 (3.9+). Install Python 3 and re-run."
fi
echo "CLI: $HF_BIN"

# ------------------------------------------------------------- 5. Max-speed Xet tuning
unset HF_HUB_ENABLE_HF_TRANSFER          # hf_transfer would bypass Xet — we want Xet
export HF_HUB_DOWNLOAD_TIMEOUT=60        # default 10 s read timeout is tight for big files

RAM_GB="$(awk '/MemTotal/ {printf "%d", $2 / 1048576}' /proc/meminfo 2>/dev/null || echo 0)"
if [ "$RAM_GB" -ge 64 ]; then
    export HF_XET_HIGH_PERFORMANCE=1     # 16→124 concurrent streams + large buffers
    echo "Xet high-performance mode: adaptive concurrency 16→124 streams (${RAM_GB} GB RAM)"
else
    echo "Xet adaptive concurrency: 1→64 streams, auto-tuned to the network (${RAM_GB} GB RAM)"
fi

CPUS="$(nproc 2>/dev/null || echo 4)"
WORKERS=8
if [ "$CPUS" -ge 8 ]; then WORKERS=16; fi
if [ -n "${HF_WORKERS:-}" ]; then WORKERS="$HF_WORKERS"; fi   # override: HF_WORKERS=32 ./hf-xet-max.sh
export HF_XET_DATA_MAX_CONCURRENT_FILE_DOWNLOADS="$WORKERS"
echo "Parallel file downloads: $WORKERS workers"
echo

# ------------------------------------------------------------- 6. Download
if [ "$URI_MODE" -eq 1 ]; then
    printf 'Target: %s\n' "$REPO_ID"
else
    printf 'Repository : %s\n' "$REPO_ID"
    if [ -n "$REVISION" ]; then printf 'Revision   : %s\n' "$REVISION"; fi
    if [ -n "$FILE" ]; then printf 'File       : %s\n' "$FILE"; fi
fi
printf 'Destination: %s\n\n' "$DEST"

CMD=("$HF_BIN" download)
if [ "$URI_MODE" -eq 0 ]; then
    CMD+=(--repo-type "$TYPE")
    if [ -n "$REVISION" ]; then CMD+=(--revision "$REVISION"); fi
fi
if [ -n "$TOKEN" ]; then CMD+=(--token "$TOKEN"); fi
CMD+=(--local-dir "$DEST" --max-workers "$WORKERS" "$REPO_ID")
if [ -n "$FILE" ]; then CMD+=("$FILE"); fi

echo "Running: ${CMD[*]}"
echo
"${CMD[@]}"

printf '\nDone. Files are in: %s\n' "$DEST"