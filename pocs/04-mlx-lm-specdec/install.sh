#!/usr/bin/env bash
# POC 4 — mlx-lm + classic speculative decoding via vanilla Qwen3 draft.
# Per /Users/julian/.claude/CLAUDE.md: use uv (not pyenv venvs).
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d .venv ]; then
  uv venv --python 3.12 .venv
fi
# Some downstream tooling (and `mlx_lm.server` plugins on certain installs)
# expect `pip` inside the venv. ensurepip is harmless if already present.
.venv/bin/python -m ensurepip --upgrade >/dev/null 2>&1 || true
uv pip install --python .venv/bin/python mlx-lm
echo "Installed. Activate with: source .venv/bin/activate"
