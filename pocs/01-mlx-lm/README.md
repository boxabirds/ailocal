# POC 1 — mlx-lm + pi.dev

**Result: ✅ ALL 3 TESTS PASS.**

| Test | Wall (s) | Status |
|---|---|---|
| test1 — off-by-one bug fix in sliding window | 37.2 | PASS |
| test2 — new word-frequency CLI from spec | 62.1 | PASS |
| test3 — cross-file refactor (extract function to new module) | 74.2 | **PASS** (hung on omlx+DFlash) |

Single-turn baseline tok/s: **14.1** (cold load 7.4s, warm 5.5s for 77 tokens).

## Setup

```bash
cd pocs/01-mlx-lm
uv venv --python 3.12 .venv
source .venv/bin/activate
uv pip install mlx-lm
./serve.sh    # mlx_lm.server on 127.0.0.1:8080
```

## Pi wiring

```bash
../eval/configure_pi.sh mlxlm http://127.0.0.1:8080/v1 EMPTY \
  "/Users/julian/models/Qwen3.6-27B-MLX-8bit"
```

`api_key` is unused (mlx-lm has no auth) but pi requires the field; "EMPTY" works.

## Eval

```bash
../eval/run_eval.sh ./results mlxlm 360
```

## Why this works where omlx+DFlash hung

- mlx-lm has no fragile experimental layer (DFlash eviction, paged KV state machine).
- No 4K context guillotine.
- Apple-maintained, stable.
- `--chat-template-args '{"enable_thinking": false}'` cleanly disables Qwen3 thinking by default.

## Tradeoff

- No speculative decoding speedup. ~14 tok/s steady-state vs DFlash's 45 tok/s short-context peak.
- For agent loops (the actual goal), reliability beats peak-burst tok/s — short-context speedup is wasted when pi's prompts always exceed 4K.

## Notes

- mlx-lm has `--draft-model` and `--num-draft-tokens` flags (classic speculative decoding).
  The z-lab DFlash drafter has custom `DFlashDraftModel` architecture and won't load via mlx-lm.
  A vanilla small Qwen3 draft (e.g. 0.6B or 1.7B) would work but vocab-mismatch with 27B target
  needs verification — out of scope for this baseline POC.
- Server warns "not recommended for production" — fine for local recipe.
