#!/usr/bin/env bash
# Usage: run_eval.sh <results_dir> <provider_name> <pi_timeout_seconds>
#
# Runs the 3 test cases via `pi -p`, capturing wall time, file deltas,
# pi stdout, and a verify-command pass/fail signal.
#
# Assumes pi is configured (pocs/eval/configure_pi.sh has been run for the
# target provider). Each test runs in a fresh copy of pocs/eval/test_cases/<id>/.

set -u

RESULTS_DIR="${1:?usage: run_eval.sh <results_dir> <provider> <timeout>}"
PROVIDER="${2:?provider}"
TIMEOUT="${3:-300}"

REPO="/Users/julian/expts/ailocal"
SRC="$REPO/pocs/eval/test_cases"
PROMPTS="$REPO/pocs/eval/prompts.json"

mkdir -p "$RESULTS_DIR"
SUMMARY="$RESULTS_DIR/summary.md"
: > "$SUMMARY"

echo "# Eval results — provider: $PROVIDER" >> "$SUMMARY"
echo >> "$SUMMARY"
echo "| Test | Wall (s) | Verify | Notes |" >> "$SUMMARY"
echo "|---|---|---|---|" >> "$SUMMARY"

for tid in test1 test2 test3; do
  WORK="$RESULTS_DIR/$tid"
  rm -rf "$WORK"
  mkdir -p "$WORK"
  # Copy fixture files (empty test2 is fine)
  if [ -d "$SRC/$tid" ]; then
    cp -R "$SRC/$tid/." "$WORK/" 2>/dev/null || true
  fi
  # Strip .gitkeep
  rm -f "$WORK/.gitkeep"

  PROMPT=$(python3 -c "import json,sys; d=json.load(open('$PROMPTS')); p=[t for t in d if t['id']=='$tid'][0]; print(p['prompt'])")
  VERIFY_CMD=$(python3 -c "import json,sys; d=json.load(open('$PROMPTS')); p=[t for t in d if t['id']=='$tid'][0]; print(p['verify']['command'])")
  EXPECT=$(python3 -c "import json,sys; d=json.load(open('$PROMPTS')); p=[t for t in d if t['id']=='$tid'][0]; print(p['verify']['expected_substring'])")

  echo "=== $tid ===" | tee -a "$RESULTS_DIR/log.txt"
  cd "$WORK"
  START=$(python3 -c "import time;print(time.perf_counter())")
  set +e
  timeout "$TIMEOUT" pi -p --no-session "$PROMPT" > "$WORK/_pi_stdout.txt" 2> "$WORK/_pi_stderr.txt"
  EXIT=$?
  set -e
  END=$(python3 -c "import time;print(time.perf_counter())")
  WALL=$(python3 -c "print(f'{$END-$START:.1f}')")

  # Run verify
  set +e
  VERIFY_OUT=$(eval "$VERIFY_CMD" 2>&1)
  VERIFY_EXIT=$?
  set -e

  if [ $EXIT -eq 124 ]; then
    STATUS="TIMEOUT"
  elif [ $EXIT -ne 0 ]; then
    STATUS="PI_ERR($EXIT)"
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
