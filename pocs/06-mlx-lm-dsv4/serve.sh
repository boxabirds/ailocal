#!/usr/bin/env bash
# POC 6 — mlx-lm (PR #1192) + DeepSeek-V4-Flash-2bit-DQ.
#
# This venv is built from the unmerged PR
#   https://github.com/ml-explore/mlx-lm/pull/1192
# which adds the `deepseek_v4` model class. Released mlx-lm (≤ 0.31.3) cannot
# load this model. The PR also requires transformers PR #45643 from source
# (tokenizer fix); both are installed into this venv at install time.
#
# Same OpenAI-compatible HTTP server as POC 1, just a different venv +
# different on-disk model.
set -euo pipefail
cd "$(dirname "$0")"
source .venv/bin/activate
exec python -m mlx_lm.server \
  --model "$HOME/models/DeepSeek-V4-Flash-2bit-DQ" \
  --host 127.0.0.1 \
  --port 8080
