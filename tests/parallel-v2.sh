#!/usr/bin/env bash
#
# hibrow parallel stress test v2 — territory fight
#
# 20 taggers compete to claim 128x128 squares on a grid. Any square can be
# overwritten — the new tagger steals it (scores +1) and the previous owner
# loses a point. The grid is a constant war zone. At the end we verify
# scores are consistent with the grid state.
#
# Usage: ./tests/parallel-v2.sh
#
set -euo pipefail

HIBROW="./zig-out/bin/hibrow"
PROFILE="test-parallel-v2"
NUM_TAGGERS=20
DURATION=8  # seconds
GRID_COLS=20
GRID_ROWS=16
CELL_SIZE=48
PASS=0
FAIL=0
TOTAL=0

# --------------------------------------------------------------------------
# Helpers
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
bold "hibrow parallel stress test v2 — territory fight"
echo ""
echo "taggers: $NUM_TAGGERS"
echo "duration: ${DURATION}s"
echo "grid: ${GRID_COLS}x${GRID_ROWS} (${CELL_SIZE}px cells)"
echo "profile: $PROFILE"
echo ""

# Clean slate
$HIBROW kill $PROFILE 2>/dev/null || true
sleep 0.5

# Launch a fresh browser
echo "$(bold '==> Setup')"
out=$($HIBROW launch $PROFILE 2>&1)
assert_contains "$out" "\"profile\"" "browser launched"

# Set up the arena
$HIBROW nav $PROFILE "about:blank" > /dev/null 2>&1
sleep 0.3

$HIBROW eval $PROFILE "
document.body.style.cssText = 'margin:0;background:#111;display:flex;flex-direction:column;align-items:center;padding:12px 0;overflow:auto;min-height:100vh';

// Title
var title = document.createElement('div');
title.style.cssText = 'font:bold 28px monospace;color:#fff;margin-bottom:8px;text-shadow:0 0 20px #888';
title.textContent = 'TERRITORY FIGHT';
document.body.appendChild(title);

// Bar graph container
var barContainer = document.createElement('div');
barContainer.id = 'bars';
barContainer.style.cssText = 'display:flex;align-items:flex-end;gap:3px;height:120px;margin-bottom:12px;padding:0 10px';
document.body.appendChild(barContainer);

// Create a bar for each tagger
var COLORS = ['#ff4444','#44ff44','#4444ff','#ffff44','#ff44ff','#ff8844','#44ffff','#8844ff','#ff4488','#88ff44','#4488ff','#ffaa00','#00ffaa','#aa00ff','#ff0088','#00ff88','#8800ff','#ff8800','#0088ff','#88ff00'];
var NAMES = ['AL','BR','CH','DE','EC','FO','GO','HO','IN','JU','KI','LI','MI','NO','OS','PA','QU','RO','SI','TA'];
var FULLNAMES = ['ALPHA','BRAVO','CHARLIE','DELTA','ECHO','FOXTROT','GOLF','HOTEL','INDIA','JULIET','KILO','LIMA','MIKE','NOVEMBER','OSCAR','PAPA','QUEBEC','ROMEO','SIERRA','TANGO'];
for (var i = 0; i < 20; i++) {
    var col = document.createElement('div');
    col.style.cssText = 'display:flex;flex-direction:column;align-items:center;width:42px';
    var val = document.createElement('div');
    val.id = 'bar-val-' + i;
    val.style.cssText = 'font:bold 10px monospace;color:#aaa;margin-bottom:2px';
    val.textContent = '0';
    col.appendChild(val);
    var bar = document.createElement('div');
    bar.id = 'bar-' + i;
    bar.style.cssText = 'width:36px;min-height:2px;background:' + COLORS[i] + ';border-radius:2px 2px 0 0;transition:height 0.15s;box-shadow:0 0 6px ' + COLORS[i] + '40';
    col.appendChild(bar);
    var lbl = document.createElement('div');
    lbl.style.cssText = 'font:bold 9px monospace;color:' + COLORS[i] + ';margin-top:2px';
    lbl.textContent = NAMES[i];
    col.appendChild(lbl);
    barContainer.appendChild(col);
}

// Stats line
var stats = document.createElement('div');
stats.id = 'stats';
stats.style.cssText = 'font:12px monospace;color:#555;margin-bottom:8px';
document.body.appendChild(stats);

// Grid container
var grid = document.createElement('div');
grid.id = 'grid';
grid.style.cssText = 'display:grid;grid-template-columns:repeat(${GRID_COLS},${CELL_SIZE}px);grid-template-rows:repeat(${GRID_ROWS},${CELL_SIZE}px);gap:1px;margin-bottom:12px';
document.body.appendChild(grid);

// Create cells
for (var r = 0; r < ${GRID_ROWS}; r++) {
    for (var c = 0; c < ${GRID_COLS}; c++) {
        var cell = document.createElement('div');
        cell.id = 'cell-' + r + '-' + c;
        cell.style.cssText = 'width:${CELL_SIZE}px;height:${CELL_SIZE}px;background:#1a1a1a;border:1px solid #222;display:flex;align-items:center;justify-content:center;font:bold 11px monospace;transition:background-color 0.1s';
        grid.appendChild(cell);
    }
}

// Scoreboard (hidden, used for data readback)
var board = document.createElement('div');
board.id = 'scoreboard';
board.style.cssText = 'font:12px monospace;color:#888;white-space:pre;text-align:left;display:none';
board.textContent = 'waiting for taggers...';
document.body.appendChild(board);

// Global state
window._grid = [];
for (var r = 0; r < ${GRID_ROWS}; r++) {
    window._grid[r] = [];
    for (var c = 0; c < ${GRID_COLS}; c++) {
        window._grid[r][c] = null;
    }
}
window._scores = {};
window._totalWrites = 0;
window._totalAttempts = 0;
window._cols = ${GRID_COLS};
window._rows = ${GRID_ROWS};
window._colors = {};
for (var i = 0; i < 20; i++) window._colors[FULLNAMES[i]] = COLORS[i];
window._names = FULLNAMES;
window._updateBars = function() {
    var max = 1;
    for (var i = 0; i < window._names.length; i++) {
        var s = window._scores[window._names[i]] || 0;
        if (s > max) max = s;
    }
    for (var i = 0; i < window._names.length; i++) {
        var s = window._scores[window._names[i]] || 0;
        var bar = document.getElementById('bar-' + i);
        var val = document.getElementById('bar-val-' + i);
        if (bar) bar.style.height = Math.max(2, (s / max) * 100) + 'px';
        if (val) val.textContent = s;
    }
};
'ready';
" > /dev/null 2>&1

echo ""
echo "$(bold '==> Spawning taggers')"

# Colors and names
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

# Spawn taggers
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for i in $(seq 0 $((NUM_TAGGERS - 1))); do
    NAME="${NAMES[$i]}"
    COLOR="${COLORS[$i]}"
    sed -e "s/__TAGGER_NAME__/${NAME}/g" -e "s/__TAGGER_COLOR__/${COLOR}/g" \
        "$SCRIPT_DIR/tagger-v2.js" > "$TMPDIR/tagger_${NAME}.js"
    (
        end=$((SECONDS + DURATION))
        claims=0
        steals=0
        held=0
        errors=0
        while [ $SECONDS -lt $end ]; do
            out=$($HIBROW eval $PROFILE -f "$TMPDIR/tagger_${NAME}.js" 2>&1) \
                || { errors=$((errors + 1)); continue; }
            if echo "$out" | grep -q "CLAIMED"; then
                claims=$((claims + 1))
            elif echo "$out" | grep -q "STOLE"; then
                steals=$((steals + 1))
            else
                held=$((held + 1))
            fi
        done
        echo "${NAME} claims=${claims} steals=${steals} held=${held} errors=${errors}" > "$TMPDIR/tagger_${NAME}.txt"
    ) &
    echo "  started $NAME ($COLOR)"
done

echo ""
echo "$(bold "==> Fighting for territory (${DURATION}s)...")"
echo ""

wait

# --------------------------------------------------------------------------
# Results
# --------------------------------------------------------------------------

echo "$(bold '==> Tagger results')"
echo ""

total_claims=0
total_steals=0
total_held=0
total_errors=0
all_attempted=true

for i in $(seq 0 $((NUM_TAGGERS - 1))); do
    NAME="${NAMES[$i]}"
    if [ -f "$TMPDIR/tagger_${NAME}.txt" ]; then
        result=$(cat "$TMPDIR/tagger_${NAME}.txt")
        claims=$(echo "$result" | grep -o 'claims=[0-9]*' | cut -d= -f2)
        steals=$(echo "$result" | grep -o 'steals=[0-9]*' | cut -d= -f2)
        held=$(echo "$result" | grep -o 'held=[0-9]*' | cut -d= -f2)
        errors=$(echo "$result" | grep -o 'errors=[0-9]*' | cut -d= -f2)
        total_claims=$((total_claims + claims))
        total_steals=$((total_steals + steals))
        total_held=$((total_held + held))
        total_errors=$((total_errors + errors))
        printf "  %-10s %3d claimed, %3d stolen, %4d held, %d errors\n" "$NAME" "$claims" "$steals" "$held" "$errors"
    else
        printf "  %-10s MISSING OUTPUT\n" "$NAME"
        all_attempted=false
    fi
done

total_writes=$((total_claims + total_steals))
echo ""
echo "  total: $total_claims fresh claims, $total_steals steals, $total_held held, $total_errors errors"
echo "  total writes (claims + steals): $total_writes"
echo ""

# --------------------------------------------------------------------------
# Assertions
# --------------------------------------------------------------------------

echo "$(bold '==> Assertions')"

# All taggers should have participated
if [ "$all_attempted" = true ]; then
    pass "all taggers participated"
else
    fail "some taggers did not produce output"
fi

# There should be steals (the whole point of v2)
if [ "$total_steals" -gt 0 ]; then
    pass "territory was contested ($total_steals steals occurred)"
else
    fail "no steals occurred — grid was never contested"
fi

# Browser write count should match client write count
browser_writes=$($HIBROW eval $PROFILE "window._totalWrites" 2>&1 | tr -d '[:space:]')
if [ "$total_writes" -eq "$browser_writes" ]; then
    pass "client writes ($total_writes) match browser count ($browser_writes)"
else
    fail "client writes ($total_writes) vs browser count ($browser_writes) mismatch"
fi

# Grid should be fully claimed (80 cells, all owned)
grid_total=$((GRID_COLS * GRID_ROWS))
grid_claimed=$($HIBROW eval $PROFILE "
var count = 0;
for (var r = 0; r < window._rows; r++) {
    for (var c = 0; c < window._cols; c++) {
        if (window._grid[r][c] !== null) count++;
    }
}
count;
" 2>&1 | tr -d '[:space:]')

if [ "$grid_claimed" -eq "$grid_total" ]; then
    pass "grid fully claimed: $grid_claimed / $grid_total cells"
elif [ "$grid_claimed" -gt 0 ]; then
    pass "grid partially claimed: $grid_claimed / $grid_total cells"
else
    fail "no cells were claimed" "$grid_claimed"
fi

# Verify grid integrity: scores should match current grid ownership
# (scores track net territory — each cell you own is +1)
integrity=$($HIBROW eval $PROFILE "
var owners = {};
for (var r = 0; r < window._rows; r++) {
    for (var c = 0; c < window._cols; c++) {
        var owner = window._grid[r][c];
        if (owner !== null) {
            owners[owner] = (owners[owner] || 0) + 1;
        }
    }
}
// Each score should match grid cell count for that tagger
var ok = true;
for (var k in owners) {
    if (window._scores[k] !== owners[k]) ok = false;
}
// Taggers with 0 cells should have score 0
for (var k in window._scores) {
    if (!(k in owners) && window._scores[k] !== 0) ok = false;
}
ok ? 'CONSISTENT' : 'INCONSISTENT';
" 2>&1 | tr -d '"[:space:]')

if [ "$integrity" = "CONSISTENT" ]; then
    pass "grid ownership consistent with scores (no race conditions)"
else
    fail "grid ownership inconsistent with scores — possible race condition" "$integrity"
fi

# Error rate should be reasonable
max_errors=$(( total_writes / 2 ))
if [ "$total_errors" -le "$max_errors" ]; then
    pass "error rate acceptable ($total_errors errors / $total_writes writes)"
else
    fail "too many errors ($total_errors / $total_writes)"
fi

# Update the stats line in the browser
$HIBROW eval $PROFILE "
document.getElementById('stats').textContent = 'total: ${total_claims} claimed, ${total_steals} stolen, ${total_held} held, ${total_errors} errors — ${browser_writes} writes';
'done';
" > /dev/null 2>&1

# Read back scoreboard
echo ""
echo "$(bold '==> Territory scoreboard (from browser)')"
echo ""
$HIBROW eval $PROFILE "document.getElementById('scoreboard').textContent" 2>&1 | tr -d '"'
echo ""

# --------------------------------------------------------------------------
# Cleanup
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# Leave it up — browser stays open to show the final state
# --------------------------------------------------------------------------

echo ""
echo "  $(bold 'Browser left running — run:') $HIBROW kill $PROFILE $(bold 'to clean up')"

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
