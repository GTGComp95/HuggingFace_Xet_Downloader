
Download model files, GGUF files, and entire repositories from the Hugging Face Hub using the **Xet protocol**.

## What this does

- Creates a Python virtual environment (`.venv_xet`) next to the script.
- Installs `huggingface_hub` and `hf_xet` into that venv.
- Prompts you for a Hugging Face Hub URL (or accepts one as an argument).
- Downloads the file / repository into an output folder created next to the script.
- All downloads route through the **Xet protocol** (content-defined chunking, BLAKE3 hashing, deduplication, signed xorb URLs) whenever `hf_xet` is installed.

## Supported URL formats

The script recognizes Hugging Face Hub URLs in these forms:

| Format | Behavior | Example |
|---|---|---|
| Direct file (`/resolve/` or `/blob/`) | Downloads that single file | `https://huggingface.co/bert-base-uncased/resolve/main/config.json` |
| Repo page with `?show_file_info=<file>` | Downloads that single file | `https://huggingface.co/AtomicChat/...GGUF?show_file_info=...` |
| Repo tree (`/tree/<revision>`) | Downloads the **entire repository** | `https://huggingface.co/bert-base-uncased/tree/main` |
| Repo tree with subfolder (`/tree/<revision>/<folder>`) | Downloads **only** that subfolder's files | `https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/tree/main/Q2_0` |
| Repo root (`/<repo_id>`) | Downloads the **entire repository** (default `main`) | `https://huggingface.co/bert-base-uncased` |
| Non-HF URL | Downloaded directly via plain HTTP | any `https://...` URL |

## Usage

Interactive: you'll be prompted for the URL


# Non-interactive: pass the URL as an argument
./download_xet "https://huggingface.co/bert-base-uncased/resolve/main/config.json"

The first run creates `.venv_xet` and installs dependencies. Subsequent runs reuse the existing venv.

## Output

- An output folder is created in the directory where the script lives.
- For Hub URLs the folder is named after the repo (`<namespace>_<repo>`).
- For subfolder tree URLs the files are placed under a subdirectory matching the requested path (e.g. `Q2_0/` inside the repo folder).
- For single-file downloads the file lands at the top level of the output folder.
- `huggingface_hub` writes its `.cache/huggingface` metadata inside the output folder; the actual model file sits alongside it.

## Requirements

- `python3` with `venv` support.
- Network access to the Hugging Face Hub.

Downloads are unauthenticated, so normal Hugging Face rate limits apply. Set `HF_TOKEN` in your environment for higher limits.

## How Xet is used

When `hf_xet` is installed (it comes bundled with recent `huggingface_hub`), `hf_hub_download` routes through the Xet protocol automatically: chunked, content-addressed storage with BLAKE3 hashing and deduplication.
Single-file downloads are verified working through Xet. 
Whole-repository downloads via `snapshot_download` can hit a known Xet read-token endpoint limitation; in that case the script falls back to per-file `hf_hub_download`, which works for every file in the repo.

## License

This script is provided as-is. No credentials are stored in the script.
