#!/usr/bin/env bash
# bench.sh — repeatable benchmark for whichever LLM server pi is currently
# pointed at. Two phases:
#
#   Phase A: throughput probe — 3 direct /v1/chat/completions calls with a
#     fixed prompt + fixed max_tokens. Measures *pure model* tok/s with no
#     agent-loop overhead. Reports min/median/max so you can see variance.
#
#   Phase B: agent-loop tests — runs the same 3 pi -p tasks used in pocs/.
#     Measures end-to-end wall-clock and pass/fail.
#
# Output: bench/results/<timestamp>/summary.md (+ raw JSON).
#
# Usage: ./bench.sh [--label NAME] [--phase a|b|both] [--probe-tokens N]

set -uo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RESULTS_ROOT="$REPO_ROOT/bench/results"
readonly PI_MODELS_JSON="$HOME/.pi/agent/models.json"
readonly PROBE_REPEATS=3
readonly DEFAULT_PROBE_TOKENS=256
readonly TIMEOUT_AGENT_S=360

# ---------- Args ----------
LABEL=""
PHASE="both"
PROBE_TOKENS="$DEFAULT_PROBE_TOKENS"
DRIVER="pi"             # pi | opencode
OC_AGENT=""             # required when DRIVER=opencode
for ((i=1; i<=$#; i++)); do
  case "${!i}" in
    --label)         i=$((i+1)); LABEL="${!i}" ;;
    --phase)         i=$((i+1)); PHASE="${!i}" ;;
    --probe-tokens)  i=$((i+1)); PROBE_TOKENS="${!i}" ;;
    --driver)        i=$((i+1)); DRIVER="${!i}" ;;
    --agent)         i=$((i+1)); OC_AGENT="${!i}" ;;
    -h|--help)
      sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown arg: ${!i}" >&2; exit 1 ;;
  esac
done

if [ -t 1 ]; then
  C_GRN=$'\033[32m'; C_RED=$'\033[31m'; C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_GRN=; C_RED=; C_BLU=; C_DIM=; C_RST=
fi
step() { printf "%s==>%s %s\n" "$C_BLU" "$C_RST" "$1"; }
fail() { printf "%s ✗%s %s\n" "$C_RED" "$C_RST" "$1" >&2; exit 1; }

# ---------- Read pi config ----------
[ -f "$PI_MODELS_JSON" ] || fail "$PI_MODELS_JSON not found. Run install.sh first."

read -r PROVIDER BASE_URL API_KEY MODEL_ID <<<"$(python3 - "$PI_MODELS_JSON" <<'PY'
import json, sys, pathlib
p = json.loads(pathlib.Path(sys.argv[1]).read_text())
prov = next(iter(p["providers"]))
cfg = p["providers"][prov]
m = cfg["models"][0]["id"]
print(prov, cfg["baseUrl"], cfg.get("apiKey", "EMPTY"), m)
PY
)"
[ -n "${MODEL_ID:-}" ] || fail "Failed to parse pi config"

if [ -z "$LABEL" ]; then LABEL="$PROVIDER"; fi
TS=$(date +%Y%m%d-%H%M%S)
RUN_DIR="$RESULTS_ROOT/${TS}-${LABEL}"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.md"
PROBE_JSON="$RUN_DIR/probe.json"
AGENT_JSON="$RUN_DIR/agent.json"

step "Bench config"
echo "  provider:   $PROVIDER"
echo "  baseUrl:    $BASE_URL"
echo "  model:      $MODEL_ID"
echo "  results:    $RUN_DIR"

{
  echo "# Bench results — $LABEL"
  echo
  echo "- timestamp: \`$TS\`"
  echo "- provider:  \`$PROVIDER\`"
  echo "- baseUrl:   \`$BASE_URL\`"
  echo "- model:     \`$MODEL_ID\`"
  echo
} > "$SUMMARY"

# ---------- Server reachability ----------
step "Pinging server"
curl -fsS "$BASE_URL/models" \
  ${API_KEY:+-H "Authorization: Bearer $API_KEY"} \
  >/dev/null \
  || fail "Server at $BASE_URL not responding. Start it first: ./pocs/01-mlx-lm/serve.sh"

# ---------- Phase A: throughput probe ----------
if [ "$PHASE" = "a" ] || [ "$PHASE" = "both" ]; then
  step "Phase A — throughput probe ($PROBE_REPEATS repeats, max_tokens=$PROBE_TOKENS)"

  # Fixed prompt that should produce a long, deterministic-ish answer.
  PROBE_PROMPT='Write a Python implementation of merge sort with a recursive helper, type annotations, and a docstring. Then write 4 test cases with assertions. Only output the Python code. No commentary.'

  python3 - "$BASE_URL" "$API_KEY" "$MODEL_ID" "$PROBE_PROMPT" "$PROBE_TOKENS" "$PROBE_REPEATS" "$PROBE_JSON" <<'PY'
import json, sys, time, urllib.request

base, api_key, model, prompt, max_tokens, repeats, out_path = sys.argv[1:]
max_tokens = int(max_tokens)
repeats = int(repeats)

results = []
for i in range(repeats):
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.0,
        "stream": False,
    }).encode()
    req = urllib.request.Request(base + "/chat/completions", data=body,
        headers={"Content-Type": "application/json",
                 **({"Authorization": f"Bearer {api_key}"} if api_key and api_key != "EMPTY" else {})})
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=600) as r:
        resp = json.loads(r.read())
    elapsed = time.perf_counter() - t0
    usage = resp.get("usage", {})
    pt = usage.get("prompt_tokens", 0)
    ct = usage.get("completion_tokens", 0)
    tok_s = ct / elapsed if elapsed > 0 else 0.0
    results.append({"run": i+1, "wall_s": round(elapsed, 3),
                    "prompt_tokens": pt, "completion_tokens": ct,
                    "tok_s": round(tok_s, 2)})
    print(f"  run {i+1}: wall={elapsed:.2f}s  prompt={pt}  completion={ct}  -> {tok_s:.2f} tok/s")

with open(out_path, "w") as f:
    json.dump(results, f, indent=2)

ts = sorted(r["tok_s"] for r in results)
median = ts[len(ts)//2]
print(f"  median: {median:.2f} tok/s   min: {ts[0]:.2f}   max: {ts[-1]:.2f}")
PY

  {
    echo "## Phase A — throughput probe"
    echo
    echo "Single-shot \`/v1/chat/completions\` calls. Fixed prompt, max_tokens=$PROBE_TOKENS, temperature=0."
    echo
    echo "| Run | Wall (s) | Prompt tokens | Completion tokens | tok/s |"
    echo "|---|---|---|---|---|"
    python3 - "$PROBE_JSON" <<'PY'
import json, sys
for r in json.load(open(sys.argv[1])):
    print(f"| {r['run']} | {r['wall_s']} | {r['prompt_tokens']} | {r['completion_tokens']} | {r['tok_s']} |")
PY
    python3 - "$PROBE_JSON" <<'PY'
import json, sys, statistics
rs = json.load(open(sys.argv[1]))
ts = [r["tok_s"] for r in rs]
print()
print(f"**Median: {statistics.median(ts):.2f} tok/s** (min {min(ts):.2f}, max {max(ts):.2f})")
PY
    echo
  } >> "$SUMMARY"
fi

# ---------- Phase B: agent-loop tests ----------
if [ "$PHASE" = "b" ] || [ "$PHASE" = "both" ]; then
  case "$DRIVER" in
    pi)
      step "Phase B — agent-loop tests (3 pi -p tasks, timeout ${TIMEOUT_AGENT_S}s each)"
      EVAL_SCRIPT="$REPO_ROOT/pocs/eval/run_eval.sh"
      EVAL_ARG2="$LABEL"
      ;;
    opencode)
      [ -n "$OC_AGENT" ] || { echo "ERROR: --driver opencode requires --agent NAME" >&2; exit 2; }
      step "Phase B — agent-loop tests (3 opencode-local --agent $OC_AGENT tasks, timeout ${TIMEOUT_AGENT_S}s each)"
      EVAL_SCRIPT="$REPO_ROOT/pocs/eval/run_eval_opencode.sh"
      EVAL_ARG2="$OC_AGENT"
      ;;
    *) echo "ERROR: --driver must be 'pi' or 'opencode' (got $DRIVER)" >&2; exit 2 ;;
  esac
  AGENT_DIR="$RUN_DIR/agent"
  mkdir -p "$AGENT_DIR"
  "$EVAL_SCRIPT" "$AGENT_DIR" "$EVAL_ARG2" "$TIMEOUT_AGENT_S" \
    > "$AGENT_DIR/run_eval.stdout" 2> "$AGENT_DIR/run_eval.stderr" \
    || true   # individual test failures shouldn't abort bench

  # The eval harness already wrote $AGENT_DIR/summary.md and per-test dirs.
  # Re-parse its log.txt to build clean JSON.
  python3 - "$AGENT_DIR" "$AGENT_JSON" <<'PY'
import json, pathlib, re, sys
agent_dir = pathlib.Path(sys.argv[1])
out = []
for line in (agent_dir/"log.txt").read_text().splitlines():
    m = re.match(r"^(test\d+): wall=([\d.]+)s status=(\S+)", line)
    if m:
        out.append({"test": m.group(1), "wall_s": float(m.group(2)), "status": m.group(3)})
pathlib.Path(sys.argv[2]).write_text(json.dumps(out, indent=2))
for r in out:
    print(f"  {r['test']}: wall={r['wall_s']}s  status={r['status']}")
PY

  {
    echo "## Phase B — agent-loop tests"
    echo
    if [ "$DRIVER" = "opencode" ]; then
      echo "Three real coding tasks via \`opencode-local run --agent $OC_AGENT\` against the same target server."
    else
      echo "Three real coding tasks via \`pi -p\` against the same target server."
    fi
    echo
    cat "$AGENT_DIR/summary.md" | sed -n '/^|/p'
    echo
    python3 - "$AGENT_JSON" <<'PY'
import json, sys
rs = json.load(open(sys.argv[1]))
total = sum(r["wall_s"] for r in rs)
passes = sum(1 for r in rs if r["status"] == "PASS")
print(f"**Total wall: {total:.1f}s — {passes}/{len(rs)} pass**")
PY
    echo
  } >> "$SUMMARY"
fi

# ---------- Done ----------
{
  echo "## Files"
  echo
  echo "- \`probe.json\` — Phase A raw results"
  echo "- \`agent.json\` — Phase B raw results"
  echo "- \`agent/\` — per-test stdout/stderr + verify outputs"
} >> "$SUMMARY"

step "Done"
echo "  $SUMMARY"
echo
cat "$SUMMARY"
