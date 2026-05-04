#!/usr/bin/env bash
#
# hibrow parallel stress test
#
# Spawns multiple clients that simultaneously try to control the same browser.
# Each "tagger" writes its name to a DOM element and changes the background
# color in a tight loop. Tests that the gateway serializes correctly — no
# crashes, no garbled responses, and we can see who won at the end.
#
# Usage: ./tests/parallel.sh [--browser chrome|firefox] [--taggers N] [--duration N]
#
set -euo pipefail

HIBROW="./zig-out/bin/hibrow"
PROFILE="test-parallel"
NUM_TAGGERS=20
DURATION=5  # seconds
BROWSER="chrome"
PASS=0
FAIL=0
TOTAL=0

# Parse args
while [ $# -gt 0 ]; do
    case "$1" in
        --browser) BROWSER="$2"; shift 2 ;;
        --taggers) NUM_TAGGERS="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --------------------------------------------------------------------------
# Helpers (same as e2e.sh)
# --------------------------------------------------------------------------

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
bold()  { printf '\033[1m%s\033[0m' "$*"; }

pass() {
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    echo "  $(green PASS) $1"
}

fail() {
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    echo "  $(red FAIL) $1"
    if [ -n "${2:-}" ]; then
        echo "       got: $2"
    fi
}

assert_contains() {
    local output="$1" expected="$2" label="$3"
    if echo "$output" | grep -q "$expected"; then
        pass "$label"
    else
        fail "$label" "$output"
    fi
}

# --------------------------------------------------------------------------
# Setup
# --------------------------------------------------------------------------

echo ""
bold "hibrow parallel stress test"
echo ""
echo "taggers: $NUM_TAGGERS"
echo "duration: ${DURATION}s"
echo "browser: $BROWSER"
echo "profile: $PROFILE"
echo ""

# Clean slate
$HIBROW gateway stop 2>/dev/null || true
sleep 0.5
$HIBROW kill $PROFILE 2>/dev/null || true
sleep 0.5

# Launch a fresh browser
echo "$(bold '==> Setup')"
out=$($HIBROW launch $PROFILE --browser $BROWSER 2>&1)
assert_contains "$out" "\"profile\"" "browser launched"

# Firefox/Marionette needs a moment to be ready
if [ "$BROWSER" = "firefox" ] || [ "$BROWSER" = "ff" ]; then
    sleep 2
fi

# Set up the arena: blank page with a tag element and a counter per tagger
$HIBROW nav $PROFILE "about:blank" > /dev/null 2>&1
sleep 0.3

cat << 'JSEOF' | $HIBROW eval $PROFILE -f- > /dev/null 2>&1
(function() {
document.body.style.cssText = 'margin:0;background:#111;display:flex;flex-direction:column;align-items:center;justify-content:center;height:100vh;font-family:monospace';

var wall = document.createElement('div');
wall.id = 'wall';
wall.style.cssText = 'font-size:72px;font-weight:bold;color:#fff;text-shadow:0 0 30px currentColor;transition:color 0.1s';
wall.textContent = '...';
document.body.appendChild(wall);

var board = document.createElement('div');
board.id = 'scoreboard';
board.style.cssText = 'margin-top:40px;font-size:18px;color:#888;white-space:pre';
board.textContent = 'waiting for taggers...';
document.body.appendChild(board);

var log = document.createElement('div');
log.id = 'log';
log.style.cssText = 'margin-top:20px;font-size:14px;color:#555;max-height:200px;overflow:hidden;white-space:pre';
document.body.appendChild(log);

window._scores = {};
window._log = [];
window._totalWrites = 0;
return 'ready';
})()
JSEOF

echo ""
echo "$(bold '==> Spawning taggers')"

# Colors for each tagger
COLORS=("#ff4444" "#44ff44" "#4444ff" "#ffff44" "#ff44ff"
        "#ff8844" "#44ffff" "#8844ff" "#ff4488" "#88ff44"
        "#4488ff" "#ffaa00" "#00ffaa" "#aa00ff" "#ff0088"
        "#00ff88" "#8800ff" "#ff8800" "#0088ff" "#88ff00")
NAMES=("ALPHA" "BRAVO" "CHARLIE" "DELTA" "ECHO"
       "FOXTROT" "GOLF" "HOTEL" "INDIA" "JULIET"
       "KILO" "LIMA" "MIKE" "NOVEMBER" "OSCAR"
       "PAPA" "QUEBEC" "ROMEO" "SIERRA" "TANGO")

# Temp dir for tagger output
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Spawn taggers as background processes
# Each tagger gets its own JS file (IIFE format works for both Chrome and Firefox)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for i in $(seq 0 $((NUM_TAGGERS - 1))); do
    NAME="${NAMES[$i]}"
    COLOR="${COLORS[$i]}"
    cat > "$TMPDIR/tagger_${NAME}.js" << JSEOF
(function() {
var _wall = document.getElementById('wall');
_wall.textContent = '${NAME}';
_wall.style.color = '${COLOR}';
document.body.style.backgroundColor = '${COLOR}' + '22';
window._scores['${NAME}'] = (window._scores['${NAME}'] || 0) + 1;
window._totalWrites++;
window._log.unshift(window._totalWrites + ': ${NAME}');
if (window._log.length > 20) window._log.pop();
document.getElementById('log').textContent = window._log.join('\\n');
document.getElementById('scoreboard').textContent = Object.entries(window._scores)
    .sort(function(a, b) { return b[1] - a[1]; })
    .map(function(e) { return e[0].padEnd(10) + e[1]; })
    .join('\\n');
return '${NAME}:' + window._scores['${NAME}'];
})()
JSEOF
    (
        end=$((SECONDS + DURATION))
        count=0
        errors=0
        while [ $SECONDS -lt $end ]; do
            out=$($HIBROW eval $PROFILE -f "$TMPDIR/tagger_${NAME}.js" 2>&1) \
                || { errors=$((errors + 1)); continue; }
            count=$((count + 1))
        done
        echo "${NAME} writes=${count} errors=${errors}" > "$TMPDIR/tagger_${NAME}.txt"
    ) &
    echo "  started $NAME ($COLOR)"
done

echo ""
echo "$(bold "==> Racing for ${DURATION}s...")"
echo ""

# Wait for all taggers to finish
wait

# --------------------------------------------------------------------------
# Results
# --------------------------------------------------------------------------

echo "$(bold '==> Tagger results')"
echo ""

total_writes=0
total_errors=0
all_wrote=true

for i in $(seq 0 $((NUM_TAGGERS - 1))); do
    NAME="${NAMES[$i]}"
    if [ -f "$TMPDIR/tagger_${NAME}.txt" ]; then
        result=$(cat "$TMPDIR/tagger_${NAME}.txt")
        writes=$(echo "$result" | grep -o 'writes=[0-9]*' | cut -d= -f2)
        errors=$(echo "$result" | grep -o 'errors=[0-9]*' | cut -d= -f2)
        total_writes=$((total_writes + writes))
        total_errors=$((total_errors + errors))
        printf "  %-10s %3d writes, %d errors\n" "$NAME" "$writes" "$errors"
        if [ "$writes" -eq 0 ]; then
            all_wrote=false
        fi
    else
        printf "  %-10s MISSING OUTPUT\n" "$NAME"
        all_wrote=false
    fi
done

echo ""
echo "  total: $total_writes writes, $total_errors errors"
echo ""

# --------------------------------------------------------------------------
# Assertions
# --------------------------------------------------------------------------

echo "$(bold '==> Assertions')"

# Every tagger should have gotten at least some writes through
if [ "$all_wrote" = true ]; then
    pass "all taggers got writes through the gateway"
else
    fail "some taggers got zero writes"
fi

# Total writes should be substantial (at least 2 per tagger per second)
min_expected=$((NUM_TAGGERS * 2))
if [ "$total_writes" -ge "$min_expected" ]; then
    pass "total writes ($total_writes) >= minimum expected ($min_expected)"
else
    fail "total writes ($total_writes) below minimum ($min_expected)"
fi

# Errors should be low (some are ok under contention, but not most)
max_errors=$((total_writes / 2))
if [ "$total_errors" -le "$max_errors" ]; then
    pass "error rate acceptable ($total_errors errors / $total_writes writes)"
else
    fail "too many errors ($total_errors / $total_writes)"
fi

# Read back the final state — wall should have one of the tagger names
out=$($HIBROW eval $PROFILE "document.getElementById('wall').textContent" 2>&1)
found_winner=false
for i in $(seq 0 $((NUM_TAGGERS - 1))); do
    NAME="${NAMES[$i]}"
    if echo "$out" | grep -q "$NAME"; then
        found_winner=true
        pass "wall shows winner: $NAME"
        break
    fi
done
if [ "$found_winner" = false ]; then
    fail "wall has unexpected content" "$out"
fi

# Read back total from browser's perspective
browser_total=$($HIBROW eval $PROFILE "window._totalWrites" 2>&1 | tr -d '[:space:]')
if [ "$browser_total" -eq "$total_writes" ]; then
    pass "browser saw all $browser_total writes (matches client count)"
else
    # Under serial execution these should match exactly
    fail "browser counted $browser_total but clients counted $total_writes"
fi

# Read back scores from browser
echo ""
echo "$(bold '==> Final scoreboard (from browser DOM)')"
echo ""
$HIBROW eval $PROFILE "document.getElementById('scoreboard').textContent" 2>&1 | tr -d '"'
echo ""

# --------------------------------------------------------------------------
# Cleanup
# --------------------------------------------------------------------------

$HIBROW kill $PROFILE > /dev/null 2>&1 || true
sleep 0.5
rm -rf "$HOME/.hibrow/profiles/$PROFILE" 2>/dev/null || true

# Clean registry
if [ -f ~/.hibrow/profiles.json ]; then
    python3 -c "
import json
try:
    with open('$HOME/.hibrow/profiles.json') as f:
        profiles = json.load(f)
    profiles = [p for p in profiles if p.get('name') != '$PROFILE']
    with open('$HOME/.hibrow/profiles.json', 'w') as f:
        json.dump(profiles, f)
except: pass
" 2>/dev/null || true
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------

echo ""
echo "────────────────────────────────"
echo "  $(bold 'Results'): $TOTAL tests, $(green "$PASS passed"), $([ $FAIL -gt 0 ] && red "$FAIL failed" || echo "$FAIL failed")"
echo "────────────────────────────────"
echo ""

if [ $FAIL -gt 0 ]; then
    exit 1
fi
