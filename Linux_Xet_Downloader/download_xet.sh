#!/usr/bin/env bash
#
# download_xet.sh — Download a model / GGUF file using the Xet protocol.
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
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv_xet"
PYTHON_BIN="$VENV_DIR/bin/python"
REQUIREMENTS=("huggingface_hub" "hf_xet")

echo "[*] Script directory: $SCRIPT_DIR"
echo "[*] Virtual environment: $VENV_DIR"

# --- 1. Create / refresh the virtual environment ---------------------------
if [ ! -d "$VENV_DIR" ]; then
    echo "[*] Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
else
    echo "[*] Virtual environment already exists."
fi

# --- 2. Install dependencies into the venv ---------------------------------
echo "[*] Installing dependencies into the venv: ${REQUIREMENTS[*]}"
"$PYTHON_BIN" -m pip install --upgrade pip </dev/null >/dev/null 2>&1
"$PYTHON_BIN" -m pip install "${REQUIREMENTS[@]}" </dev/null >/dev/null 2>&1

# --- 3. Run the download client inside the venv ----------------------------
# Forward any URL argument (from bash $1) to the Python client. The Python
# source is written to a temp file and executed with stdin inherited from the
# terminal so that the interactive prompt (input()) reads from the user, not
# from the heredoc that carries the source.
URL_ARG="${1:-}"
TEMP_PY="$(mktemp)"
cat > "$TEMP_PY" <<'PYEOF'
import os
import sys
from urllib.parse import urlparse, parse_qs, unquote

from huggingface_hub import hf_hub_download

# Directory of the *script* (not the temp file this code was copied into).
SCRIPT_DIR = os.environ.get("XET_SCRIPT_DIR") or os.path.dirname(os.path.abspath(__file__))

# --- Resolve URL -----------------------------------------------------------
# Accept an optional URL argument so the script is also usable non-interactively.
# Otherwise, prompt the user (as required).
if len(sys.argv) > 1 and sys.argv[1].strip():
    url = sys.argv[1].strip()
else:
    url = input("Enter the link to the model file or GGUF file: ").strip()
if not url:
    print("[!] No URL provided. Exiting.", file=sys.stderr)
    sys.exit(1)

parsed = urlparse(url)

# --- Resolve Hugging Face Hub URL ------------------------------------------
# Supports:
#   * direct file URLs: /<repo_id>/resolve|blob/<revision>/<filepath>
#   * repo tree pages:  /<repo_id>/tree/<revision>  (-> download whole repo)
#   * repo root pages:  /<repo_id>                  (-> download whole repo, default main)
#   * repo pages with ?show_file_info=<file>        (-> download that file)
repo_id = revision = filepath = subfolder = None
is_repo = False
is_hub = "huggingface.co" in parsed.netloc
if is_hub:
    path = parsed.path.strip("/")
    parts = path.split("/")
    marker_idx = None
    for i, p in enumerate(parts):
        if p in ("resolve", "blob"):
            marker_idx = i
            break
    tree_idx = None
    for i, p in enumerate(parts):
        if p == "tree":
            tree_idx = i
            break
    if marker_idx is not None:
        # Direct file URL.
        repo_id = "/".join(parts[:marker_idx])
        revision = parts[marker_idx + 1]
        filepath = "/".join(parts[marker_idx + 2:]) if len(parts) > marker_idx + 2 else revision
    elif tree_idx is not None:
        # Repo tree page: /<namespace>/<repo>/tree/<revision>[/subfolder/...]
        # Anything after the revision is a path to download only.
        repo_id = "/".join(parts[:tree_idx])
        revision = parts[tree_idx + 1] if len(parts) > tree_idx + 1 else "main"
        is_repo = True
        if len(parts) > tree_idx + 2:
            subfolder = "/".join(parts[tree_idx + 2:])
    else:
        # Repo root page: /<namespace>/<repo> or /<repo>
        if len(parts) >= 2:
            repo_id = parts[0] + "/" + parts[1]
        elif parts:
            repo_id = parts[0]
        else:
            repo_id = path or None
        revision = "main"
        is_repo = True
    # show_file_info can request a specific file from a repo page.
    qs = parse_qs(parsed.query)
    raw = qs.get("show_file_info")
    if raw:
        filepath = unquote(raw[0])
        is_repo = False  # a specific file was requested
    if is_repo:
        if not repo_id or not revision:
            print("[!] Could not determine a repository from this Hub URL.", file=sys.stderr)
            sys.exit(1)
    elif not repo_id or not filepath:
        print("[!] Could not determine a specific file from this Hub URL.", file=sys.stderr)
        sys.exit(1)

# --- Determine output folder -----------------------------------------------
# For Hub URLs the folder is named after the repo (slashes -> underscores);
# for generic URLs it is named after the file basename. Either way the folder
# is created next to this script.
if is_hub:
    folder_name = repo_id.replace("/", "_") or "download"
    filename = filepath or os.path.basename(repo_id) or "download"
else:
    folder_name = os.path.basename(parsed.path.rstrip("/")) or "download"
    filename = folder_name
output_folder = os.path.join(SCRIPT_DIR, folder_name)
os.makedirs(output_folder, exist_ok=True)
print(f"[*] Output folder: {output_folder}")


def download_repo(output_folder, subfolder=None):
    """Download the entire repository, or only a subfolder path within it.

    Tries snapshot_download (Xet-powered, fast). If the Xet read-token flow
    fails (it has no HTTP fallback), fall back to per-file hf_hub_download,
    which works for every file in the repo.

    When subfolder is given, only files under that path are downloaded.
    """
    from huggingface_hub import snapshot_download, list_repo_files, hf_hub_download
    if subfolder:
        # Download only files under the subfolder path.
        all_files = list_repo_files(repo_id=repo_id, revision=revision)
        files_in_folder = [f for f in all_files if f.startswith(subfolder + "/")]
        if files_in_folder:
            for filename in files_in_folder:
                hf_hub_download(
                    repo_id=repo_id,
                    filename=filename,
                    revision=revision,
                    local_dir=output_folder,
                )
            print(f"[+] Downloaded repository subfolder '{subfolder}': {output_folder}")
            return output_folder
        # The subfolder path itself might be a file.
        if subfolder in all_files:
            hf_hub_download(
                repo_id=repo_id,
                filename=subfolder,
                revision=revision,
                local_dir=output_folder,
            )
            print(f"[+] Downloaded file '{subfolder}': {output_folder}")
            return output_folder
        print(f"[!] No files found under subfolder '{subfolder}' in repo {repo_id}", file=sys.stderr)
        sys.exit(1)
    try:
        snapshot_download(
            repo_id=repo_id,
            revision=revision,
            local_dir=output_folder,
        )
        print(f"[+] Downloaded repository via Xet (snapshot_download): {output_folder}")
        return output_folder
    except Exception as exc:
        print(f"[!] snapshot_download failed: {exc}; falling back to per-file download", file=sys.stderr)
        for filename in list_repo_files(repo_id=repo_id, revision=revision):
            hf_hub_download(
                repo_id=repo_id,
                filename=filename,
                revision=revision,
                local_dir=output_folder,
            )
        print(f"[+] Downloaded repository via per-file fallback: {output_folder}")
        return output_folder


def download_file(output_folder):
    """Download a single file from the Hugging Face Hub via hf_hub_download
    (uses Xet when hf_xet is installed)."""
    return hf_hub_download(
        repo_id=repo_id,
        filename=filepath,
        revision=revision,
        local_dir=output_folder,
    )


def download_direct(url, output_folder):
    """Fallback: download a generic URL directly."""
    import urllib.request
    out_path = os.path.join(output_folder, filename)
    with urllib.request.urlopen(url) as resp, open(out_path, "wb") as f:
        while True:
            chunk = resp.read(8192)
            if not chunk:
                break
            f.write(chunk)
    return out_path


# --- Download --------------------------------------------------------------
def attempt(download_fn, label):
    try:
        result = download_fn(output_folder)
        print(f"[+] {label}: {result if result else output_folder}")
        return True
    except Exception as exc:
        print(f"[!] {label} failed: {exc}", file=sys.stderr)
        return False


try:
    if is_hub:
        if is_repo:
            ok = attempt(lambda of: download_repo(of, subfolder=subfolder), "Downloaded repository")
        else:
            ok = attempt(download_file, "Downloaded via Xet (hf_hub_download)")
        if not ok:
            print("[*] Retrying once...", file=sys.stderr)
            if is_repo:
                download_repo(output_folder, subfolder=subfolder)
                print(f"[+] Downloaded repository via retry: {output_folder}")
            else:
                result = download_file(output_folder)
                print(f"[+] Downloaded via retry: {result}")
    else:
        result = download_direct(url, output_folder)
        print(f"[+] Downloaded directly: {result}")
except Exception as exc:
    print(f"[!] Download failed: {exc}", file=sys.stderr)
    sys.exit(1)

print("[*] Done.")
PYEOF
XET_SCRIPT_DIR="$SCRIPT_DIR" "$PYTHON_BIN" "$TEMP_PY" "$URL_ARG"
rm -f "$TEMP_PY"
