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
