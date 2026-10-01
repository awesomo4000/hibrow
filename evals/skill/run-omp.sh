#!/usr/bin/env bash
# Run the hibrow skill test battery against any model available in the `omp` CLI.
# Usage: ./run-omp.sh "<omp-model>"   e.g. ./run-omp.sh "gpt-5-mini"
# The model string is whatever your omp resolves (fuzzy name or provider/name).
#
# Each task is a fresh, non-interactive omp run that knows hibrow only from
# `hibrow --skill`, acting against the local fixture. Then grade.sh scores it.
set -u
MODEL="${1:?usage: run-omp.sh <omp-model>}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WRAP="${HIBROW_BROWSER:-}"
export PATH="$REPO/zig-out/bin:$PATH"
FX="file://$REPO/evals/skill/fixture.html"

# Fresh headless gateway (HIBROW_BROWSER must be in the gateway's env).
hibrow gateway stop >/dev/null 2>&1; sleep 1
hibrow ls >/dev/null 2>&1; sleep 1

PROF=(ev1 ev2 ev3 ev4 ev5 ev6)
TASK=(
"Store the exact text content of the element #fact into window.__answer."
"Read the table #data and store it into window.__answer as an array of objects, one object per data row, each shaped like {Name:<name>, Score:<score>}."
"Click the #inc button exactly 3 times, then store the text content of #count into window.__answer."
"Put the text hibrow into the #name input so the app commits it. This is a React-style controlled input: a naive value assignment will NOT register. After it commits, store window.__committed into window.__answer."
"An element #late appears a short moment after load. Wait for it to appear, then store its text content into window.__answer."
"Clicking #load triggers a network fetch. Capture the page network traffic, click #load, then store the URL of the captured request into window.__answer."
)

for i in 0 1 2 3 4 5; do
  p="${PROF[$i]}"; t="${TASK[$i]}"
  prompt="You are using the hibrow CLI (already on PATH). Learn it by running 'hibrow --skill' FIRST; that is your ONLY source of hibrow knowledge (do not read its source). Then launch a chrome session named $p, navigate it to $FX, and do this task: $t  Store your final result in window.__answer via a hibrow eval. Do NOT kill the session. Be efficient; use as few hibrow commands as possible."
  echo "=== [$MODEL] task $((i+1)) ($p) ==="
  timeout 300 omp -p --no-session --model "$MODEL" --cwd "$REPO" "$prompt" 2>&1 | tail -2
done

echo "=== GRADING [$MODEL] ==="
"$REPO/evals/skill/grade.sh" hibrow
rc=$?
for p in "${PROF[@]}"; do hibrow kill "$p" >/dev/null 2>&1; done
hibrow gateway stop >/dev/null 2>&1
exit $rc
