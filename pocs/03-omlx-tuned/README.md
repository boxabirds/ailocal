# POC 3 — omlx with tuned DFlash env vars

**Result: ✅ ALL 3 TESTS PASS** — but ~2× slower wall-clock than mlx-lm (POC 1).

| Test | Wall (s) | Status |
|---|---|---|
| test1 — bug fix | 88.0 | PASS |
| test2 — new file from spec | 100.4 | PASS |
| test3 — cross-file refactor | 123.3 | **PASS** (hung in Phase 1 with default env) |

**This proves the Phase 1 hang was caused by DFlash's 4096-token cap.** Raising `DFLASH_MAX_CTX` to 32768 and bounding draft KV growth via `DFLASH_DRAFT_WINDOW=4096` lets pi's agent prompts complete instead of evicting into a stuck fallback path.

## Setup

omlx must already be installed and configured (Phase 1):
- target model `Qwen3.6-27B-MLX-8bit` at `~/models/Qwen3.6-27B-MLX-8bit`
- draft model `Qwen3.6-27B-DFlash` at `~/models/Qwen3.6-27B-DFlash`
- per-model settings PUT via admin API: `dflash_enabled=true`, `dflash_draft_model=/Users/julian/models/Qwen3.6-27B-DFlash`, `enable_thinking=false`, `is_default=true`
- API key set in `~/.omlx/settings.json` (saved to `/tmp/omlx_key`)

```bash
./serve.sh    # exports DFLASH_MAX_CTX=32768 DFLASH_DRAFT_WINDOW=4096 then omlx serve
```

## Pi wiring

```bash
KEY=$(cat /tmp/omlx_key)
../eval/configure_pi.sh omlx http://127.0.0.1:8000/v1 "$KEY" "Qwen3.6-27B-MLX-8bit"
```

## Eval

```bash
../eval/run_eval.sh ./results omlx 360
```

## Why slower than mlx-lm despite DFlash

DFlash gets ~3× speedup on **short** prompts (45 tok/s vs 13). But for agent loops:
- pi sends > 4K-token prompts every turn → DFlash falls into "long context" mode
- Even with `DFLASH_DRAFT_WINDOW=4096` bounding draft KV, the verify pass is on the full target context
- omlx's overhead (paged cache, scheduler, multi-engine routing) is paid every turn
- mlx-lm's straight-through path skips all of that

## Required env vars

```
DFLASH_MAX_CTX=32768       # default 4096; raise to cover agent prompts
DFLASH_DRAFT_WINDOW=4096   # default 1024; sliding window for draft KV
DFLASH_VERIFY_LEN=16       # default block_size; cap on verify block length
DFLASH_DRAFT_SINK=64       # default 64; draft KV cache sink size
```

These are not in omlx's admin UI — only via env at server start.
