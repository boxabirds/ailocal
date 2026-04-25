#!/usr/bin/env bash
# POC 3 — omlx with DFLASH context-cap tuned upward.
#
# Default DFLASH_MAX_CTX is 4096 (drafter trained at 3-4K). Pi.dev's agent
# prompt blows past that immediately, triggering an eviction → engine fallback
# that hung in Phase 1. This POC raises the cap to 32K and bounds draft KV
# growth via the documented sliding-window env var.
#
# Reads existing per-model DFlash settings from prior omlx config — assumes
# `dflash_enabled=true` and `dflash_draft_model=/Users/julian/models/Qwen3.6-27B-DFlash`
# are already PUT via the admin API (done in Phase 1).

set -euo pipefail
cd "$(dirname "$0")"

export DFLASH_MAX_CTX=32768
export DFLASH_DRAFT_WINDOW=4096
export DFLASH_VERIFY_LEN=16
export DFLASH_DRAFT_SINK=64

echo "DFLASH_MAX_CTX=$DFLASH_MAX_CTX"
echo "DFLASH_DRAFT_WINDOW=$DFLASH_DRAFT_WINDOW"
echo "DFLASH_VERIFY_LEN=$DFLASH_VERIFY_LEN"
echo "DFLASH_DRAFT_SINK=$DFLASH_DRAFT_SINK"

exec omlx serve --model-dir "$HOME/models" --log-level info --port 8000
