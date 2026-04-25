# POC 4 — mlx-lm + classic speculative decoding

**Result: BLOCKED at runtime. Architectural incompatibility, not a vocab issue.**

mlx-lm's `--draft-model` cannot accelerate **any** Qwen3.5 / Qwen3.6 target on Apple Silicon today, regardless of which draft is paired with it. The target's hybrid attention scheme uses non-trimmable recurrent caches; mlx-lm's spec-decode rewinds the KV cache on each verify pass and refuses to start when any cache layer is non-trimmable.

## What was tried

Target: `~/models/Qwen3.6-27B-MLX-8bit` (already on disk from POC 1).
Draft: `~/models/Qwen3.5-0.8B-MLX-8bit` (downloaded from `mlx-community/Qwen3.5-0.8B-MLX-8bit`, ~1 GB).
Server: `mlx_lm.server --draft-model <draft> --num-draft-tokens 4` on port 8080.

## Vocab-match verification (passed)

Per the thc1006 bench, vocab mismatch silently disables spec-decode. So before downloading anything I verified:

```bash
# Target
jq 'paths(scalars) as $p | select($p[-1]=="vocab_size") | getpath($p)' \
  /Users/julian/models/Qwen3.6-27B-MLX-8bit/config.json
# -> 248320  (nested under text_config — Qwen3.6 is multimodal)

# Candidate draft (HF API, no download)
curl -s 'https://huggingface.co/mlx-community/Qwen3.5-0.8B-MLX-8bit/raw/main/config.json' \
  | jq '.text_config.vocab_size'
# -> 248320
```

For total certainty I also compared `tokenizer.json` SHA-256 between target (on disk) and draft (HEAD-streamed from HF) — **byte-identical**:

```
87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4  /Users/julian/models/Qwen3.6-27B-MLX-8bit/tokenizer.json
87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4  -  (mlx-community/Qwen3.5-0.8B-MLX-8bit)
```

So vocab is fine. The wall is elsewhere.

## The blocker

First chat-completion request died with:

```
File ".../mlx_lm/generate.py", line 531, in speculative_generate_step
    raise ValueError(
ValueError: Speculative decoding requires a trimmable prompt cache (got {'ArraysCache'}).
```

Source (`mlx_lm/generate.py:529-533`):

```python
if not cache.can_trim_prompt_cache(model_cache):
    types = {type(c).__name__ for c in model_cache if not c.is_trimmable()}
    raise ValueError(
        f"Speculative decoding requires a trimmable prompt cache (got {types})."
    )
```

### Why the cache is non-trimmable

Qwen3.5 / Qwen3.6 use a **hybrid attention** scheme: ~75% Gated Delta Net (GDN, linear-attention / Mamba-style) layers + ~25% standard full-attention layers, interleaved. From `mlx_lm/models/qwen3_5.py:304-305`:

```python
def make_cache(self):
    return [ArraysCache(size=2) if l.is_linear else KVCache() for l in self.layers]
```

`ArraysCache` holds a recurrent state (decay terms + last keys/values). It is fundamentally non-trimmable — you cannot rewind a recurrent state without recomputing the prefix. mlx-lm's spec-decode requires `trim_prompt_cache(...)` after every verify pass to back out rejected draft tokens (`generate.py:589-591`), so it bails early.

The target's `config.json` shows the layer pattern explicitly:

```
text_config.layer_types =
  18 × "linear_attention"  (use ArraysCache → not trimmable)
   6 × "full_attention"    (use KVCache → trimmable)
```

### Why no draft can fix this

The constraint is on the **target**, not the draft. Even with a "perfect" matching draft, the target's GDN cache still cannot be rewound. Confirmed by checking the same `layer_types` field on:

- `mlx-community/Qwen3.5-0.8B-MLX-8bit` — 18 linear / 6 full (same hybrid)
- `unsloth/Qwen3.5-0.8B` — 18 linear / 6 full (same hybrid)

Every Qwen3.5/3.6 variant on HF is hybrid by family design. Picking a non-hybrid drafter (e.g. plain Qwen2 or Qwen3 0.6B) breaks vocab match (151936 vs 248320) — and it wouldn't matter anyway, because the failing cache is the target's.

## Why the thc1006 RTX3090 bench got it working

Their report was vLLM on CUDA, where vLLM has its own custom speculative-decoding plumbing for hybrid models (it can prefill the GDN state in chunks and live-replay-on-reject rather than trim). mlx-lm has no equivalent path. **DFlash** (POC 2 / 3) is z-lab's drop-in answer to exactly this problem — a custom drafter that reuses the target's hybrid forward pass — but mlx-lm can't load DFlash either (custom architecture).

So on Apple Silicon today there are three doors and they're all stuck:
1. mlx-lm + classic spec-decode → **target's GDN cache is non-trimmable** (this POC).
2. mlx-lm + DFlash → **mlx-lm can't load `DFlashDraftModel`** (POC 1's tradeoff).
3. omlx + DFlash → works but slower wall-clock on agent traces (POC 3).
4. vllm-swift + spec-decode → blocked on missing GDN Metal kernels (POC 2).

## Setup

`install.sh` and `serve.sh` are kept in this directory so the negative result is reproducible. The smoke-test stack-trace from a freshly-installed server is at `results/server_error.log`.

```bash
cd pocs/04-mlx-lm-specdec
./install.sh                 # uv venv + uv pip install mlx-lm (mlx-lm 0.31.3)
hf download mlx-community/Qwen3.5-0.8B-MLX-8bit \
  --local-dir ~/models/Qwen3.5-0.8B-MLX-8bit
./serve.sh                   # mlx_lm.server with --draft-model ...

# In another shell — first request fails:
curl -s -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"/Users/julian/models/Qwen3.6-27B-MLX-8bit","messages":[{"role":"user","content":"hi"}],"max_tokens":10}'
# -> server returns 200 then crashes the request thread with the
#    ValueError above. No tokens are emitted.
```

## Eval not run

The full `pi -p` eval was skipped on purpose: with spec-decode failing, mlx-lm would either fall back to non-speculative decoding (duplicating POC 1's result, 37.2 / 62.1 / 74.2 s) or fail every request. Re-running it would consume ~3 minutes per test for no information.

## Comparison vs POC 1

| Dim | POC 1 (mlx-lm baseline) | POC 4 (mlx-lm + spec-decode) |
|---|---|---|
| Server starts | yes | yes |
| First inference | yes (~14 tok/s warm) | **no** — `ValueError: ArraysCache not trimmable` |
| test1 | 37.2s PASS | n/a — blocked |
| test2 | 62.1s PASS | n/a — blocked |
| test3 | 74.2s PASS | n/a — blocked |

## Verdict

**Don't include classic spec-decode in the Phase 2 installer.** It is dead-on-arrival for the entire Qwen3.5/3.6 family on mlx-lm. The Phase 2 recipe should ship POC 1 as-is and (optionally) point users toward POC 3 if they want DFlash.

Revisit if either:
- mlx-lm adds chunked / replay-style spec-decode support for hybrid models (track the `is_trimmable` constraint in `mlx_lm/cache.py`), or
- Apple ships a non-hybrid Qwen3.5/3.6 variant (unlikely; the GDN layers are why the family is fast at all).

## Files

- `install.sh` — uv venv + `uv pip install mlx-lm`. Runs `python -m ensurepip --upgrade` for safety.
- `serve.sh` — `mlx_lm.server --draft-model ... --num-draft-tokens 4` on 127.0.0.1:8080.
- `results/server_error.log` — full stack trace from the failed first request.
