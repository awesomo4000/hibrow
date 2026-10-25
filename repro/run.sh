#!/usr/bin/env bash
# End-to-end reproducer for the gateway crash in WebSocket.readFrame.
# Usage: repro/run.sh [eof|midframe]     (needs a built zig-out/bin/hibrow)
set -u
MODE=${1:-eof}
HERE=$(cd "$(dirname "$0")/.." && pwd)
BIN=$HERE/zig-out/bin/hibrow
PORT=9555
PROFILE=crashprof
WORK=$(mktemp -d)
mkdir -p "$WORK/$PROFILE"

"$BIN" gateway stop >/dev/null 2>&1 || true

python3 "$HERE/repro/mock_chrome.py" --remote-debugging-port=$PORT \
  --user-data-dir="$WORK/$PROFILE" --close-after=1 --mode="$MODE" &
MOCK=$!
"$BIN" gateway serve 2>"$WORK/gateway.stderr" &
GW=$!
trap 'kill $MOCK $GW 2>/dev/null; rm -rf "$WORK"' EXIT
sleep 0.5

echo "== eval #1 (opens + caches CDP connection, mock answers)"
"$BIN" eval $PROFILE "1+1"; echo "exit=$?"
echo "== eval #2 (mock drops the cached connection; want a clean error)"
"$BIN" eval $PROFILE "2+2"; echo "exit=$?"
sleep 0.3

if ! kill -0 $GW 2>/dev/null; then
  wait $GW; echo "== REPRODUCED: gateway died, status=$?"
  echo "== gateway stderr:"; cat "$WORK/gateway.stderr"
  exit 1
fi
echo "== eval #3 (gateway should have evicted + reconnect)"
"$BIN" eval $PROFILE "3+3"; rc=$?; echo "exit=$rc"
if [ $rc -eq 0 ] && kill -0 $GW 2>/dev/null; then echo "== FIXED: gateway survived and reconnected"; exit 0; fi
echo "== gateway alive but reconnect failed"; cat "$WORK/gateway.stderr"; exit 2
