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

`install.sh` (no flags) sets up uv + the model + **mlx-vlm** (vision-capable) + pi config + an opencode wrapper that has Exa websearch and the full opencode tool suite enabled by default. `--auto-start` picks the lifecycle; `--text-only` opts out of vision.

### A. Wrapper (default) — agent-local commands, idle-stops after 5 min

```bash
./install.sh
# Defaults: vision ON, Exa websearch ON, tools ON, idle-stop = 5 min.
# Adds to ~/.local/bin: pi-local, opencode-local, mlxlm-start, mlxlm-stop,
#                        mlxlm-idle-watcher
# Writes ~/.pi/ailocal.conf with MLXLM_IDLE_SECONDS=300
```

Two agent wrappers ship — both do the same thing for their respective agent: ensure the local server is up, then `exec` the real binary so all the agent's flags pass through unchanged.

```bash
pi-local -p "explain this codebase"           # pi.dev against the local model
opencode-local                                # opencode TUI, qwen-mlxlm agent, Exa+tools+vision on
```

(`opencode-local` injects `--agent qwen-mlxlm` if you don't pass one — opencode otherwise defaults to whatever's first in `opencode.json`. Pass `--agent foo` to override; the installer leaves your other agents untouched.)

Lifecycle either way:

```bash
# First call:        spawns mlx-lm + idle-watcher (~5-10 s model load).
# Subsequent calls:  instant — server is already up.

# After you stop using either agent:
#   - watcher polls every 30 s
#   - skipped while any tracked agent (pi, opencode) is alive
#   - once no agent is running AND the access log has been idle for 5 min,
#     the server is killed automatically
mlxlm-stop                          # explicit stop — also clears the watcher
```

**How the idle-stop decides:** every 30 s, the watcher asks two questions in order:

1. **Is any tracked agent process running?** (`pgrep -x pi` and `pgrep -x opencode`). pi.dev's launcher uses `#!/usr/bin/env node` which makes the kernel set `argv[0]` to `pi`; opencode is a Go binary whose `argv[0]` is `opencode`. Both match cleanly. If any is alive → skip the kill check entirely.
2. **Has the access log been quiet for `MLXLM_IDLE_SECONDS`?** (file mtime gap; every HTTP request mlx-lm handles writes a line). If yes → kill the server.

A long REPL session where you're typing/reading (zero API calls for 10 min) does **not** trigger a kill — the server only goes away after the agent exits *and* nothing has hit the API for the configured window.

**Failure modes are self-healing.** No cooperative state to leak: `pgrep` is a live OS snapshot, log mtime is filesystem-managed, the watcher pid file is `kill -0`-verified before any spawn. If the agent crashes, the watcher just stops finding it on the next poll. If the watcher dies, the next `*-local` call spawns a new one.

**Tune it:**

```bash
./install.sh --idle-stop-minutes 15                        # change at install
echo MLXLM_IDLE_SECONDS=900 > ~/.pi/ailocal.conf           # or edit afterwards
./install.sh --idle-stop-minutes 0                         # disable entirely (manual stop only)
```

**Optional aliases** (in `~/.zshrc` or `~/.bashrc`) so plain `pi` / `opencode` also auto-start the server:

```bash
alias pi=pi-local
alias opencode=opencode-local
```

> Caveat: the agent gate matches anything whose `argv[0]` is literally `pi` or `opencode`. If an unrelated binary on your machine has one of those names (rare), the watcher will treat it as a live agent session and refuse to shut the server down.

#### opencode setup (handled automatically)

`install.sh` patches `~/.config/opencode/opencode.json` for you if opencode is installed (it merges into your existing config rather than overwriting). It adds a `mlxlm` provider pointing at `127.0.0.1:8080/v1` and a `qwen-mlxlm` agent. After install, just run:

```bash
opencode-local                       # default agent is qwen-mlxlm
opencode-local --agent qwen-mlxlm    # or be explicit
```

If you don't have opencode yet: `brew install opencode`, then re-run `install.sh` to pick up the patch.

#### Screenshots / vision input — on by default

`./install.sh` (no flags) wires up **mlx-vlm**, so `pi-local` and `opencode-local` accept image attachments out of the box. Same on-disk Qwen3.6-27B model — the checkpoint already includes the vision tower; mlx-lm just ignored it. The installer also patches both client configs:

- `~/.pi/agent/models.json`: `input: ["text", "image"]`
- `~/.config/opencode/opencode.json` (qwen-mlxlm agent): `attachment: true`, `modalities.input: ["text","image"]`

Cost: ~600 MB of extra disk for `torch + torchvision` (transformers' `Qwen3VLVideoProcessor` hard-imports them even if you only send images), and ~+2 GB peak resident memory while a request with an image is being served. To skip vision and use text-only `mlx-lm` instead:

```bash
./install.sh --text-only
```

Verify it works (the random-token test — proves the vision tower is actually grounded, not just confabulating):

```bash
SECRET=$(python3 -c 'import secrets; print(secrets.token_urlsafe(8))')
echo "secret in image: $SECRET"

# any python with PIL installed; if you don't have one, the mlx-vlm venv has PIL:
~/.local/share/uv/venv/bin/python <<EOF || /Users/julian/expts/ailocal/pocs/05-mlx-vlm/.venv/bin/python <<EOF
from PIL import Image, ImageDraw
img = Image.new("RGB", (640, 96), "white")
ImageDraw.Draw(img).text((10, 30), "$SECRET", fill="black")
img.save("/tmp/v.png")
EOF

# IMPORTANT: prompt comes BEFORE --file in opencode (yargs variadic-array
# greed will otherwise eat your prompt as another file path)
opencode-local run \
  "Output only the exact text shown in the image, nothing else, no quotes." \
  --file=/tmp/v.png
```

If the response contains the same `$SECRET` you generated, vision is fully wired. Two known caveats worth re-running this on your own checkpoint:

1. **opencode arg ordering** — put the prompt first, then `--file=...`. The `-f /tmp/v.png "prompt"` form has yargs treat the prompt as another file path and you'll get `Error: File not found: <your prompt>`. Annoying, not fatal.
2. **mlx-vlm issue [#1057](https://github.com/Blaizzy/mlx-vlm/issues/1057)** (open as of 2026-04-26) describes silent vision-tower loss on `qwen3_5_moe` checkpoints — the server returns 200 with plausible-sounding text but the model never saw the image. The empirical test above on the **dense 27B** checkpoint passes, so it isn't affected. If you switch to a 35B-A3B MoE variant (or another `qwen3_5_moe` model), re-run this test before trusting the output.

#### opencode + Exa web search — on by default (anonymous), key optional

opencode ships with built-in [Exa](https://exa.ai)-powered web search via a hosted MCP server. With a custom provider like `mlxlm` it's hidden unless `OPENCODE_ENABLE_EXA=true` is exported. **`opencode-local` does that for you automatically** — the agent always has the websearch tool. The remaining choice is whether your calls are anonymous or authenticated.

Two env vars matter (verified against opencode 1.4.0's bundled source):

| Var | Set by `opencode-local`? | What it does |
|---|---|---|
| `OPENCODE_ENABLE_EXA` | **yes, automatically** | Reveals the Exa tools to the agent. |
| `EXA_API_KEY` | only if you provide one | Passed as a query param to `mcp.exa.ai/mcp`. Without it, opencode hits the endpoint anonymously — works for a quick try but rate-limiting is opaque. With a free key, you get a real per-month quota. |

To get an authenticated free-tier key (recommended for sustained use):

1. Sign up at [exa.ai](https://exa.ai) and verify your email. Their pricing page shows the current monthly request quota.
2. Generate an API key in the Exa dashboard ("API Keys" — typically at `dashboard.exa.ai/api-keys`).
3. Persist it via the installer or by editing the conf file directly:

   ```bash
   ./install.sh --exa-api-key "exa_..."         # writes EXA_API_KEY into ~/.pi/ailocal.conf
   # or, if you prefer to edit by hand:
   #   echo 'EXA_API_KEY="exa_..."' >> ~/.pi/ailocal.conf
   ```

   `opencode-local` sources `~/.pi/ailocal.conf` and exports the key into opencode's environment. A shell-env `EXA_API_KEY` (e.g. set in `~/.zshrc`) wins over the conf file — useful if you want different keys in different shells.

4. Verify:

   ```bash
   opencode-local run \
     "Use websearch to find the current Apple MLX version on GitHub. Cite the URL."
   ```

   You'll see a `websearch` tool call in the output and a real URL in the answer. Without Exa, the agent would say it has no web tools or guess from training data.

#### opencode + MCP servers (your own, beyond Exa)

opencode also speaks the MCP protocol natively, so any MCP server (local stdio or remote SSE/HTTP) plugs in without code changes. Two ways to wire one up:

**A. CLI** — opencode ships subcommands for managing MCP entries:

```bash
opencode mcp add        # interactive: name, command/url, env vars
opencode mcp list       # what's wired
opencode mcp auth       # OAuth dance for remote servers that need it
opencode mcp debug      # tail traffic to/from a server
```

**B. Edit `~/.config/opencode/opencode.json`** — the same shape the installer already writes for the `mlxlm` provider. Add an `mcp.<name>` block; opencode picks it up on next launch:

```jsonc
{
  "mcp": {
    "linear": {
      "type": "remote",
      "url": "https://mcp.linear.app/sse",
      "enabled": true
    },
    "my-local-tool": {
      "type": "local",
      "command": ["node", "/path/to/server.js"],
      "environment": { "API_KEY": "..." },
      "enabled": true
    }
  }
}
```

Once an MCP server is wired, its tools appear to the agent the same way the built-in tools do — no change needed to the `qwen-mlxlm` agent block. You can scope which agents see which MCP server via the `mcp` field on an agent if you want to limit tool surface area.

### B. Manual — only running when you say so

```bash
./install.sh --auto-start none
./pocs/05-mlx-vlm/serve.sh   # vision build (default); use 01-mlx-lm/serve.sh if you installed --text-only
pi -p "write hello world in rust"   # in another terminal
```

You explicitly start and stop. ~33 GB only held while `serve.sh` is running. No helper scripts get added to `~/.local/bin`. Pick this if you don't want anything daemon-shaped on your system.

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

prereq checks (Apple Silicon, RAM ≥ 32 GB, disk ≥ 50 GB free, Xcode CLT) → `uv` → HuggingFace token + scope verify → download `unsloth/Qwen3.6-27B-MLX-8bit` (~33 GB, resumable) → uv venv with `mlx-vlm` (or `mlx-lm` for `--text-only`) → write `~/.pi/agent/{models,settings}.json` → patch `~/.config/opencode/opencode.json` (provider + agent + image modalities) → write `~/.pi/ailocal.conf` (idle-stop window, default agent, optional `EXA_API_KEY`) → optional smoke test. Idempotent.

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
│   ├── mlxlm-idle-watcher # polls process+log; kills server after N minutes idle
│   ├── pi-local          # `pi` wrapper that auto-starts the server first
│   └── opencode-local    # `opencode` wrapper, same auto-start behavior
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
