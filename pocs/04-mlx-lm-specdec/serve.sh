#!/usr/bin/env bash
# POC 4 — mlx-lm with classic speculative decoding.
#
# Target:  $HOME/models/Qwen3.6-27B-MLX-8bit  (vocab 248320)
# Drafter: $HOME/models/Qwen3.5-0.8B-MLX-8bit (vocab 248320, identical
#          tokenizer.json by SHA256 — verified before download).
#
# Both are mlx-community MLX-format quantizations with the same Qwen3_5
# multimodal arch family, so mlx_lm.server can load them as
# (target, draft).
set -euo pipefail
cd "$(dirname "$0")"
source .venv/bin/activate

TARGET="$HOME/models/Qwen3.6-27B-MLX-8bit"
DRAFT="$HOME/models/Qwen3.5-0.8B-MLX-8bit"
NUM_DRAFT_TOKENS="${NUM_DRAFT_TOKENS:-4}"
PORT="${PORT:-8080}"

exec mlx_lm.server \
  --model "$TARGET" \
  --draft-model "$DRAFT" \
  --num-draft-tokens "$NUM_DRAFT_TOKENS" \
  --host 127.0.0.1 \
  --port "$PORT" \
  --log-level INFO \
  --chat-template-args '{"enable_thinking": false}' \
  --max-tokens 4096
