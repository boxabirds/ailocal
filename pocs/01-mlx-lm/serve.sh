#!/usr/bin/env bash
# POC 1 — mlx-lm + Qwen3.6-27B (no speculation; clean baseline path)
set -euo pipefail
cd "$(dirname "$0")"
source .venv/bin/activate
exec mlx_lm.server \
  --model "$HOME/models/Qwen3.6-27B-MLX-8bit" \
  --host 127.0.0.1 \
  --port 8080 \
  --log-level INFO \
  --chat-template-args '{"enable_thinking": false}' \
  --max-tokens 16384
