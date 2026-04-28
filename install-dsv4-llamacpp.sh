#!/usr/bin/env bash
# bootstrap-dsv4.sh — recreate the pi.dev + DeepSeek-V4-Flash + llama.cpp stack
# from a clean machine. Sister script to install.sh (which targets the Qwen3.6
# + mlx-lm path). Idempotent: safe to re-run; only missing pieces are added.
#
# What this stack is, with sources:
#
#   pi.dev (the agent)
#     npm      @mariozechner/pi-coding-agent
#     repo     https://github.com/badlogic/pi-mono
#     tui dep  @mariozechner/pi-tui (same repo, packages/tui)
#
#   llama.cpp (the inference server)
#     fork     https://github.com/antirez/llama.cpp-deepseek-v4-flash
#     why      upstream llama.cpp doesn't yet have DeepSeek-V4-Flash; this
#              fork adds the model + a hand-written V4 chat template that
#              actually wires up tool-calling.
#
#   GGUF weights
#     repo     https://huggingface.co/antirez/deepseek-v4-gguf
#     file     DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2.gguf
#     size     ~87 GB
#     quant    Q2 routed experts, Q4/Q8 attention/output (antirez recipe)
#
#   Repo wrappers (this repo, bin/)
#     pi-local            health-checks server + auto-starts before pi
#     mlxlm-start         launches the active serve.sh, registers PID
#     mlxlm-stop          kills server cleanly
#     mlxlm-idle-watcher  tails server log; kills after N idle seconds
#
#   Config (~/.pi/)
#     agent/models.json   pi's provider config (llamacpp baseUrl + model)
#     ailocal.conf        runtime selector (AILOCAL_SERVE_SCRIPT, idle secs)
#     mlxlm-active-script auto-written marker of which serve.sh is active
#
# Usage:
#   ./bootstrap-dsv4.sh                  # full bootstrap
#   ./bootstrap-dsv4.sh --skip-model     # skip 87 GB download (assume present)
#   ./bootstrap-dsv4.sh --skip-build     # skip llama.cpp build (assume built)
#   ./bootstrap-dsv4.sh --skip-smoke     # skip end-to-end smoke test

set -uo pipefail

# ---------- Constants ----------
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly POC_DIR="$REPO_ROOT/pocs/07-llamacpp-dsv4"
readonly LLAMA_DIR="$POC_DIR/llama.cpp"
readonly LLAMA_BIN="$LLAMA_DIR/build/bin/llama-server"
readonly LLAMA_REPO_URL="https://github.com/antirez/llama.cpp-deepseek-v4-flash.git"
readonly TEMPLATE_PATH="$LLAMA_DIR/models/templates/deepseek-ai-DeepSeek-V4.jinja"

readonly MODELS_DIR="$HOME/models/deepseek-v4-gguf"
readonly GGUF_FILE="DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2.gguf"
readonly GGUF_PATH="$MODELS_DIR/$GGUF_FILE"
readonly GGUF_HF_REPO="antirez/deepseek-v4-gguf"

readonly PI_CONFIG_DIR="$HOME/.pi"
readonly PI_MODELS_JSON="$PI_CONFIG_DIR/agent/models.json"
readonly AILOCAL_CONF="$PI_CONFIG_DIR/ailocal.conf"
readonly LOCAL_BIN="$HOME/.local/bin"

readonly REQUIRED_MACOS_MAJOR=14
readonly MIN_RAM_GB=120          # 87 GB weights + KV cache + headroom
readonly MIN_FREE_DISK_GB=120    # 87 GB GGUF + 5 GB build artifacts + slack
readonly HEALTH_URL="http://127.0.0.1:8080/v1/models"

# ---------- Args ----------
SKIP_MODEL=0
SKIP_BUILD=0
SKIP_SMOKE=0
for arg in "$@"; do
  case "$arg" in
    --skip-model) SKIP_MODEL=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --skip-smoke) SKIP_SMOKE=1 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# ---------- Logging ----------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_RED=; C_GRN=; C_YLW=; C_BLU=; C_DIM=; C_RST=
fi
step() { printf "%s==>%s %s\n" "$C_BLU" "$C_RST" "$1"; }
ok()   { printf "%s ✓%s %s\n" "$C_GRN" "$C_RST" "$1"; }
warn() { printf "%s ⚠%s %s\n" "$C_YLW" "$C_RST" "$1"; }
fail() { printf "%s ✗%s %s\n" "$C_RED" "$C_RST" "$1" >&2; exit 1; }
note() { printf "   %s%s%s\n" "$C_DIM" "$1" "$C_RST"; }

# ---------- 1. Prereqs ----------
step "Checking prerequisites"

[ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ] \
  || fail "Apple Silicon Mac required (got $(uname -s)/$(uname -m))"
ok "Apple Silicon ($(uname -m))"

macos_major=$(sw_vers -productVersion | cut -d. -f1)
[ "$macos_major" -ge "$REQUIRED_MACOS_MAJOR" ] \
  || fail "macOS $REQUIRED_MACOS_MAJOR or newer required (got $(sw_vers -productVersion))"
ok "macOS $(sw_vers -productVersion)"

ram_gb=$(sysctl -n hw.memsize | awk '{printf "%d", $1/1024/1024/1024}')
[ "$ram_gb" -ge "$MIN_RAM_GB" ] \
  || fail "Need at least ${MIN_RAM_GB} GB RAM, have ${ram_gb} GB. The GGUF is 87 GB and is mmap'd into wired Metal pages — under-spec'd machines will swap or fail to allocate."
ok "RAM: ${ram_gb} GB"

free_gb=$(df -g "$HOME" | tail -1 | awk '{print $4}')
[ "$free_gb" -ge "$MIN_FREE_DISK_GB" ] \
  || fail "Need at least ${MIN_FREE_DISK_GB} GB free in \$HOME, have ${free_gb} GB. GGUF is 87 GB; plus llama.cpp build artifacts."
ok "Free disk on \$HOME: ${free_gb} GB"

xcode-select -p >/dev/null 2>&1 \
  || fail "Xcode Command Line Tools missing. Run: sudo softwareupdate -i \"Command Line Tools for Xcode 26.4-26.4.1\" --verbose"
ok "Xcode CLT at $(xcode-select -p)"

command -v cmake >/dev/null 2>&1 \
  || fail "cmake missing. Install: brew install cmake"
ok "cmake $(cmake --version | head -1 | awk '{print $3}')"

command -v git >/dev/null 2>&1 || fail "git missing"
ok "git $(git --version | awk '{print $3}')"

command -v node >/dev/null 2>&1 \
  || fail "node missing. Install via nvm: https://github.com/nvm-sh/nvm — needs node ≥20"
node_major=$(node -v | sed 's/^v//' | cut -d. -f1)
[ "$node_major" -ge 20 ] || fail "node ≥20 required, have $(node -v)"
ok "node $(node -v)"

command -v npm >/dev/null 2>&1 || fail "npm missing"
ok "npm $(npm -v)"

if ! command -v hf >/dev/null 2>&1; then
  if command -v uv >/dev/null 2>&1; then
    step "Installing huggingface_hub CLI via uv"
    uv tool install --upgrade "huggingface_hub[cli]" || fail "hf CLI install failed"
  else
    fail "hf CLI missing and uv not present. Install uv first: curl -LsSf https://astral.sh/uv/install.sh | sh"
  fi
fi
ok "hf CLI present"

# ---------- 2. pi.dev ----------
step "Checking pi.dev"
if ! command -v pi >/dev/null 2>&1; then
  step "Installing @mariozechner/pi-coding-agent globally"
  npm install -g @mariozechner/pi-coding-agent || fail "pi.dev install failed"
fi
PI_VERSION=$(pi --version 2>/dev/null || echo "?")
ok "pi.dev v$PI_VERSION"

# ---------- 3. llama.cpp (antirez fork) ----------
step "Checking llama.cpp (antirez fork)"
mkdir -p "$POC_DIR"
if [ ! -d "$LLAMA_DIR/.git" ]; then
  step "Cloning $LLAMA_REPO_URL"
  git clone --depth 1 "$LLAMA_REPO_URL" "$LLAMA_DIR" || fail "git clone failed"
fi
ok "Source at $LLAMA_DIR"

[ -f "$TEMPLATE_PATH" ] || fail "Chat template missing at $TEMPLATE_PATH — fork may have moved it. Without this, tool calls don't work."
ok "V4 jinja template present"

if [ "$SKIP_BUILD" -eq 0 ]; then
  if [ ! -x "$LLAMA_BIN" ]; then
    step "Building llama.cpp with Metal (this takes a few minutes)"
    cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build" \
      -DGGML_METAL=ON \
      -DLLAMA_CURL=OFF \
      -DCMAKE_BUILD_TYPE=Release \
      || fail "cmake configure failed"
    cmake --build "$LLAMA_DIR/build" --target llama-server -j \
      || fail "cmake build failed"
  fi
  [ -x "$LLAMA_BIN" ] || fail "Build did not produce $LLAMA_BIN"
  ok "llama-server built at $LLAMA_BIN"
else
  warn "Skipping build (--skip-build)"
fi

# ---------- 4. GGUF weights ----------
step "Checking GGUF weights"
mkdir -p "$MODELS_DIR"
if [ "$SKIP_MODEL" -eq 0 ]; then
  if [ ! -f "$GGUF_PATH" ]; then
    step "Downloading $GGUF_FILE (~87 GB) from $GGUF_HF_REPO"
    note "URL: https://huggingface.co/$GGUF_HF_REPO"
    note "This will take a while. Resume-friendly — re-run if it dies."
    hf download "$GGUF_HF_REPO" "$GGUF_FILE" \
      --local-dir "$MODELS_DIR" \
      || fail "hf download failed"
  fi
  [ -f "$GGUF_PATH" ] || fail "GGUF still missing at $GGUF_PATH"
  size_gb=$(du -g "$GGUF_PATH" | awk '{print $1}')
  [ "$size_gb" -ge 80 ] || fail "GGUF size $size_gb GB is suspiciously small (expected ~87 GB) — partial download?"
  ok "GGUF at $GGUF_PATH ($size_gb GB)"
else
  warn "Skipping model download (--skip-model)"
  [ -f "$GGUF_PATH" ] || warn "GGUF not present — server will fail to start"
fi

# ---------- 5. Wrapper scripts ----------
step "Linking wrapper scripts to $LOCAL_BIN"
mkdir -p "$LOCAL_BIN"
chmod +x "$REPO_ROOT"/bin/* "$POC_DIR"/serve.sh 2>/dev/null || true
for w in pi-local mlxlm-start mlxlm-stop mlxlm-idle-watcher; do
  src="$REPO_ROOT/bin/$w"
  dst="$LOCAL_BIN/$w"
  [ -x "$src" ] || fail "Missing wrapper: $src"
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    continue
  fi
  ln -sfn "$src" "$dst"
done
ok "Symlinks: pi-local, mlxlm-start, mlxlm-stop, mlxlm-idle-watcher"
case ":$PATH:" in
  *":$LOCAL_BIN:"*) ;;
  *) warn "$LOCAL_BIN not on \$PATH. Add to your shell rc: export PATH=\"$LOCAL_BIN:\$PATH\"" ;;
esac

# ---------- 6. pi config ----------
step "Writing pi.dev config"
mkdir -p "$(dirname "$PI_MODELS_JSON")"
cat > "$PI_MODELS_JSON" <<JSON
{
  "providers": {
    "llamacpp": {
      "baseUrl": "http://127.0.0.1:8080/v1",
      "api": "openai-completions",
      "apiKey": "EMPTY",
      "authHeader": true,
      "models": [
        {
          "id": "$GGUF_PATH",
          "name": "$GGUF_PATH",
          "reasoning": false,
          "input": ["text"],
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
          "contextWindow": 262144,
          "maxTokens": 16384
        }
      ]
    }
  }
}
JSON
ok "Wrote $PI_MODELS_JSON"

# ailocal.conf — preserve any existing settings; only set the keys we manage
mkdir -p "$PI_CONFIG_DIR"
touch "$AILOCAL_CONF"
set_conf() {
  local key="$1" val="$2"
  if grep -q "^$key=" "$AILOCAL_CONF"; then
    # macOS sed needs explicit empty -i ''
    sed -i '' "s|^$key=.*|$key=\"$val\"|" "$AILOCAL_CONF"
  else
    printf '%s="%s"\n' "$key" "$val" >> "$AILOCAL_CONF"
  fi
}
set_conf AILOCAL_SERVE_SCRIPT "$POC_DIR/serve.sh"
grep -q "^MLXLM_IDLE_SECONDS=" "$AILOCAL_CONF" || echo 'MLXLM_IDLE_SECONDS=300' >> "$AILOCAL_CONF"
ok "Wrote $AILOCAL_CONF (AILOCAL_SERVE_SCRIPT → POC 7)"

# ---------- 7. Smoke test ----------
if [ "$SKIP_SMOKE" -eq 0 ]; then
  step "Smoke test: start server, hit /v1/models, stop"
  if curl -fsS -m 1 "$HEALTH_URL" >/dev/null 2>&1; then
    note "server already running — leaving it up after smoke test"
    ALREADY_UP=1
  else
    ALREADY_UP=0
    "$LOCAL_BIN/mlxlm-start" >/dev/null || fail "mlxlm-start failed"
  fi
  for i in $(seq 1 60); do
    curl -fsS -m 1 "$HEALTH_URL" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -fsS -m 2 "$HEALTH_URL" >/dev/null 2>&1 \
    || fail "Server didn't respond at $HEALTH_URL within 60s. Check ~/Library/Logs/mlxlm.log"
  ok "Server healthy at $HEALTH_URL"

  step "Round-trip: pi -p 'reply with TEST OK'"
  out=$(timeout 60 pi -p --no-session "Reply with exactly: TEST OK" 2>&1 | tail -5)
  echo "$out" | grep -q "TEST OK" \
    || { echo "$out"; fail "pi round-trip didn't return expected phrase"; }
  ok "pi round-trip OK"

  if [ "$ALREADY_UP" -eq 0 ]; then
    "$LOCAL_BIN/mlxlm-stop" >/dev/null 2>&1 || true
    note "stopped server (was started by smoke test)"
  fi
else
  warn "Skipping smoke test (--skip-smoke)"
fi

# ---------- Done ----------
echo
ok "Bootstrap complete."
echo
echo "Next steps:"
echo "  pi-local                 # interactive (TUI — see iTerm2 caveats)"
echo "  pi-local -p 'hello'      # non-interactive (recommended in iTerm2)"
echo "  mlxlm-stop               # free RAM when done"
