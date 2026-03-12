#!/usr/bin/env bash
#
# hibrow parallel stress test v3 — Core Wars edition
#
# 20 taggers with different strategies compete for territory.
# Adjacency bonus: +2 for claiming next to your own cells, +1 otherwise.
# Strategies: EXPAND (grow into empty space), ATTACK (steal enemy cells),
#             DEFEND (build thick clusters).
# Win condition: first to reach the target score wins.
#
# Usage: ./tests/parallel-v3.sh
#
set -euo pipefail

HIBROW="./zig-out/bin/hibrow"
PROFILE="test-parallel-v3"
NUM_TAGGERS=20
GRID_COLS=20
GRID_ROWS=16
CELL_SIZE=48
WIN_PCT=50  # percent of grid cells needed to win

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
bold()  { printf '\033[1m%s\033[0m' "$*"; }

# Colors and names
COLORS=("#ff4444" "#44ff44" "#4444ff" "#ffff44" "#ff44ff"
        "#ff8844" "#44ffff" "#8844ff" "#ff4488" "#88ff44"
        "#4488ff" "#ffaa00" "#00ffaa" "#aa00ff" "#ff0088"
        "#00ff88" "#8800ff" "#ff8800" "#0088ff" "#88ff00")
NAMES=("ALPHA" "BRAVO" "CHARLIE" "DELTA" "ECHO"
       "FOXTROT" "GOLF" "HOTEL" "INDIA" "JULIET"
       "KILO" "LIMA" "MIKE" "NOVEMBER" "OSCAR"
       "PAPA" "QUEBEC" "ROMEO" "SIERRA" "TANGO")
STRATS=("EXPAND" "ATTACK" "DEFEND")

# Assign strategies — roughly equal distribution with some randomness
TAGGER_STRATS=()
for i in $(seq 0 $((NUM_TAGGERS - 1))); do
    TAGGER_STRATS+=("${STRATS[$((i % 3))]}")
done

# --------------------------------------------------------------------------
# Setup
# --------------------------------------------------------------------------

echo ""
bold "hibrow parallel stress test v3 — Core Wars edition"
echo ""
echo "taggers: $NUM_TAGGERS  |  grid: ${GRID_COLS}x${GRID_ROWS}  |  win: >${WIN_PCT}% of cells"
echo ""

# Kill any existing instance
$HIBROW kill $PROFILE 2>/dev/null || true
sleep 0.5

# Launch browser
echo "$(bold '==> Launching browser')"
out=$($HIBROW launch $PROFILE 2>&1)
echo "  launched"

# Navigate and build arena
$HIBROW nav $PROFILE "about:blank" > /dev/null 2>&1
sleep 0.3

# Build the full arena HTML with play button
$HIBROW eval $PROFILE "
document.body.style.cssText = 'margin:0;background:#111;display:flex;flex-direction:column;align-items:center;padding:12px 0;overflow:auto;min-height:100vh';

// Title
var title = document.createElement('div');
title.style.cssText = 'font:bold 28px monospace;color:#fff;margin-bottom:4px;text-shadow:0 0 20px #888';
title.textContent = 'CORE WARS — TERRITORY FIGHT';
document.body.appendChild(title);

// Subtitle with strategy legend
var legend = document.createElement('div');
legend.style.cssText = 'font:12px monospace;color:#666;margin-bottom:8px';
legend.innerHTML = '<span style=\"color:#4f4\">■ EXPAND</span> grow into space &nbsp; <span style=\"color:#f44\">■ ATTACK</span> steal enemy cells &nbsp; <span style=\"color:#44f\">■ DEFEND</span> build thick clusters';
document.body.appendChild(legend);

// Bar graph container
var barContainer = document.createElement('div');
barContainer.id = 'bars';
barContainer.style.cssText = 'display:flex;align-items:flex-end;gap:3px;height:120px;margin-bottom:8px;padding:0 10px';
document.body.appendChild(barContainer);

// Strategy colors for labels
var stratColors = { EXPAND: '#4f4', ATTACK: '#f44', DEFEND: '#44f' };
var COLORS = ['#ff4444','#44ff44','#4444ff','#ffff44','#ff44ff','#ff8844','#44ffff','#8844ff','#ff4488','#88ff44','#4488ff','#ffaa00','#00ffaa','#aa00ff','#ff0088','#00ff88','#8800ff','#ff8800','#0088ff','#88ff00'];
var NAMES = ['AL','BR','CH','DE','EC','FO','GO','HO','IN','JU','KI','LI','MI','NO','OS','PA','QU','RO','SI','TA'];
var FULLNAMES = ['ALPHA','BRAVO','CHARLIE','DELTA','ECHO','FOXTROT','GOLF','HOTEL','INDIA','JULIET','KILO','LIMA','MIKE','NOVEMBER','OSCAR','PAPA','QUEBEC','ROMEO','SIERRA','TANGO'];
var STRATS = ['EXPAND','ATTACK','DEFEND','EXPAND','ATTACK','DEFEND','EXPAND','ATTACK','DEFEND','EXPAND','ATTACK','DEFEND','EXPAND','ATTACK','DEFEND','EXPAND','ATTACK','DEFEND','EXPAND','ATTACK'];

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
    lbl.style.cssText = 'font:bold 9px monospace;color:' + COLORS[i] + ';margin-top:1px';
    lbl.textContent = NAMES[i];
    col.appendChild(lbl);
    var strat = document.createElement('div');
    strat.style.cssText = 'font:7px monospace;color:' + stratColors[STRATS[i]] + ';opacity:0.7';
    strat.textContent = STRATS[i].substring(0, 3);
    col.appendChild(strat);
    barContainer.appendChild(col);
}

// Win target line
var winLine = document.createElement('div');
winLine.style.cssText = 'font:10px monospace;color:#ff0;margin-bottom:4px';
winLine.textContent = '── KING OF THE HILL: own >${WIN_PCT}% of cells to win ──';
winLine.id = 'win-line';
document.body.appendChild(winLine);

// Stats + play button row
var controlRow = document.createElement('div');
controlRow.style.cssText = 'display:flex;align-items:center;gap:16px;margin-bottom:8px';

var playBtn = document.createElement('button');
playBtn.id = 'play-btn';
playBtn.textContent = '▶ PLAY';
playBtn.style.cssText = 'font:bold 16px monospace;background:#333;color:#0f0;border:2px solid #0f0;padding:6px 20px;cursor:pointer;border-radius:4px;text-shadow:0 0 10px #0f0';
playBtn.onclick = function() {
    if (window._winner) {
        // Reset for new round
        for (var r = 0; r < window._rows; r++) {
            for (var c = 0; c < window._cols; c++) {
                window._grid[r][c] = null;
                var cell = document.getElementById('cell-' + r + '-' + c);
                if (cell) { cell.style.backgroundColor = '#1a1a1a'; cell.textContent = ''; cell.style.boxShadow = 'none'; }
            }
        }
        window._scores = {};
        window._totalWrites = 0;
        window._totalAttempts = 0;
        window._winner = null;
        window._updateBars();
        document.getElementById('stats').textContent = 'press PLAY to start';
        document.getElementById('stats').style.color = '#555';
        document.getElementById('stats').style.fontSize = '12px';
        playBtn.textContent = '▶ PLAY';
        playBtn.style.color = '#0f0';
        playBtn.style.borderColor = '#0f0';
        return;
    }
    window._running = !window._running;
    if (window._running) {
        window._startGameLoop();
        playBtn.textContent = '⏸ PAUSE';
        playBtn.style.color = '#ff0';
        playBtn.style.borderColor = '#ff0';
    } else {
        if (window._gameLoop) { clearInterval(window._gameLoop); window._gameLoop = null; }
        playBtn.textContent = '▶ PLAY';
        playBtn.style.color = '#0f0';
        playBtn.style.borderColor = '#0f0';
    }
};
controlRow.appendChild(playBtn);

var stats = document.createElement('div');
stats.id = 'stats';
stats.style.cssText = 'font:12px monospace;color:#555';
stats.textContent = 'press PLAY to start';
controlRow.appendChild(stats);
document.body.appendChild(controlRow);

// Grid
var grid = document.createElement('div');
grid.id = 'grid';
grid.style.cssText = 'display:grid;grid-template-columns:repeat(${GRID_COLS},${CELL_SIZE}px);grid-template-rows:repeat(${GRID_ROWS},${CELL_SIZE}px);gap:1px;margin-bottom:12px';
document.body.appendChild(grid);

for (var r = 0; r < ${GRID_ROWS}; r++) {
    for (var c = 0; c < ${GRID_COLS}; c++) {
        var cell = document.createElement('div');
        cell.id = 'cell-' + r + '-' + c;
        cell.style.cssText = 'width:${CELL_SIZE}px;height:${CELL_SIZE}px;background:#1a1a1a;border:1px solid #222;display:flex;align-items:center;justify-content:center;font:bold 11px monospace;transition:background-color 0.1s';
        grid.appendChild(cell);
    }
}

// Hidden scoreboard for data readback
var board = document.createElement('div');
board.id = 'scoreboard';
board.style.cssText = 'display:none';
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
window._running = false;
window._winner = null;
window._totalCells = ${GRID_COLS} * ${GRID_ROWS};
window._winCells = Math.ceil(window._totalCells * ${WIN_PCT} / 100) + 1;
window._colors = {};
window._strats = {};
for (var i = 0; i < 20; i++) {
    window._colors[FULLNAMES[i]] = COLORS[i];
    window._strats[FULLNAMES[i]] = STRATS[i];
}
window._names = FULLNAMES;
window._updateBars = function() {
    // Count actual grid cells per tagger (not score — territory count)
    var owned = {};
    for (var r = 0; r < window._rows; r++) {
        for (var c = 0; c < window._cols; c++) {
            var o = window._grid[r][c];
            if (o !== null) owned[o] = (owned[o] || 0) + 1;
        }
    }
    window._owned = owned;
    var max = Math.max(1, window._winCells);
    for (var i = 0; i < window._names.length; i++) {
        var n = window._names[i];
        var cells = owned[n] || 0;
        var bar = document.getElementById('bar-' + i);
        var val = document.getElementById('bar-val-' + i);
        if (bar) bar.style.height = Math.max(2, (cells / max) * 100) + 'px';
        if (val) val.textContent = cells;
    }
};

// ---------------------------------------------------------------------------
// Embedded tagger engine — runs entirely in-browser, no shell needed
// ---------------------------------------------------------------------------
window._tick = function(name, color, strat) {
    if (!window._running) return;
    var cols = window._cols, rows = window._rows, grid = window._grid;
    window._totalAttempts++;

    function myN(r, c) {
        var n = 0;
        if (r > 0 && grid[r-1][c] === name) n++;
        if (r < rows-1 && grid[r+1][c] === name) n++;
        if (c > 0 && grid[r][c-1] === name) n++;
        if (c < cols-1 && grid[r][c+1] === name) n++;
        return n;
    }

    var bR = -1, bC = -1, bS = -999;
    for (var t = 0; t < 12; t++) {
        var r = Math.floor(Math.random() * rows);
        var c = Math.floor(Math.random() * cols);
        var s = 0, mn = myN(r, c);
        if (grid[r][c] === name) { s = -100; }
        else if (strat === 'EXPAND') { s = grid[r][c] === null ? 10 + mn * 5 : 1 + mn * 2; }
        else if (strat === 'ATTACK') { s = grid[r][c] !== null ? 10 + mn * 5 : 1 + mn * 2; }
        else { s = mn * 8 + (grid[r][c] === null ? 2 : 1); }
        if (s > bS) { bS = s; bR = r; bC = c; }
    }
    var _row = bR >= 0 ? bR : Math.floor(Math.random() * rows);
    var _col = bC >= 0 ? bC : Math.floor(Math.random() * cols);
    var prev = grid[_row][_col];
    if (prev === name) return;

    if (prev !== null) window._scores[prev] = (window._scores[prev] || 0) - 1;
    grid[_row][_col] = name;
    var adj = myN(_row, _col);
    window._scores[name] = (window._scores[name] || 0) + 1;
    window._totalWrites++;

    var cell = document.getElementById('cell-' + _row + '-' + _col);
    if (cell) {
        cell.style.backgroundColor = color;
        cell.textContent = name.substring(0, 2);
        cell.style.color = '#fff';
        cell.style.textShadow = '0 0 4px #000';
        cell.style.boxShadow = adj > 0 ? '0 0 8px ' + color : 'none';
    }

    // Check win: does this tagger own > 50% of the grid?
    var cellCount = 0;
    for (var cr = 0; cr < rows; cr++) {
        for (var cc = 0; cc < cols; cc++) {
            if (grid[cr][cc] === name) cellCount++;
        }
    }
    if (cellCount >= window._winCells && !window._winner) {
        window._winner = name;
        window._running = false;
        if (window._gameLoop) { clearInterval(window._gameLoop); window._gameLoop = null; }
        var pct = Math.round(cellCount / window._totalCells * 100);
        document.getElementById('stats').textContent = '*** ' + name + ' WINS — ' + cellCount + '/' + window._totalCells + ' cells (' + pct + '%) ***';
        document.getElementById('stats').style.color = color;
        document.getElementById('stats').style.fontSize = '18px';
        document.getElementById('play-btn').textContent = 'PLAY AGAIN';
        document.getElementById('play-btn').style.color = '#0f0';
        document.getElementById('play-btn').style.borderColor = '#0f0';
    }
};

// Game loop: each interval tick runs all 20 taggers
window._startGameLoop = function() {
    if (window._gameLoop) clearInterval(window._gameLoop);
    window._gameLoop = setInterval(function() {
        if (!window._running || window._winner) return;
        for (var i = 0; i < window._names.length; i++) {
            var n = window._names[i];
            window._tick(n, window._colors[n], window._strats[n]);
        }
        window._updateBars();
        // Update scoreboard for readback
        document.getElementById('scoreboard').textContent = Object.entries(window._scores)
            .sort(function(a, b) { return b[1] - a[1]; })
            .map(function(e) { return e[0].padEnd(10) + e[1]; })
            .join('\\n');
    }, 16); // ~60fps
};

// Live stats updater
window._statsInterval = setInterval(function() {
    if (!window._running || window._winner) return;
    var top = Object.entries(window._owned || {}).sort(function(a,b){return b[1]-a[1];});
    var leader = top.length > 0 ? top[0][0] + ' (' + top[0][1] + '/' + window._totalCells + ')' : '---';
    document.getElementById('stats').textContent = 'writes: ' + window._totalWrites + ' | leader: ' + leader + ' | need: ' + window._winCells + ' cells';
}, 200);

'arena ready';
" > /dev/null 2>&1

echo "  arena built"
echo ""

# Print strategy assignments
echo "$(bold '==> Strategy assignments')"
for i in $(seq 0 $((NUM_TAGGERS - 1))); do
    printf "  %-10s %s (%s)\n" "${NAMES[$i]}" "${TAGGER_STRATS[$i]}" "${COLORS[$i]}"
done
echo ""

# --------------------------------------------------------------------------
# Start the fight (runs entirely in-browser)
# --------------------------------------------------------------------------

echo "$(bold '==> Starting fight')"
echo "  game runs in-browser — PLAY button works for replays"
echo ""

# Start the in-browser game loop
$HIBROW eval $PROFILE "
window._running = true;
window._startGameLoop();
document.getElementById('play-btn').textContent = '⏸ PAUSE';
document.getElementById('play-btn').style.color = '#ff0';
document.getElementById('play-btn').style.borderColor = '#ff0';
'started';
" > /dev/null 2>&1

# Wait for a winner or timeout
TIMEOUT=30
elapsed=0
while [ $elapsed -lt $TIMEOUT ]; do
    winner=$($HIBROW eval $PROFILE "window._winner || ''" 2>&1 | tr -d '"[:space:]')
    if [ -n "$winner" ]; then
        break
    fi
    sleep 0.5
    elapsed=$((elapsed + 1))
done

# --------------------------------------------------------------------------
# Results — pulled from browser state
# --------------------------------------------------------------------------

echo "$(bold '==> Results')"
echo ""

# Get all scores and stats from browser
$HIBROW eval $PROFILE "
var lines = [];
var names = window._names;
for (var i = 0; i < names.length; i++) {
    var n = names[i];
    var s = window._scores[n] || 0;
    var st = window._strats[n];
    lines.push(n.padEnd(12) + st.padEnd(8) + s + ' pts');
}
lines.sort(function(a, b) {
    var sa = parseInt(a.split(/\\s+/)[2]);
    var sb = parseInt(b.split(/\\s+/)[2]);
    return sb - sa;
});
lines.join('\\n');
" 2>&1 | tr -d '"' | sed 's/\\n/\n  /g; s/^/  /'

echo ""

total_writes=$($HIBROW eval $PROFILE "window._totalWrites" 2>&1 | tr -d '[:space:]')
total_attempts=$($HIBROW eval $PROFILE "window._totalAttempts" 2>&1 | tr -d '[:space:]')
echo "  total writes: $total_writes  |  total attempts: $total_attempts"
echo ""

# Show winner
winner=$($HIBROW eval $PROFILE "window._winner || 'none'" 2>&1 | tr -d '"')
if [ "$winner" != "none" ]; then
    score=$($HIBROW eval $PROFILE "window._scores['$winner']" 2>&1 | tr -d '[:space:]')
    strat=$($HIBROW eval $PROFILE "window._strats['$winner']" 2>&1 | tr -d '"')
    echo "  $(bold "*** WINNER: $winner ($strat) with $score points! ***")"
else
    leader=$($HIBROW eval $PROFILE "
        var top = Object.entries(window._scores).sort(function(a,b){return b[1]-a[1];});
        top.length > 0 ? top[0][0] + ' with ' + top[0][1] + ' pts' : 'nobody';
    " 2>&1 | tr -d '"')
    echo "  $(bold "No winner — leader: $leader")"
fi

# Strategy breakdown
echo ""
echo "$(bold '==> Strategy breakdown')"
echo ""
$HIBROW eval $PROFILE "
var byStrat = {};
var names = window._names;
for (var i = 0; i < names.length; i++) {
    var s = window._strats[names[i]];
    if (!byStrat[s]) byStrat[s] = { total: 0, count: 0 };
    byStrat[s].total += (window._scores[names[i]] || 0);
    byStrat[s].count++;
}
Object.entries(byStrat)
    .map(function(e) { return e[0].padEnd(8) + ' avg=' + Math.round(e[1].total / e[1].count) + ' total=' + e[1].total + ' (' + e[1].count + ' taggers)'; })
    .join('\n');
" 2>&1 | tr -d '"' | sed 's/\\n/\n  /g; s/^/  /'

echo ""
echo ""
echo "  $(bold 'Browser left running') — go watch the replay or click PLAY AGAIN"
echo "  Run: $HIBROW kill $PROFILE  to clean up"
echo ""
