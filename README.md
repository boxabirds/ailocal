# ailocal — recipes for running coding-agent stacks locally on Apple Silicon

This repo collects empirically-tested recipes for running an OpenAI-compatible LLM server + coding-agent CLI **entirely on a Mac** — no cloud, no API keys, no rate limits.

The current target is:

- **Agent**: [pi.dev](https://pi.dev) (custom-OpenAI-provider mode)
- **Model**: Qwen3.6-27B (8-bit MLX, ~33 GB on disk)
- **Server**: [mlx-lm](https://github.com/ml-explore/mlx-lm) (Apple's official MLX inference package)
- **Hardware**: Apple Silicon, ≥ 64 GB unified memory recommended (tested on M5 Max 128 GB, macOS 26.4)

## Why this stack

We benched **three** servers head-to-head on the same model and the same agent prompts (see [`pocs/`](pocs/)):

| POC | Server | Spec decode | All 3 tests pass? | Wall vs winner |
|---|---|---|---|---|
| **[01-mlx-lm](pocs/01-mlx-lm/)** | `mlx_lm.server` | none | ✅ | **1×** |
| [02-vllm-swift](pocs/02-vllm-swift/) | `vllm serve` (Swift/Metal plugin) | DFlash (untested) | ❌ blocked — missing GDN Metal kernels | — |
| [03-omlx-tuned](pocs/03-omlx-tuned/) | `omlx serve` | DFlash (`DFLASH_MAX_CTX=32768`) | ✅ | ~2× slower |
| [04-mlx-lm-specdec](pocs/04-mlx-lm-specdec/) | `mlx_lm.server` | classic `--draft-model` | ❌ blocked — Qwen3.6's hybrid GDN cache is non-trimmable | — |

mlx-lm wins despite having **no** speculative-decoding layer. DFlash's ~3.4× short-prompt speedup (45 vs 13 tok/s) collapses on real agent traces because pi.dev's prompts always exceed 4 K tokens; the verify-pass overhead and scheduler cost wipe the gain.

Full breakdown and gotchas: **[pocs/README.md](pocs/README.md)**.

## Quick start

```bash
# 1. Install everything (idempotent — safe to re-run)
./install.sh

# 2. Start the server (long-running)
./pocs/01-mlx-lm/serve.sh

# 3. In another shell, run the bench
./bench.sh
```

The installer handles: prereq checks (Apple Silicon, RAM, disk, Xcode CLT), `uv` install, HuggingFace auth verification, model download, mlx-lm setup, and pi.dev wiring. Re-running it is safe; each step is gated by a check.

## Reference results — M5 Max 128 GB, macOS 26.4, mlx-lm 0.31.3

`bench.sh` runs in two phases against whatever server pi is currently pointed at:

**Phase A — pure model throughput** (single-shot `/v1/chat/completions`, fixed 50-token prompt, `max_tokens=256`, `temperature=0`, 3 repeats):

| Run | Wall (s) | Completion tokens | tok/s |
|---|---|---|---|
| 1 | 17.6 | 256 | 14.5 |
| 2 | 17.4 | 256 | 14.7 |
| 3 | 17.5 | 256 | 14.6 |

**Median 14.6 tok/s** (variance < 1.5 %).

**Phase B — agent-loop tests** (3 real coding tasks via `pi -p`):

| Test | Wall (s) | Status |
|---|---|---|
| test1 — bug fix in sliding window | 41.9 | ✅ PASS |
| test2 — new word-frequency CLI from spec | 50.8 | ✅ PASS |
| test3 — cross-file refactor | 57.7 | ✅ PASS |

**Total 150 s, 3/3 pass.**

## Layout

```
ailocal/
├── README.md          # this file
├── install.sh         # Phase 2 — resilient one-shot installer
├── bench.sh           # 3-test agent-loop bench with consistent tok/s
├── pocs/              # head-to-head bench of 4 server stacks
│   ├── README.md
│   ├── eval/          # shared eval harness (prompts.json, run_eval.sh, configure_pi.sh)
│   ├── 01-mlx-lm/     # ✅ winner
│   ├── 02-vllm-swift/ # ❌ blocked (GDN Metal kernels)
│   ├── 03-omlx-tuned/ # ✅ but ~2× slower
│   └── 04-mlx-lm-specdec/ # ❌ blocked (non-trimmable cache)
└── CLAUDE.md          # collected hard-won notes for future Claude sessions
```

## Status

- Phase 1 (POCs): complete — see [pocs/README.md](pocs/README.md).
- Phase 2 (installer + bench): in progress.
