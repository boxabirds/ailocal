#!/usr/bin/env bash
# Usage: run_eval_opencode.sh <results_dir> <agent_name> <timeout_seconds>
#
# Same as run_eval.sh but drives the agent via `opencode-local run` instead
# of `pi -p`. Use this when pi isn't working or you want to bench against
# the same agent + tool stack the user actually runs interactively.

set -u

RESULTS_DIR="${1:?usage: run_eval_opencode.sh <results_dir> <agent> <timeout>}"
AGENT="${2:?agent name (e.g. qwen-mlxlm or dsv4-mlxlm)}"
TIMEOUT="${3:-300}"

REPO="/Users/julian/expts/ailocal"
SRC="$REPO/pocs/eval/test_cases"
PROMPTS="$REPO/pocs/eval/prompts.json"
OPENCODE="${OPENCODE_BIN:-$HOME/.local/bin/opencode-local}"

mkdir -p "$RESULTS_DIR"
SUMMARY="$RESULTS_DIR/summary.md"
: > "$SUMMARY"

echo "# Eval results — agent: $AGENT (via opencode-local)" >> "$SUMMARY"
echo >> "$SUMMARY"
echo "| Test | Wall (s) | Verify | Notes |" >> "$SUMMARY"
echo "|---|---|---|---|" >> "$SUMMARY"

for tid in test1 test2 test3; do
  WORK="$RESULTS_DIR/$tid"
  rm -rf "$WORK"
  mkdir -p "$WORK"
  if [ -d "$SRC/$tid" ]; then
    cp -R "$SRC/$tid/." "$WORK/" 2>/dev/null || true
  fi
  rm -f "$WORK/.gitkeep"

  PROMPT=$(python3 -c "import json,sys; d=json.load(open('$PROMPTS')); p=[t for t in d if t['id']=='$tid'][0]; print(p['prompt'])")
  VERIFY_CMD=$(python3 -c "import json,sys; d=json.load(open('$PROMPTS')); p=[t for t in d if t['id']=='$tid'][0]; print(p['verify']['command'])")
  EXPECT=$(python3 -c "import json,sys; d=json.load(open('$PROMPTS')); p=[t for t in d if t['id']=='$tid'][0]; print(p['verify']['expected_substring'])")

  echo "=== $tid ===" | tee -a "$RESULTS_DIR/log.txt"
  cd "$WORK"
  START=$(python3 -c "import time;print(time.perf_counter())")
  set +e
  timeout "$TIMEOUT" "$OPENCODE" run \
    --agent "$AGENT" \
    --dir "$WORK" \
    --dangerously-skip-permissions \
    "$PROMPT" \
    > "$WORK/_opencode_stdout.txt" 2> "$WORK/_opencode_stderr.txt"
  EXIT=$?
  set -e
  END=$(python3 -c "import time;print(time.perf_counter())")
  WALL=$(python3 -c "print(f'{$END-$START:.1f}')")

  set +e
  VERIFY_OUT=$(cd "$WORK" && eval "$VERIFY_CMD" 2>&1)
  VERIFY_EXIT=$?
  set -e

  if [ $EXIT -eq 124 ]; then
    STATUS="TIMEOUT"
  elif [ $EXIT -ne 0 ]; then
    STATUS="OC_ERR($EXIT)"
  elif echo "$VERIFY_OUT" | grep -qF "$EXPECT" && [ $VERIFY_EXIT -eq 0 ]; then
    STATUS="PASS"
  else
    STATUS="FAIL"
  fi

  NOTES=$(echo "$VERIFY_OUT" | head -1 | tr '|' '/' | cut -c1-60)
  echo "| $tid | $WALL | $STATUS | $NOTES |" >> "$SUMMARY"
  echo "$tid: wall=${WALL}s status=$STATUS" | tee -a "$RESULTS_DIR/log.txt"
done

cd "$REPO"
echo "Wrote $SUMMARY"
cat "$SUMMARY"
