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

## Quick start — three ways to run it

`install.sh` always sets up uv + the model + mlx-lm + pi config. The `--auto-start` flag picks how the server lifecycle works. Pick the one that matches how you'll actually use it:

### A. Manual (default) — only running when you say so

```bash
./install.sh
./pocs/01-mlx-lm/serve.sh   # in its own terminal — Ctrl-C to stop
pi -p "write hello world in rust"   # in another terminal
```

You explicitly start and stop. ~33 GB only held while `serve.sh` is running.

### B. Wrapper — `pi-local` starts on demand, idle-stops after 5 min

```bash
./install.sh --auto-start wrapper
# Adds to ~/.local/bin: pi-local, mlxlm-start, mlxlm-stop, mlxlm-idle-watcher
# Writes ~/.pi/ailocal.conf with MLXLM_IDLE_SECONDS=300
```

Then from any directory:

```bash
pi-local -p "explain this codebase"
# First call:        spawns mlx-lm + idle-watcher (~5-10 s model load), then runs pi.
# Subsequent calls:  instant — server is already up.
# After 5 min idle:  watcher polls the access log and kills the server automatically.
# Next call:         restarts everything from scratch.

mlxlm-stop                          # explicit stop — also clears the watcher
```

How the idle-stop works: the watcher polls every 30 s, compares the mlx-lm log file's mtime to "now". Every HTTP request mlx-lm handles writes a line to the log, so the mtime is exactly the last-request timestamp. After `MLXLM_IDLE_SECONDS` of staleness, the watcher kills the server and exits. There's no per-call timer — only one watcher per server, and a long-running interactive `pi-local` REPL keeps the server alive as long as it makes API calls.

Tune it:

```bash
./install.sh --auto-start wrapper --idle-stop-minutes 15   # change at install
echo MLXLM_IDLE_SECONDS=900 > ~/.pi/ailocal.conf            # or edit afterwards
./install.sh --auto-start wrapper --idle-stop-minutes 0    # disable entirely
```

Optional: `alias pi=pi-local` in your shell rc and plain `pi` becomes auto-start too.

This is the right mode if `pi` use is bursty and you don't want a 33 GB resident process between sessions.

### C. launchd — server is always running on login

```bash
./install.sh --auto-start launchd
# Writes ~/Library/LaunchAgents/com.ailocal.mlxlm.plist and loads it.
# RunAtLoad + KeepAlive: starts at login, restarts if it crashes.
```

```bash
pi -p "..."   # always works, no warmup, no wrapper
```

Lifecycle:

```bash
launchctl unload ~/Library/LaunchAgents/com.ailocal.mlxlm.plist   # stop, frees RAM
launchctl load   ~/Library/LaunchAgents/com.ailocal.mlxlm.plist   # start again
# logs: ~/Library/Logs/mlxlm.{out,err}.log
```

This is the right mode if you use pi every day and the 33 GB resident cost is fine.

### What the installer does (any mode)

prereq checks (Apple Silicon, RAM ≥ 32 GB, disk ≥ 50 GB free, Xcode CLT) → `uv` → HuggingFace token + scope verify → download `unsloth/Qwen3.6-27B-MLX-8bit` (~33 GB, resumable) → uv venv with `mlx-lm` → write `~/.pi/agent/{models,settings}.json` → optional smoke test. Idempotent.

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
├── install.sh         # resilient one-shot installer
├── bench.sh           # 3-test agent-loop bench with consistent tok/s
├── bin/                  # symlink targets used by --auto-start wrapper/launchd
│   ├── mlxlm-start       # spawn the mlx-lm server (idempotent)
│   ├── mlxlm-stop        # kill the running server (and its idle watcher)
│   ├── mlxlm-idle-watcher # polls log mtime; kills server after N minutes idle
│   └── pi-local          # `pi` wrapper that auto-starts the server first
├── pocs/              # head-to-head bench of 4 server stacks
│   ├── README.md
│   ├── eval/          # shared eval harness (prompts.json, run_eval.sh, configure_pi.sh)
│   ├── 01-mlx-lm/     # ✅ winner
│   ├── 02-vllm-swift/ # ❌ blocked (GDN Metal kernels)
│   ├── 03-omlx-tuned/ # ✅ but ~2× slower
│   └── 04-mlx-lm-specdec/ # ❌ blocked (non-trimmable cache)
└── CLAUDE.md          # collected hard-won notes for future Claude sessions
```

## Honest caveat on speed

**~14.6 tok/s is not fast.** Frontier APIs (Claude/GPT) are 5-10× faster on the same prompts. If you bench heavily and the latency annoys you, this stack isn't going to win you back. What it does win:

- Zero per-token cost.
- Zero rate limits.
- Code never leaves your machine.
- Works offline (after the model is cached).

If you're just trying it out: use **wrapper mode**, run `mlxlm-stop` when you're done, and decide later whether it's worth keeping the LaunchAgent loaded.

## Status

- Phase 1 (POCs): complete — see [pocs/README.md](pocs/README.md).
- Phase 2 (installer + bench + auto-start): complete.
