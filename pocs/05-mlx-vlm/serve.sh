#!/usr/bin/env bash
# POC 5 — mlx-vlm + Qwen3.6-27B-MLX-8bit (vision-enabled OpenAI-compat server).
#
# Same on-disk model as POC 1 (unsloth/Qwen3.6-27B-MLX-8bit) — the checkpoint
# bundles the vision tower (333 ViT weights alongside 1367 LM weights). mlx-lm
# ignores the vision parts; mlx-vlm loads them and exposes them via the
# OpenAI-standard `image_url` content part.
set -euo pipefail
cd "$(dirname "$0")"
source .venv/bin/activate
exec python -m mlx_vlm.server \
  --model "$HOME/models/Qwen3.6-27B-MLX-8bit" \
  --host 127.0.0.1 \
  --port 8080
