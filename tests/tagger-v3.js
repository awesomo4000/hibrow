// tagger-v3.js — used by parallel-v3.sh
// Core Wars-inspired territory fight with strategies and adjacency bonuses.
//
// Strategies:
//   EXPAND  — prefer empty cells adjacent to own territory
//   ATTACK  — prefer enemy cells adjacent to own territory
//   DEFEND  — prefer re-claiming cells near own clusters
//
// Scoring:
//   +2 if claimed cell is adjacent to own territory (adjacency bonus)
//   +1 otherwise
//   Victim loses 1 point per stolen cell
//
// Expects globals from arena setup:
//   window._grid, window._scores, window._totalWrites, window._totalAttempts
//   window._cols, window._rows, window._running
//
// Sed-injected:
//   __TAGGER_NAME__   e.g. "ALPHA"
//   __TAGGER_COLOR__  e.g. "#ff4444"
//   __TAGGER_STRAT__  e.g. "EXPAND"

(function() {
    if (!window._running) return 'PAUSED';

    var name = '__TAGGER_NAME__';
    var color = '__TAGGER_COLOR__';
    var strat = '__TAGGER_STRAT__';
    var cols = window._cols;
    var rows = window._rows;
    var grid = window._grid;

    window._totalAttempts++;

    // Helper: count how many of the 4 neighbors belong to a given owner (or null for empty)
    function neighbors(r, c, owner) {
        var count = 0;
        if (r > 0 && grid[r-1][c] === owner) count++;
        if (r < rows-1 && grid[r+1][c] === owner) count++;
        if (c > 0 && grid[r][c-1] === owner) count++;
        if (c < cols-1 && grid[r][c+1] === owner) count++;
        return count;
    }

    function myNeighbors(r, c) { return neighbors(r, c, name); }

    // Strategy: pick a target cell
    var _row, _col;
    var tries = 0;
    var bestRow = -1, bestCol = -1, bestScore = -999;

    if (strat === 'EXPAND') {
        // Sample 12 random cells, prefer empty ones adjacent to our territory
        for (tries = 0; tries < 12; tries++) {
            var r = Math.floor(Math.random() * rows);
            var c = Math.floor(Math.random() * cols);
            var s = 0;
            if (grid[r][c] === name) { s = -100; } // skip own cells
            else if (grid[r][c] === null) { s = 10 + myNeighbors(r, c) * 5; }
            else { s = 1 + myNeighbors(r, c) * 2; } // will attack if nothing better
            if (s > bestScore) { bestScore = s; bestRow = r; bestCol = c; }
        }
    } else if (strat === 'ATTACK') {
        // Sample 12 random cells, prefer enemy cells adjacent to our territory
        for (tries = 0; tries < 12; tries++) {
            var r = Math.floor(Math.random() * rows);
            var c = Math.floor(Math.random() * cols);
            var s = 0;
            if (grid[r][c] === name) { s = -100; }
            else if (grid[r][c] !== null) { s = 10 + myNeighbors(r, c) * 5; } // enemy!
            else { s = 1 + myNeighbors(r, c) * 2; } // empty is fallback
            if (s > bestScore) { bestScore = s; bestRow = r; bestCol = c; }
        }
    } else { // DEFEND
        // Sample 12 random cells, prefer cells near our clusters (own or empty near own)
        for (tries = 0; tries < 12; tries++) {
            var r = Math.floor(Math.random() * rows);
            var c = Math.floor(Math.random() * cols);
            var s = 0;
            var mn = myNeighbors(r, c);
            if (grid[r][c] === name) { s = -100; }
            else { s = mn * 8 + (grid[r][c] === null ? 2 : 1); }
            if (s > bestScore) { bestScore = s; bestRow = r; bestCol = c; }
        }
    }

    _row = bestRow >= 0 ? bestRow : Math.floor(Math.random() * rows);
    _col = bestCol >= 0 ? bestCol : Math.floor(Math.random() * cols);

    var prev = grid[_row][_col];

    if (prev === name) {
        return 'HELD:' + name + ':' + _row + ',' + _col;
    }

    // Claim or steal
    if (prev !== null) {
        window._scores[prev] = (window._scores[prev] || 0) - 1;
    }

    grid[_row][_col] = name;

    // Adjacency bonus: +2 if next to own territory, +1 otherwise
    var adj = myNeighbors(_row, _col);
    var points = adj > 0 ? 2 : 1;
    window._scores[name] = (window._scores[name] || 0) + points;
    window._totalWrites++;

    // Paint the cell
    var cell = document.getElementById('cell-' + _row + '-' + _col);
    if (cell) {
        cell.style.backgroundColor = color;
        cell.textContent = name.substring(0, 2);
        cell.style.color = '#fff';
        cell.style.textShadow = '0 0 4px #000';
        // Glow border if adjacency bonus
        cell.style.boxShadow = adj > 0 ? '0 0 8px ' + color : 'none';
    }

    // Update scoreboard (hidden)
    document.getElementById('scoreboard').textContent = Object.entries(window._scores)
        .sort(function(a, b) { return b[1] - a[1]; })
        .map(function(e) { return e[0].padEnd(10) + e[1]; })
        .join('\n');

    // Update bar graphs
    if (window._updateBars) window._updateBars();

    // Check win condition
    if (window._scores[name] >= window._winTarget && !window._winner) {
        window._winner = name;
        window._running = false;
        document.getElementById('stats').textContent = '*** ' + name + ' WINS with ' + window._scores[name] + ' points! ***';
        document.getElementById('stats').style.color = color;
        document.getElementById('stats').style.fontSize = '18px';
        var btn = document.getElementById('play-btn');
        if (btn) btn.textContent = 'PLAY AGAIN';
    }

    return (prev ? 'STOLE' : 'CLAIMED') + ':' + name + ':' + _row + ',' + _col + (adj > 0 ? ':COMBO' : '');
})();
