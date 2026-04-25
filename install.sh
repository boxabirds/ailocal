#!/usr/bin/env bash
# install.sh — Phase 2 resilient installer for ailocal (mlx-lm + Qwen3.6-27B + pi.dev)
#
# Idempotent: safe to re-run. Each step is gated by a check; only missing
# pieces are installed. Hard failures abort with an actionable message.
#
# What this installs:
#   - Verifies prerequisites (Apple Silicon, macOS, RAM, disk, Xcode CLT)
#   - uv (Astral's Python package manager) if missing
#   - HuggingFace CLI (`hf`) and verifies token has the right scope
#   - Qwen3.6-27B-MLX-8bit model into ~/models/  (~33 GB, gated repo)
#   - mlx-lm into pocs/01-mlx-lm/.venv via uv
#   - pi.dev (npm install -g if missing) and writes ~/.pi/agent/models.json
#   - Smoke test: starts the server, hits /v1/models, kills server
#
# Usage: ./install.sh [--skip-model] [--skip-smoke]

set -uo pipefail

# ---------- Constants ----------
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly POC_DIR="$REPO_ROOT/pocs/01-mlx-lm"
readonly VENV_DIR="$POC_DIR/.venv"
readonly MODELS_DIR="$HOME/models"
readonly MODEL_REPO="unsloth/Qwen3.6-27B-MLX-8bit"
readonly MODEL_LOCAL_DIR="$MODELS_DIR/Qwen3.6-27B-MLX-8bit"
readonly MIN_RAM_GB=32
readonly MIN_FREE_DISK_GB=50
readonly REQUIRED_MACOS_MAJOR=15
readonly MLX_LM_PORT=8080
readonly PI_CONFIG_DIR="$HOME/.pi/agent"

# ---------- Output helpers ----------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_RED=; C_GRN=; C_YLW=; C_BLU=; C_DIM=; C_RST=
fi

step()  { printf "%s==>%s %s\n" "$C_BLU" "$C_RST" "$1"; }
ok()    { printf "%s ✓%s %s\n" "$C_GRN" "$C_RST" "$1"; }
warn()  { printf "%s ⚠%s %s\n" "$C_YLW" "$C_RST" "$1"; }
fail()  { printf "%s ✗%s %s\n" "$C_RED" "$C_RST" "$1" >&2; exit 1; }
note()  { printf "%s   %s%s\n" "$C_DIM" "$1" "$C_RST"; }

# ---------- Args ----------
SKIP_MODEL=0
SKIP_SMOKE=0
for arg in "$@"; do
  case "$arg" in
    --skip-model) SKIP_MODEL=1 ;;
    --skip-smoke) SKIP_SMOKE=1 ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0 ;;
    *) fail "unknown arg: $arg" ;;
  esac
done

# ---------- 1. Prereq checks ----------
step "Checking prerequisites"

# Apple Silicon
if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  fail "Apple Silicon Mac required (got $(uname -s)/$(uname -m))"
fi
ok "Apple Silicon ($(uname -m))"

# macOS version
macos_major=$(sw_vers -productVersion | cut -d. -f1)
if [ "$macos_major" -lt "$REQUIRED_MACOS_MAJOR" ]; then
  fail "macOS $REQUIRED_MACOS_MAJOR or newer required (got $(sw_vers -productVersion))"
fi
ok "macOS $(sw_vers -productVersion)"

# RAM
ram_gb=$(sysctl -n hw.memsize | awk '{printf "%d", $1/1024/1024/1024}')
if [ "$ram_gb" -lt "$MIN_RAM_GB" ]; then
  fail "Need at least ${MIN_RAM_GB} GB RAM, have ${ram_gb} GB. Qwen3.6-27B 8-bit MLX is ~33 GB resident; thrashing into swap on a 16 GB machine will be unusable."
fi
ok "RAM: ${ram_gb} GB"

# Free disk
free_gb=$(df -g "$HOME" | tail -1 | awk '{print $4}')
if [ "$free_gb" -lt "$MIN_FREE_DISK_GB" ]; then
  fail "Need at least ${MIN_FREE_DISK_GB} GB free in \$HOME, have ${free_gb} GB. Model is ~33 GB plus ~5 GB for Python deps."
fi
ok "Free disk on \$HOME: ${free_gb} GB"

# Xcode CLT
if ! xcode-select -p >/dev/null 2>&1; then
  warn "Xcode Command Line Tools not detected"
  note "Run: sudo softwareupdate -i \"Command Line Tools for Xcode 26.4-26.4.1\" --verbose"
  note "(GUI installer 'xcode-select --install' can hang silently with a fake progress bar.)"
  fail "Install Xcode CLT then re-run."
fi
ok "Xcode CLT at $(xcode-select -p)"

# ---------- 2. uv ----------
step "Checking uv"
if ! command -v uv >/dev/null 2>&1; then
  step "Installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh || fail "uv install failed"
  # uv writes to ~/.local/bin or ~/.cargo/bin depending on shell — make sure it's on PATH
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
  command -v uv >/dev/null 2>&1 || fail "uv installed but not on PATH; restart your shell and re-run"
fi
ok "uv $(uv --version | awk '{print $2}')"

# ---------- 3. HuggingFace CLI + token ----------
step "Checking HuggingFace CLI"
if ! command -v hf >/dev/null 2>&1; then
  step "Installing huggingface_hub via uv tool install"
  uv tool install --upgrade "huggingface_hub[cli]" || fail "hf CLI install failed"
fi
ok "hf CLI present"

step "Verifying HuggingFace token"
# Token can come from env or ~/.cache/huggingface/token (older `hf` versions
# don't have `hf auth token` so we don't rely on it).
hf_token="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
if [ -z "$hf_token" ] && [ -f "$HOME/.cache/huggingface/token" ]; then
  hf_token=$(tr -d '[:space:]' < "$HOME/.cache/huggingface/token")
fi
if [ -z "$hf_token" ]; then
  warn "No HF token found (checked \$HF_TOKEN, \$HUGGING_FACE_HUB_TOKEN, ~/.cache/huggingface/token)"
  note "Run: hf auth login"
  fail "HF auth not configured."
fi
hf_whoami=$(curl -fsS -H "Authorization: Bearer $hf_token" \
  https://huggingface.co/api/whoami-v2 2>/dev/null || true)
if [ -z "$hf_whoami" ] || echo "$hf_whoami" | grep -q '"error"'; then
  warn "HF token rejected by API. Run: hf auth login"
  fail "HF token invalid."
fi
hf_user=$(echo "$hf_whoami" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])' 2>/dev/null || echo "?")
ok "HF token user: $hf_user"

# Check fine-grained scope (only matters for fine-grained tokens; classic read tokens are fine)
can_read_gated=$(echo "$hf_whoami" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); fg=d.get("auth",{}).get("accessToken",{}).get("fineGrained"); print("n/a" if not fg else fg.get("canReadGatedRepos", False))' \
  2>/dev/null || echo "n/a")
case "$can_read_gated" in
  "True"|"true"|"n/a")
    ok "HF token scope OK (gated-repo reads: $can_read_gated)" ;;
  *)
    warn "HF fine-grained token is missing 'Read access to contents of all public gated repos'."
    note "Edit token at https://huggingface.co/settings/tokens — enable that scope, then re-run."
    fail "HF token scope insufficient for gated model downloads."
    ;;
esac

# ---------- 4. Model pull ----------
step "Checking target model: $MODEL_REPO"
mkdir -p "$MODELS_DIR"
if [ "$SKIP_MODEL" = "1" ]; then
  warn "Skipping model pull (--skip-model)"
elif [ -d "$MODEL_LOCAL_DIR" ] && [ -f "$MODEL_LOCAL_DIR/config.json" ]; then
  size=$(du -sh "$MODEL_LOCAL_DIR" 2>/dev/null | awk '{print $1}')
  ok "Model already present at $MODEL_LOCAL_DIR ($size)"
else
  step "Downloading model (~33 GB) — this is the slow step"
  hf download "$MODEL_REPO" --local-dir "$MODEL_LOCAL_DIR" \
    || fail "Model download failed. Re-run; hf will resume."
  ok "Model downloaded to $MODEL_LOCAL_DIR"
fi

# ---------- 5. mlx-lm setup ----------
step "Setting up mlx-lm in $VENV_DIR"
if [ ! -d "$VENV_DIR" ]; then
  uv venv --python 3.12 "$VENV_DIR" || fail "uv venv failed"
fi
# uv pip install is idempotent (will be a no-op if mlx-lm already installed at correct version)
uv pip install --python "$VENV_DIR/bin/python" --upgrade mlx-lm \
  || fail "mlx-lm install failed"
ok "mlx-lm: $("$VENV_DIR/bin/python" -c 'import mlx_lm,importlib.metadata as m; print(m.version("mlx-lm"))')"

# ---------- 6. pi.dev ----------
step "Checking pi.dev"
if ! command -v pi >/dev/null 2>&1; then
  warn "pi CLI not found"
  note "Install: npm install -g @pi-dev/cli  (requires Node.js)"
  note "Or visit https://pi.dev for the latest install instructions."
  fail "Install pi.dev then re-run."
fi
ok "pi.dev $(pi --version 2>&1 | head -1)"

step "Wiring pi.dev to mlx-lm"
mkdir -p "$PI_CONFIG_DIR"
"$REPO_ROOT/pocs/eval/configure_pi.sh" mlxlm \
  "http://127.0.0.1:${MLX_LM_PORT}/v1" \
  "EMPTY" \
  "$MODEL_LOCAL_DIR" >/dev/null
ok "pi.dev configured (provider=mlxlm, baseUrl=http://127.0.0.1:${MLX_LM_PORT}/v1)"

# ---------- 7. Smoke test ----------
if [ "$SKIP_SMOKE" = "1" ]; then
  warn "Skipping smoke test (--skip-smoke)"
else
  step "Smoke test: start mlx-lm server and hit /v1/models"
  if lsof -nP -iTCP:${MLX_LM_PORT} -sTCP:LISTEN >/dev/null 2>&1; then
    warn "Port ${MLX_LM_PORT} already in use — assuming an existing server. Skipping spawn."
  else
    "$POC_DIR/serve.sh" >/tmp/ailocal_smoke.log 2>&1 &
    SERVER_PID=$!
    trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
    note "Server PID: $SERVER_PID (logs: /tmp/ailocal_smoke.log)"
    # Wait for /v1/models — up to 60s (model load takes ~5-10s, but cold may be slower)
    for i in $(seq 1 60); do
      if curl -fsS "http://127.0.0.1:${MLX_LM_PORT}/v1/models" >/dev/null 2>&1; then
        ok "Server responding after ${i}s"
        break
      fi
      sleep 1
      if [ "$i" = "60" ]; then
        cat /tmp/ailocal_smoke.log >&2
        fail "Server did not respond within 60s. See /tmp/ailocal_smoke.log."
      fi
    done
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    trap - EXIT
    ok "Smoke test passed"
  fi
fi

# ---------- Done ----------
cat <<EOF

${C_GRN}Install complete.${C_RST}

Next steps:
  1. Start the server (long-running):
     ${C_DIM}\$${C_RST} ./pocs/01-mlx-lm/serve.sh

  2. In another shell, run the bench:
     ${C_DIM}\$${C_RST} ./bench.sh

  3. Or just use pi normally — it's already wired up:
     ${C_DIM}\$${C_RST} pi -p "write a hello world in rust"
EOF
