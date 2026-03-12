// tagger.js — used by parallel.sh
// Injected via: hibrow eval <profile> -f tests/tagger.js
//
// Expects these globals to be set before first call (by arena setup):
//   window._scores, window._log, window._totalWrites
//
// The tagger name and color are injected by parallel.sh via sed:
//   __TAGGER_NAME__  →  e.g. "ALPHA"
//   __TAGGER_COLOR__ →  e.g. "#ff4444"

var _wall = document.getElementById('wall');
_wall.textContent = '__TAGGER_NAME__';
_wall.style.color = '__TAGGER_COLOR__';
document.body.style.backgroundColor = '__TAGGER_COLOR__' + '22';

window._scores['__TAGGER_NAME__'] = (window._scores['__TAGGER_NAME__'] || 0) + 1;
window._totalWrites++;

window._log.unshift(window._totalWrites + ': __TAGGER_NAME__');
if (window._log.length > 20) window._log.pop();
document.getElementById('log').textContent = window._log.join('\n');

// Update scoreboard
document.getElementById('scoreboard').textContent = Object.entries(window._scores)
    .sort(function(a, b) { return b[1] - a[1]; })
    .map(function(e) { return e[0].padEnd(10) + e[1]; })
    .join('\n');

'__TAGGER_NAME__:' + window._scores['__TAGGER_NAME__'];
