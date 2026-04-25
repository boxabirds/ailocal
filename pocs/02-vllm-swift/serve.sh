#!/usr/bin/env bash
# POC 2 — vllm-swift (Swift/Metal vLLM plugin) + Qwen3.6-27B
#
# Three modes selected by SERVE_MODE env var:
#   plain         (default) — no speculation
#   dflash        --speculative-config '{"method":"dflash","model":"z-lab/Qwen3.6-27B-DFlash",...}'
#   turboquant    --additional-config '{"kv_scheme":"turbo4v2","kv_bits":4}'
set -euo pipefail
cd "$(dirname "$0")"

MODE="${SERVE_MODE:-plain}"
MODEL="$HOME/models/Qwen3.6-27B-MLX-8bit"
DRAFT="$HOME/models/Qwen3.6-27B-DFlash"
SWIFT_BUILD="$PWD/src/swift/.build/arm64-apple-macosx/release"

source .venv/bin/activate
export DYLD_LIBRARY_PATH="$SWIFT_BUILD:${DYLD_LIBRARY_PATH:-}"

EXTRA_ARGS=()
case "$MODE" in
  plain)
    ;;
  dflash)
    EXTRA_ARGS+=(--speculative-config "{\"method\":\"dflash\",\"model\":\"$DRAFT\",\"num_speculative_tokens\":15}")
    ;;
  turboquant)
    EXTRA_ARGS+=(--additional-config '{"kv_scheme":"turbo4v2","kv_bits":4}')
    ;;
  *)
    echo "Unknown SERVE_MODE: $MODE (use plain|dflash|turboquant)"; exit 1 ;;
esac

echo "Mode: $MODE"
echo "Model: $MODEL"
echo "Extra args: ${EXTRA_ARGS[*]:-(none)}"

exec vllm serve "$MODEL" \
  --served-model-name qwen36-27b \
  --host 127.0.0.1 \
  --port 8000 \
  --max-model-len 32768 \
  --enable-auto-tool-choice --tool-call-parser hermes \
  "${EXTRA_ARGS[@]}"
