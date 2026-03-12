#!/usr/bin/env bash
#
# hibrow parallel stress test v4 — Evolutionary Core Wars
#
# 20 taggers with evolving DNA compete for territory on a grid.
# Each tagger has 4 genes that control behavior:
#   - aggression (0-1): prefer enemy cells vs empty cells
#   - samples (4-20):   how many candidate cells to evaluate per turn
#   - adjacency (0-1):  how much to prefer cells near own territory
#   - kingslayer (0-1):  how much to target the current leader
#
# Every EVOLVE_INTERVAL ticks, the bottom half is replaced by mutated
# clones of the top half. Strategies emerge from selection pressure.
#
# Win: last one standing — elimination every EVOLVE_INTERVAL ticks until 1 remains.
# PLAY AGAIN button works — runs entirely in-browser after setup.
#
# Usage: ./tests/parallel-v4.sh
#
set -euo pipefail

HIBROW="./zig-out/bin/hibrow"
PROFILE="test-parallel-v4"
NUM_TAGGERS=20
GRID_COLS=24
GRID_ROWS=18
CELL_SIZE=38
WIN_PCT=15
EVOLVE_INTERVAL=80    # ticks between evolution rounds (eliminations)

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
bold()  { printf '\033[1m%s\033[0m' "$*"; }

echo ""
bold "hibrow parallel v4 — Evolutionary Core Wars"
echo ""
echo "taggers: $NUM_TAGGERS  |  grid: ${GRID_COLS}x${GRID_ROWS} (${CELL_SIZE}px)  |  win: >${WIN_PCT}% cells"
echo "evolution every $EVOLVE_INTERVAL ticks — worst tagger eliminated each round, last one standing wins"
echo ""

# Kill any existing instance
$HIBROW kill $PROFILE 2>/dev/null || true
sleep 0.5

echo "$(bold '==> Launching browser')"
$HIBROW launch $PROFILE > /dev/null 2>&1
echo "  launched"

$HIBROW nav $PROFILE "about:blank" > /dev/null 2>&1
sleep 0.3

# --------------------------------------------------------------------------
# Inject the entire arena + game engine as one big eval
# --------------------------------------------------------------------------

$HIBROW eval $PROFILE "
document.body.style.cssText = 'margin:0;background:#111;display:flex;flex-direction:column;align-items:center;padding:8px 0;overflow:auto;min-height:100vh;font-family:monospace';

// =========================================================================
// CONSTANTS
// =========================================================================
var NC = ${NUM_TAGGERS};
var COLS = ${GRID_COLS}, ROWS = ${GRID_ROWS}, CELL = ${CELL_SIZE};
var TOTAL_CELLS = COLS * ROWS;
var WIN_CELLS = Math.ceil(TOTAL_CELLS * ${WIN_PCT} / 100) + 1;
var EVOLVE_EVERY = ${EVOLVE_INTERVAL};

var COLORS = ['#ff4444','#44ff44','#4444ff','#ffff44','#ff44ff','#ff8844','#44ffff','#8844ff','#ff4488','#88ff44','#4488ff','#ffaa00','#00ffaa','#aa00ff','#ff0088','#00ff88','#8800ff','#ff8800','#0088ff','#88ff00'];
var NAMES = ['ALPHA','BRAVO','CHARLIE','DELTA','ECHO','FOXTROT','GOLF','HOTEL','INDIA','JULIET','KILO','LIMA','MIKE','NOVEMBER','OSCAR','PAPA','QUEBEC','ROMEO','SIERRA','TANGO'];
var SHORT = ['AL','BR','CH','DE','EC','FO','GO','HO','IN','JU','KI','LI','MI','NO','OS','PA','QU','RO','SI','TA'];

// =========================================================================
// TITLE + LEGEND
// =========================================================================
var h = document.createElement('div');
h.style.cssText = 'font:bold 24px monospace;color:#fff;margin-bottom:2px;text-shadow:0 0 15px #888';
h.textContent = 'EVOLUTIONARY CORE WARS';
document.body.appendChild(h);

var leg = document.createElement('div');
leg.id = 'legend';
leg.style.cssText = 'font:10px monospace;color:#666;margin-bottom:6px';
leg.textContent = 'genes: AGG=aggression SMP=samples ADJ=adjacency KSL=kingslayer | more territory = more moves per tick | evolve every ' + EVOLVE_EVERY;
document.body.appendChild(leg);

// =========================================================================
// BAR GRAPHS
// =========================================================================
var barsDiv = document.createElement('div');
barsDiv.id = 'bars';
barsDiv.style.cssText = 'display:flex;align-items:flex-end;gap:2px;height:110px;margin-bottom:4px;padding:0 4px';
document.body.appendChild(barsDiv);

for (var i = 0; i < NC; i++) {
    var col = document.createElement('div');
    col.style.cssText = 'display:flex;flex-direction:column;align-items:center;width:38px';
    var val = document.createElement('div');
    val.id = 'bv-' + i;
    val.style.cssText = 'font:bold 9px monospace;color:#aaa;margin-bottom:1px';
    val.textContent = '0';
    col.appendChild(val);
    var bar = document.createElement('div');
    bar.id = 'bb-' + i;
    bar.style.cssText = 'width:32px;min-height:2px;background:' + COLORS[i] + ';border-radius:2px 2px 0 0;transition:height 0.1s;box-shadow:0 0 4px ' + COLORS[i] + '40';
    col.appendChild(bar);
    var lbl = document.createElement('div');
    lbl.id = 'bl-' + i;
    lbl.style.cssText = 'font:bold 8px monospace;color:' + COLORS[i] + ';margin-top:1px';
    lbl.textContent = SHORT[i];
    col.appendChild(lbl);
    var dna = document.createElement('div');
    dna.id = 'bd-' + i;
    dna.style.cssText = 'font:7px monospace;color:#555;margin-top:0px;text-align:center;line-height:1.1';
    dna.textContent = '...';
    col.appendChild(dna);
    barsDiv.appendChild(col);
}

// Win line
var wl = document.createElement('div');
wl.style.cssText = 'font:10px monospace;color:#ff0;margin-bottom:2px';
wl.textContent = 'LAST ONE STANDING: elimination every ' + EVOLVE_EVERY + ' ticks until 1 remains';
document.body.appendChild(wl);

// Controls row
var ctrl = document.createElement('div');
ctrl.style.cssText = 'display:flex;align-items:center;gap:12px;margin-bottom:6px';

var btn = document.createElement('button');
btn.id = 'play-btn';
btn.textContent = '\\u25B6 PLAY';
btn.style.cssText = 'font:bold 14px monospace;background:#333;color:#0f0;border:2px solid #0f0;padding:5px 16px;cursor:pointer;border-radius:4px;text-shadow:0 0 8px #0f0';
ctrl.appendChild(btn);

var sts = document.createElement('div');
sts.id = 'stats';
sts.style.cssText = 'font:11px monospace;color:#555';
sts.textContent = 'press PLAY to start';
ctrl.appendChild(sts);
document.body.appendChild(ctrl);

// Evolution log
var elog = document.createElement('div');
elog.id = 'evo-log';
elog.style.cssText = 'font:9px monospace;color:#555;margin-bottom:4px;max-height:40px;overflow:hidden;text-align:center';
document.body.appendChild(elog);

// Grid
var gDiv = document.createElement('div');
gDiv.style.cssText = 'display:grid;grid-template-columns:repeat(' + COLS + ',' + CELL + 'px);grid-template-rows:repeat(' + ROWS + ',' + CELL + 'px);gap:1px;margin-bottom:8px';
document.body.appendChild(gDiv);

for (var r = 0; r < ROWS; r++) {
    for (var c = 0; c < COLS; c++) {
        var ce = document.createElement('div');
        ce.id = 'c-' + r + '-' + c;
        ce.style.cssText = 'width:' + CELL + 'px;height:' + CELL + 'px;background:#1a1a1a;border:1px solid #222;display:flex;align-items:center;justify-content:center;font:bold 9px monospace;transition:background-color 0.08s';
        gDiv.appendChild(ce);
    }
}

// =========================================================================
// STATE
// =========================================================================
var G = window;
G._grid = [];
for (var r = 0; r < ROWS; r++) { G._grid[r] = []; for (var c = 0; c < COLS; c++) G._grid[r][c] = null; }
G._cols = COLS; G._rows = ROWS;
G._running = false;
G._winner = null;
G._totalWrites = 0;
G._tick_count = 0;
G._evoRound = 0;

// DNA: each tagger has 4 genes (0..1 floats, except samples which is 4..20)
G._dna = [];
for (var i = 0; i < NC; i++) {
    G._dna[i] = {
        aggression: Math.random(),       // prefer enemy (1) vs empty (0)
        samples:    4 + Math.floor(Math.random() * 17),  // 4..20
        adjacency:  Math.random(),       // weight for own-neighbor bonus
        kingslayer: Math.random()        // target leader specifically
    };
}
G._alive = [];
for (var i = 0; i < NC; i++) G._alive[i] = true;
G._names = NAMES;
G._colors = COLORS;
G._short = SHORT;

// =========================================================================
// COUNT TERRITORY
// =========================================================================
G._countOwned = function() {
    var owned = {};
    for (var r = 0; r < ROWS; r++)
        for (var c = 0; c < COLS; c++) {
            var o = G._grid[r][c];
            if (o !== null) owned[o] = (owned[o] || 0) + 1;
        }
    G._owned = owned;
    return owned;
};

// =========================================================================
// UPDATE BARS
// =========================================================================
G._updateBars = function() {
    var owned = G._owned || G._countOwned();
    for (var i = 0; i < NC; i++) {
        var n = NAMES[i], cells = owned[n] || 0;
        var bar = document.getElementById('bb-' + i);
        var val = document.getElementById('bv-' + i);
        if (bar) bar.style.height = Math.max(2, (cells / WIN_CELLS) * 100) + 'px';
        if (val) val.textContent = cells;
        // Show DNA under bar
        var d = G._dna[i];
        var dd = document.getElementById('bd-' + i);
        if (dd) dd.textContent = 'A' + d.aggression.toFixed(1) + ' S' + d.samples + '\\nJ' + d.adjacency.toFixed(1) + ' K' + d.kingslayer.toFixed(1);
    }
};

// =========================================================================
// FIND LEADER
// =========================================================================
G._findLeader = function() {
    var owned = G._owned || {};
    var best = null, bestN = 0;
    for (var k in owned) { if (owned[k] > bestN) { bestN = owned[k]; best = k; } }
    return best;
};

// =========================================================================
// TICK — one move for one tagger
// =========================================================================
G._tick = function(idx) {
    if (!G._running || !G._alive[idx]) return;
    var name = NAMES[idx], color = COLORS[idx], dna = G._dna[idx];
    var grid = G._grid;

    function myN(r, c) {
        var n = 0;
        if (r > 0 && grid[r-1][c] === name) n++;
        if (r < ROWS-1 && grid[r+1][c] === name) n++;
        if (c > 0 && grid[r][c-1] === name) n++;
        if (c < COLS-1 && grid[r][c+1] === name) n++;
        return n;
    }

    var leader = G._findLeader();
    var bR = -1, bC = -1, bS = -999;
    var nSamples = dna.samples;

    for (var t = 0; t < nSamples; t++) {
        var r = Math.floor(Math.random() * ROWS);
        var c = Math.floor(Math.random() * COLS);
        if (grid[r][c] === name) continue; // skip own cells

        var s = 0;
        var mn = myN(r, c);
        var isEmpty = grid[r][c] === null;
        var isEnemy = !isEmpty;
        var isLeader = grid[r][c] === leader;

        // Base: prefer empty or enemy based on aggression gene
        if (isEmpty) s += (1 - dna.aggression) * 10;
        if (isEnemy) s += dna.aggression * 10;

        // Adjacency bonus
        s += mn * dna.adjacency * 8;

        // Kingslayer bonus: extra points for targeting the leader
        if (isLeader && leader !== name) s += dna.kingslayer * 15;

        if (s > bS) { bS = s; bR = r; bC = c; }
    }

    if (bR < 0) return; // no valid target found

    var prev = grid[bR][bC];
    grid[bR][bC] = name;
    G._totalWrites++;

    var cell = document.getElementById('c-' + bR + '-' + bC);
    if (cell) {
        cell.style.backgroundColor = color;
        cell.textContent = SHORT[idx];
        cell.style.color = '#fff';
        cell.style.textShadow = '0 0 3px #000';
        cell.style.boxShadow = myN(bR, bC) > 0 ? '0 0 6px ' + color : 'none';
    }
};

// =========================================================================
// EVOLUTION — survival of the fittest
// =========================================================================
G._evolve = function() {
    G._evoRound++;
    var owned = G._countOwned();

    // Rank alive taggers by territory
    var ranked = [];
    for (var i = 0; i < NC; i++) {
        if (G._alive[i]) ranked.push({ idx: i, cells: owned[NAMES[i]] || 0 });
    }
    ranked.sort(function(a, b) { return b.cells - a.cells; });

    // LAST ONE STANDING — declare winner
    if (ranked.length <= 1) {
        if (ranked.length === 1) G._declareWinner(ranked[0].idx);
        return;
    }

    // Down to 2 — announce the final showdown but keep eliminating
    if (ranked.length === 2) {
        var el = document.getElementById('evo-log');
        if (el) {
            el.style.color = '#f44';
            el.style.fontSize = '14px';
            el.textContent = 'FINAL 2: ' + NAMES[ranked[0].idx] + ' vs ' + NAMES[ranked[1].idx] + ' — next elimination decides it!';
        }
        var title = document.querySelector('div');
        if (title) title.textContent = 'FINAL SHOWDOWN!';
    }

    // ELIMINATE the worst tagger — erase their territory
    var worst = ranked[ranked.length - 1];
    G._alive[worst.idx] = false;
    var killName = NAMES[worst.idx];
    for (var r = 0; r < ROWS; r++) {
        for (var c = 0; c < COLS; c++) {
            if (G._grid[r][c] === killName) {
                G._grid[r][c] = null;
                var ce = document.getElementById('c-' + r + '-' + c);
                if (ce) { ce.style.backgroundColor = '#1a1a1a'; ce.textContent = ''; ce.style.boxShadow = 'none'; }
            }
        }
    }
    // Grey out their bar
    var bb = document.getElementById('bb-' + worst.idx);
    if (bb) { bb.style.background = '#333'; bb.style.boxShadow = 'none'; }
    var bl = document.getElementById('bl-' + worst.idx);
    if (bl) bl.style.color = '#333';
    var bd = document.getElementById('bd-' + worst.idx);
    if (bd) bd.textContent = 'DEAD';

    // Mutate bottom half of survivors (copy DNA from top half)
    var alive = ranked.slice(0, -1); // remove the one we just killed
    var half = Math.floor(alive.length / 2);
    var survivors = alive.slice(0, half);
    var weak = alive.slice(half);

    for (var d = 0; d < weak.length; d++) {
        var parent = survivors[Math.floor(Math.random() * survivors.length)];
        var pDna = G._dna[parent.idx];
        var mutRate = 0.15;
        function mutF(v) { return Math.max(0, Math.min(1, v + (Math.random() - 0.5) * mutRate * 2)); }
        function mutI(v, lo, hi) { var nv = v + Math.round((Math.random() - 0.5) * 6); return Math.max(lo, Math.min(hi, nv)); }
        G._dna[weak[d].idx] = {
            aggression: mutF(pDna.aggression),
            samples:    mutI(pDna.samples, 4, 20),
            adjacency:  mutF(pDna.adjacency),
            kingslayer: mutF(pDna.kingslayer)
        };
    }

    var aliveCount = ranked.length - 1;
    var msg = 'Gen ' + G._evoRound + ': ' + SHORT[worst.idx] + ' ELIMINATED (' + worst.cells + ' cells) | ' + aliveCount + ' remain | leader: ' + SHORT[ranked[0].idx] + '(' + ranked[0].cells + ')';
    var el = document.getElementById('evo-log');
    if (el) el.textContent = msg;
};

// =========================================================================
// DECLARE WINNER
// =========================================================================
G._declareWinner = function(idx) {
    var cells = (G._owned || {})[NAMES[idx]] || 0;
    G._winner = NAMES[idx];
    G._running = false;
    if (G._gameLoop) { clearInterval(G._gameLoop); G._gameLoop = null; }
    var pct = Math.round(cells / TOTAL_CELLS * 100);
    var d = G._dna[idx];
    document.getElementById('stats').textContent = '*** ' + NAMES[idx] + ' WINS — ' + cells + '/' + TOTAL_CELLS + ' (' + pct + '%) | DNA: agg=' + d.aggression.toFixed(2) + ' smp=' + d.samples + ' adj=' + d.adjacency.toFixed(2) + ' ksl=' + d.kingslayer.toFixed(2) + ' ***';
    document.getElementById('stats').style.color = COLORS[idx];
    document.getElementById('stats').style.fontSize = '14px';
    var title = document.querySelector('div');
    if (title) { title.textContent = NAMES[idx] + ' WINS!'; title.style.color = COLORS[idx]; title.style.textShadow = '0 0 30px ' + COLORS[idx]; }
    document.getElementById('play-btn').textContent = 'PLAY AGAIN';
    document.getElementById('play-btn').style.color = '#0f0';
    document.getElementById('play-btn').style.borderColor = '#0f0';
};

// =========================================================================
// GAME LOOP
// =========================================================================
G._startGameLoop = function() {
    if (G._gameLoop) clearInterval(G._gameLoop);
    G._gameLoop = setInterval(function() {
        if (!G._running || G._winner) return;

        // Run taggers — territory = more moves (scaling advantage)
        // Everyone gets 1 base move. +1 extra move per 5% of grid owned.
        // Dead taggers skip.
        var owned = G._countOwned();
        for (var i = 0; i < NC; i++) {
            if (!G._alive[i]) continue;
            var cells = owned[NAMES[i]] || 0;
            var moves = 1 + Math.floor(cells / (TOTAL_CELLS * 0.05));
            for (var m = 0; m < moves; m++) G._tick(i);
        }
        G._tick_count++;

        // Count territory + update bars every 4 ticks (perf)
        if (G._tick_count % 4 === 0) {
            owned = G._countOwned();
            G._updateBars();
        }

        // Evolution
        if (G._tick_count % EVOLVE_EVERY === 0) G._evolve();

    }, 16);
};

// Stats updater
setInterval(function() {
    if (!G._running || G._winner) return;
    var owned = G._owned || {};
    var top = Object.entries(owned).sort(function(a,b){return b[1]-a[1];});
    var ldr = top.length > 0 ? top[0][0] + '(' + top[0][1] + ')' : '---';
    document.getElementById('stats').textContent = 'tick:' + G._tick_count + ' evo:' + G._evoRound + ' | leader:' + ldr + ' | need:' + WIN_CELLS + ' | writes:' + G._totalWrites;
}, 250);

// =========================================================================
// PLAY BUTTON
// =========================================================================
btn.onclick = function() {
    if (G._winner) {
        // Full reset
        for (var r = 0; r < ROWS; r++)
            for (var c = 0; c < COLS; c++) {
                G._grid[r][c] = null;
                var ce = document.getElementById('c-' + r + '-' + c);
                if (ce) { ce.style.backgroundColor = '#1a1a1a'; ce.textContent = ''; ce.style.boxShadow = 'none'; }
            }
        G._totalWrites = 0; G._tick_count = 0; G._evoRound = 0;
        G._winner = null; G._owned = {};
        // Re-randomize DNA and revive all
        for (var i = 0; i < NC; i++) {
            G._dna[i] = { aggression: Math.random(), samples: 4 + Math.floor(Math.random() * 17), adjacency: Math.random(), kingslayer: Math.random() };
            G._alive[i] = true;
            // Restore bar colors
            var bb = document.getElementById('bb-' + i);
            if (bb) { bb.style.background = COLORS[i]; bb.style.boxShadow = '0 0 4px ' + COLORS[i] + '40'; }
            var bl = document.getElementById('bl-' + i);
            if (bl) bl.style.color = COLORS[i];
        }
        G._updateBars();
        // Restore title
        var title = document.querySelector('div');
        if (title) { title.textContent = 'EVOLUTIONARY CORE WARS!'; title.style.color = '#fff'; title.style.textShadow = '0 0 25px #f80, 0 0 50px #f40'; }
        document.getElementById('stats').textContent = 'press PLAY to start';
        document.getElementById('stats').style.color = '#555';
        document.getElementById('stats').style.fontSize = '11px';
        document.getElementById('evo-log').textContent = '';
        document.getElementById('evo-log').style.color = '#555';
        document.getElementById('evo-log').style.fontSize = '9px';
        btn.textContent = '\\u25B6 PLAY';
        btn.style.color = '#0f0'; btn.style.borderColor = '#0f0';
        return;
    }
    G._running = !G._running;
    if (G._running) {
        G._startGameLoop();
        btn.textContent = '\\u23F8 PAUSE';
        btn.style.color = '#ff0'; btn.style.borderColor = '#ff0';
    } else {
        if (G._gameLoop) { clearInterval(G._gameLoop); G._gameLoop = null; }
        btn.textContent = '\\u25B6 PLAY';
        btn.style.color = '#0f0'; btn.style.borderColor = '#0f0';
    }
};

'arena ready';
" > /dev/null 2>&1

echo "  arena built"
echo ""

# Auto-start
$HIBROW eval $PROFILE "
window._running = true;
window._startGameLoop();
document.getElementById('play-btn').textContent = '\\u23F8 PAUSE';
document.getElementById('play-btn').style.color = '#ff0';
document.getElementById('play-btn').style.borderColor = '#ff0';
'started';
" > /dev/null 2>&1

echo "$(bold '==> Fight started — evolution every') $EVOLVE_INTERVAL $(bold 'ticks')"
echo ""

# Wait for winner or timeout
TIMEOUT=180
elapsed=0
while [ $elapsed -lt $TIMEOUT ]; do
    winner=$($HIBROW eval $PROFILE "window._winner || ''" 2>&1 | tr -d '"[:space:]')
    if [ -n "$winner" ]; then
        break
    fi
    sleep 0.5
    elapsed=$((elapsed + 1))
done

# Results
echo "$(bold '==> Results')"
echo ""

$HIBROW eval $PROFILE "
var owned = window._countOwned();
var lines = [];
for (var i = 0; i < window._names.length; i++) {
    var n = window._names[i];
    var c = owned[n] || 0;
    var d = window._dna[i];
    lines.push({ name: n, cells: c, dna: d });
}
lines.sort(function(a,b) { return b.cells - a.cells; });
lines.map(function(x, i) {
    return (i+1) + '. ' + x.name.padEnd(10) + x.cells.toString().padStart(4) + ' cells  agg=' + x.dna.aggression.toFixed(2) + ' smp=' + x.dna.samples.toString().padStart(2) + ' adj=' + x.dna.adjacency.toFixed(2) + ' ksl=' + x.dna.kingslayer.toFixed(2);
}).join('\\n');
" 2>&1 | tr -d '"' | sed 's/\\n/\n  /g; s/^/  /'

echo ""
echo ""

winner=$($HIBROW eval $PROFILE "window._winner || 'none'" 2>&1 | tr -d '"')
if [ "$winner" != "none" ]; then
    evo=$($HIBROW eval $PROFILE "window._evoRound" 2>&1 | tr -d '[:space:]')
    ticks=$($HIBROW eval $PROFILE "window._tick_count" 2>&1 | tr -d '[:space:]')
    echo "  $(bold "*** WINNER: $winner after $ticks ticks, $evo evolution rounds ***")"
else
    echo "  $(bold 'No winner in 60s — the struggle continues')"
fi

echo ""
echo "  $(bold 'Browser left running') — click PLAY AGAIN to re-evolve from scratch"
echo "  Run: $HIBROW kill $PROFILE  to clean up"
echo ""
