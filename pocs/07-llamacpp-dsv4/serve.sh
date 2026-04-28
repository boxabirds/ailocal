#!/usr/bin/env bash
# POC 7 — llama.cpp (antirez fork) + DeepSeek-V4-Flash GGUF.
#
# Source:  https://github.com/antirez/llama.cpp-deepseek-v4-flash
# Weights: https://huggingface.co/antirez/deepseek-v4-gguf
#
# Why this exists: mlx-lm PR #1192 loads DSV4 fine but rejects the OpenAI
# `tools` array (no tool-call template), and OOMs around 6K-token prompts
# (Metal single-buffer cap). antirez's fork includes a hand-written V4 chat
# template that handles tool-calling and runs at full context. Trade-off:
# llama.cpp's Metal path is reportedly ~5× slower than mlx-lm for raw decode.
#
# Tested locally on 2026-04-27.
set -euo pipefail
cd "$(dirname "$0")"
SERVER="$PWD/llama.cpp/build/bin/llama-server"
MODEL="$HOME/models/deepseek-v4-gguf/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2.gguf"
TEMPLATE="$PWD/llama.cpp/models/templates/deepseek-ai-DeepSeek-V4.jinja"

[ -x "$SERVER" ] || { echo "missing $SERVER — run cmake build first" >&2; exit 1; }
[ -f "$MODEL" ]  || { echo "missing $MODEL — run hf download" >&2; exit 1; }
[ -f "$TEMPLATE" ] || { echo "missing $TEMPLATE — clone of antirez fork incomplete" >&2; exit 1; }

# Default: 32K context (well below the 1M YaRN-extended max, room for KV) +
# Metal layer offload. Tune up via env if you need more.
CTX="${LLAMA_CTX:-32768}"
NGL="${LLAMA_NGL:-999}"   # offload all layers to Metal

exec "$SERVER" \
  --model "$MODEL" \
  --chat-template-file "$TEMPLATE" \
  --host 127.0.0.1 \
  --port 8080 \
  --ctx-size "$CTX" \
  --n-gpu-layers "$NGL" \
  --jinja \
  --log-prefix
