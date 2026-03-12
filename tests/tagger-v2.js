// tagger-v2.js — used by parallel-v2.sh
// Territory fight: each tagger claims a random cell on the grid.
// Any cell can be overwritten — the new tagger steals it and scores a point.
// The previous owner loses a point. Bar graphs update live.
//
// Expects globals from arena setup:
//   window._grid          — 2D array tracking ownership per cell
//   window._scores        — { name: count }
//   window._totalWrites   — total successful writes
//   window._totalAttempts  — total attempts
//   window._cols, window._rows — grid dimensions
//
// Sed-injected:
//   __TAGGER_NAME__  →  e.g. "ALPHA"
//   __TAGGER_COLOR__ →  e.g. "#ff4444"

var _col = Math.floor(Math.random() * window._cols);
var _row = Math.floor(Math.random() * window._rows);
var _prev = window._grid[_row][_col];
var _result;

window._totalAttempts++;

if (_prev === '__TAGGER_NAME__') {
    // Already ours — no-op
    _result = 'HELD:__TAGGER_NAME__:' + _row + ',' + _col;
} else {
    // Claim or steal
    if (_prev !== null) {
        // Steal: previous owner loses a point
        window._scores[_prev] = (window._scores[_prev] || 0) - 1;
    }

    window._grid[_row][_col] = '__TAGGER_NAME__';
    window._scores['__TAGGER_NAME__'] = (window._scores['__TAGGER_NAME__'] || 0) + 1;
    window._totalWrites++;

    // Paint the cell
    var cell = document.getElementById('cell-' + _row + '-' + _col);
    if (cell) {
        cell.style.backgroundColor = '__TAGGER_COLOR__';
        cell.textContent = '__TAGGER_NAME__'.substring(0, 2);
        cell.style.color = '#fff';
        cell.style.textShadow = '0 0 4px #000';
    }

    // Update scoreboard
    document.getElementById('scoreboard').textContent = Object.entries(window._scores)
        .sort(function(a, b) { return b[1] - a[1]; })
        .map(function(e) { return e[0].padEnd(10) + e[1]; })
        .join('\n');

    // Update bar graphs
    if (window._updateBars) window._updateBars();

    _result = (_prev ? 'STOLE' : 'CLAIMED') + ':__TAGGER_NAME__:' + _row + ',' + _col;
}

_result;
