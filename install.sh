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
# Usage: ./install.sh [--skip-model] [--skip-smoke] [--auto-start MODE]
#                     [--idle-stop-minutes N]
#
# --auto-start MODE controls how mlx-lm starts up:
#   wrapper  (default) — installs `pi-local` (and `mlxlm-start`/`mlxlm-stop`)
#                         into ~/.local/bin. `pi-local` starts the server on
#                         demand if it isn't running, then runs pi normally.
#                         An idle-stop watcher kills the server after N minutes
#                         of no requests (default 5; --idle-stop-minutes 0 to
#                         disable). You can also stop manually: `mlxlm-stop`.
#   none               — you start it yourself: ./pocs/01-mlx-lm/serve.sh
#   launchd            — installs ~/Library/LaunchAgents/com.ailocal.mlxlm.plist
#                         and loads it. Server starts at login, restarts on
#                         crash, and holds ~33 GB until you `launchctl unload`.
#                         Idle-stop is disabled here (would conflict with
#                         KeepAlive).
#
# --idle-stop-minutes N
#   Wrapper-mode only. Default 5. Set to 0 to disable.

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
readonly USER_BIN_DIR="$HOME/.local/bin"
readonly LAUNCH_AGENT_LABEL="com.ailocal.mlxlm"
readonly LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"

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
AUTO_START="wrapper"
IDLE_STOP_MINUTES=5
i=1
while [ $i -le $# ]; do
  arg="${!i}"
  case "$arg" in
    --skip-model) SKIP_MODEL=1 ;;
    --skip-smoke) SKIP_SMOKE=1 ;;
    --auto-start)
      i=$((i+1)); AUTO_START="${!i:-}"
      case "$AUTO_START" in
        none|wrapper|launchd) ;;
        *) fail "--auto-start must be one of: none, wrapper, launchd (got: $AUTO_START)" ;;
      esac ;;
    --idle-stop-minutes)
      i=$((i+1)); IDLE_STOP_MINUTES="${!i:-}"
      [[ "$IDLE_STOP_MINUTES" =~ ^[0-9]+$ ]] \
        || fail "--idle-stop-minutes must be a non-negative integer (got: $IDLE_STOP_MINUTES)"
      ;;
    -h|--help)
      sed -n '2,32p' "$0"
      exit 0 ;;
    *) fail "unknown arg: $arg" ;;
  esac
  i=$((i+1))
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

# ---------- 7. Auto-start (optional) ----------
step "Configuring auto-start mode: $AUTO_START"
case "$AUTO_START" in
  none)
    note "Manual mode — start with ./pocs/01-mlx-lm/serve.sh, stop with Ctrl-C."
    ;;
  wrapper)
    mkdir -p "$USER_BIN_DIR" "$HOME/.pi"
    for cmd in mlxlm-start mlxlm-stop mlxlm-idle-watcher pi-local opencode-local; do
      ln -sf "$REPO_ROOT/bin/$cmd" "$USER_BIN_DIR/$cmd"
    done
    cat > "$HOME/.pi/ailocal.conf" <<EOF
# ailocal config — sourced by mlxlm-start. Edit to retune.
MLXLM_IDLE_SECONDS=$((IDLE_STOP_MINUTES * 60))
EOF
    ok "Installed mlxlm-start, mlxlm-stop, mlxlm-idle-watcher, pi-local, opencode-local into $USER_BIN_DIR"
    if [ "$IDLE_STOP_MINUTES" -gt 0 ]; then
      ok "Idle-stop: server will shut down after $IDLE_STOP_MINUTES min of no requests"
    else
      warn "Idle-stop disabled (--idle-stop-minutes 0); use mlxlm-stop to free RAM"
    fi
    case ":$PATH:" in
      *":$USER_BIN_DIR:"*) : ;;
      *) warn "$USER_BIN_DIR is not on your PATH"
         note "Add to your shell rc: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
    esac
    note "Run 'pi-local …' or 'opencode-local …' to use the local Qwen3.6 server."
    note "Both auto-start the server on first call. mlxlm-stop frees the ~33 GB."
    note "Edit ~/.pi/ailocal.conf to retune the idle-stop window."
    ;;
  launchd)
    mkdir -p "$USER_BIN_DIR" "$(dirname "$LAUNCH_AGENT_PLIST")"
    for cmd in mlxlm-start mlxlm-stop pi-local; do
      ln -sf "$REPO_ROOT/bin/$cmd" "$USER_BIN_DIR/$cmd"
    done
    cat >"$LAUNCH_AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LAUNCH_AGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${REPO_ROOT}/bin/mlxlm-start</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>MLXLM_FOREGROUND</key><string>1</string>
    <key>MLXLM_IDLE_SECONDS</key><string>0</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${HOME}/Library/Logs/mlxlm.out.log</string>
  <key>StandardErrorPath</key><string>${HOME}/Library/Logs/mlxlm.err.log</string>
</dict>
</plist>
EOF
    # Reload if already loaded
    launchctl unload "$LAUNCH_AGENT_PLIST" 2>/dev/null || true
    launchctl load "$LAUNCH_AGENT_PLIST" || fail "launchctl load failed"
    ok "LaunchAgent loaded: $LAUNCH_AGENT_LABEL"
    note "Server will start at login and on every reboot. ~33 GB held until unloaded."
    note "Stop:    launchctl unload $LAUNCH_AGENT_PLIST"
    note "Restart: launchctl unload \$1 && launchctl load \$1   (where \$1 is the plist path)"
    note "Logs:    ~/Library/Logs/mlxlm.{out,err}.log"
    ;;
esac

# ---------- 8. Smoke test ----------
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
EOF
case "$AUTO_START" in
  none) cat <<EOF

To use it (manual mode):
  1. Start the server (in its own shell — leave running):
     ${C_DIM}\$${C_RST} ./pocs/01-mlx-lm/serve.sh
  2. In any other shell:
     ${C_DIM}\$${C_RST} pi -p "write hello world in rust"
  3. Stop the server: Ctrl-C in the serve.sh shell. ~33 GB freed.

  Run the bench: ${C_DIM}\$${C_RST} ./bench.sh
EOF
  ;;
  wrapper) cat <<EOF

To use it (wrapper mode):
  ${C_DIM}\$${C_RST} pi-local -p "write hello world in rust"
  ${C_DIM}\$${C_RST} opencode-local --agent qwen-mlxlm
        — both auto-start the server on first use (model loads ~5-10s)
        — server keeps running while you use either tool
        — idle watcher stops it after ${IDLE_STOP_MINUTES} min of no agent process + no requests
        — ${C_DIM}\$${C_RST} mlxlm-stop  → kills the server now, frees ~33 GB

  Optional aliases (in ~/.zshrc or ~/.bashrc):
    alias pi=pi-local
    alias opencode=opencode-local

  Run the bench: ${C_DIM}\$${C_RST} ./bench.sh   (server must be up; \`pi-local --version\` will start it)
EOF
  ;;
  launchd) cat <<EOF

To use it (launchd mode — server is already running):
  ${C_DIM}\$${C_RST} pi -p "write hello world in rust"

  Stop:    ${C_DIM}\$${C_RST} launchctl unload $LAUNCH_AGENT_PLIST
  Restart: ${C_DIM}\$${C_RST} launchctl unload $LAUNCH_AGENT_PLIST && launchctl load $LAUNCH_AGENT_PLIST
  Logs:    ~/Library/Logs/mlxlm.{out,err}.log
  Memory:  ~33 GB held continuously until you unload.

  Run the bench: ${C_DIM}\$${C_RST} ./bench.sh
EOF
  ;;
esac
