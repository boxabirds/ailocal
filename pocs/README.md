# POCs — three paths to running Qwen3.6-27B + pi.dev on Apple Silicon

Three recipes evaluated head-to-head with the same eval harness (`eval/run_eval.sh`):
1. bug fix in an existing file
2. new file from spec
3. cross-file refactor (the case that exposes 4K-context speculative-decoding limits)

All three use the same target model on disk (`~/models/Qwen3.6-27B-MLX-8bit`, 8-bit MLX, ~33 GB) and pi.dev's custom-OpenAI-provider config. Hardware: MacBook Pro M5 Max, 128 GB unified memory, macOS 26.4.

## Headline results

| POC | Server | Spec decode | test1 (s) | test2 (s) | test3 (s) | All pass? |
|---|---|---|---|---|---|---|
| **[01-mlx-lm](01-mlx-lm/)** | `mlx_lm.server` | none | **37.2** | **62.1** | **74.2** | ✅ |
| [02-vllm-swift](02-vllm-swift/) | `vllm serve` (Swift/Metal plugin) | DFlash via `--speculative-config` (untested) | — | — | — | ❌ blocked at runtime |
| [03-omlx-tuned](03-omlx-tuned/) | `omlx serve` | DFlash with tuned `DFLASH_MAX_CTX=32768` | 88.0 | 100.4 | 123.3 | ✅ |
| [04-mlx-lm-specdec](04-mlx-lm-specdec/) | `mlx_lm.server` | classic `--draft-model` (vocab-matched Qwen3.5-0.8B) | — | — | — | ❌ target's hybrid GDN cache is non-trimmable; mlx-lm refuses spec-decode |

**mlx-lm wins on every test, ~2× wall-clock faster than omlx+DFlash for agent loops.**

## Why mlx-lm wins despite no speculation

Phase 1 measured DFlash giving ~3.4× single-turn speedup (45 vs 13 tok/s) on short prompts. But pi.dev's agent prompts are always > 4 K tokens (system prompt + tools + file contents), which:
- Triggered DFlash's hard 4K cap with default config — caused a 12+ min hang in Phase 1.
- Even with `DFLASH_MAX_CTX=32768` raising the cap, the verify pass on long context plus omlx's scheduler/paged-cache overhead means the DFlash speedup never materializes for multi-turn workflows.

mlx-lm has **no speculative layer at all** but its straight-through decode path beats DFlash's overhead-laden path on real agent traces. ~14 tok/s sustained; the reliability and the lack of fragile experimental layers carry the day.

**And mlx-lm's classic `--draft-model` spec-decode is not an option here either** — see [POC 4](04-mlx-lm-specdec/). Qwen3.5/3.6's hybrid GDN attention uses non-trimmable `ArraysCache`, which mlx-lm's spec-decode rewinds on every verify pass. The check fires before any tokens come back, regardless of which (vocab-matched) draft is paired with it.

## Setup

| POC | Install | Time |
|---|---|---|
| 01-mlx-lm | `uv venv && uv pip install mlx-lm` | seconds |
| 02-vllm-swift | git clone + swift build + ensurepip + pip install vllm | ~5 min build (compiled wheels) |
| 03-omlx-tuned | `brew tap jundot/omlx && brew install omlx` (requires Apple CLT for macOS 26) | ~3 min |

## Hard-won gotchas (worth bringing into Phase 2's installer)

### Apple CLT (required for any brew install on macOS 26)
A stale standalone CLT from before macOS 26 fails brew's preflight check even when Xcode is current and `xcode-select` points at it. Apple's GUI installer can hang silently with a fake progress bar; CLI is `sudo softwareupdate -i "Command Line Tools for Xcode 26.4-26.4.1" --verbose`.

### HF token scope (required for the DFlash drafter)
`z-lab/Qwen3.6-27B-DFlash` is auto-gated. The user's token can be account-gate-accepted but still 403 file-resolve calls if it's a fine-grained token without "Read access to contents of all public gated repos you can access". Verify via `curl https://huggingface.co/api/whoami-v2` — `auth.accessToken.fineGrained.canReadGatedRepos` must be `true`.

### omlx defaults the DFlash drafter as the *served* model on first discovery
Wrong — DFlash is a drafter not a standalone. PUT `is_default: true` on the target via `/admin/api/models/{id}/settings` after starting the server.

### omlx DFlash uses absolute path, NOT model id
`dflash_draft_model: "Qwen3.6-27B-DFlash"` makes omlx try to fetch `Qwen3.6-27B-DFlash` from HF (no org prefix → 404 → silent fallback to plain VLM, no DFlash). Use `/Users/julian/models/Qwen3.6-27B-DFlash`.

### omlx DFlash 4K cap is `DFLASH_MAX_CTX` env var
Not exposed in admin UI. There are five env vars total (`DFLASH_MAX_CTX`, `DFLASH_DRAFT_WINDOW`, `DFLASH_VERIFY_LEN`, `DFLASH_DRAFT_SINK`, `DFLASH_QUANTIZE_DRAFT`).

### mlx-lm classic spec-decode is dead-on-arrival for Qwen3.5/3.6
Vocab match isn't the wall (it's fine — both vocab 248320 and tokenizer.json byte-identical between target and `mlx-community/Qwen3.5-0.8B-MLX-8bit`). The wall is the **target's** hybrid GDN attention: 18 of 24 layers use `ArraysCache` (recurrent state), and mlx-lm's spec-decode requires every cache layer to be trimmable to back out rejected drafts. `ValueError: Speculative decoding requires a trimmable prompt cache (got {'ArraysCache'})` is raised before the first token. No draft model can fix this; the constraint is on the target. See `04-mlx-lm-specdec/README.md` for the full trace and source-code citations.

### vllm-swift on macOS 26
- No `arm64_tahoe` bottle. Brew formula tries source build, hits Swift PM's own `sandbox-exec` block.
- Source build via `./scripts/install.sh` works (~97s swift compile).
- vLLM dep install: **uv refuses** because of CUDA-only deps on the dependency tree; **pip works**. Need `python -m ensurepip` first if using a uv venv.
- For Qwen3.6-27B specifically: GDN Metal kernels missing in default metallib → fatal error at first inference. Marked blocked.

### pi.dev config
pi reads `~/.pi/agent/models.json`. Each POC's eval rewrites that file via `pocs/eval/configure_pi.sh <provider> <baseUrl> <apiKey> <model>`. `omlx launch pi --model X` does the same automatically for omlx.

## Recommendation

Build the Phase-2 installer around **POC 1 (mlx-lm)**. Reasons:
- Apple-maintained, stable, no experimental layers.
- Simplest install (one `uv pip install` away).
- Fastest agent-loop wall-clock of the three.
- No hardcoded context caps to tune.
- Works the moment models are on disk.

Keep POC 3 (omlx + DFlash + tuned env) documented as the **speed-burner alternative** for users who specifically want DFlash and don't mind the slightly slower agent path. The 45 tok/s short-prompt peak might matter for non-agent uses (chat, single-turn coding assistance).

POC 2 (vllm-swift) can be revisited when upstream fixes GDN kernel compilation. Worth tracking — if/when fixed, `--speculative-config dflash` could give the best of both worlds (DFlash speedup + vllm's mature long-context handling).
