(function () {
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>⧬ Stele of the Seventh Cycle</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Cormorant+Garamond:ital,wght@0,300;0,500;1,300&family=Cinzel:wght@300;500&display=swap" rel="stylesheet">
<style>
  :root {
    --void: #050508;
    --night: #0a0a14;
    --stone: #1a1a2e;
    --gold: #d4af37;
    --gold-dim: rgba(212,175,55,0.35);
    --gold-faint: rgba(212,175,55,0.12);
    --cyan: #88d8e0;
    --parchment: #e8d9b0;
    --parchment-dim: rgba(232,217,176,0.45);
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html, body {
    min-height: 100%;
    background: radial-gradient(ellipse at 50% 28%, #1a1a2e 0%, #0a0a14 48%, #050508 100%);
    color: var(--parchment);
    font-family: 'Cormorant Garamond', serif;
    overflow-x: hidden;
  }
  /* faint starfield */
  body::before {
    content: '';
    position: fixed; inset: 0;
    background-image:
      radial-gradient(1px 1px at 12% 14%, rgba(255,240,200,0.55), transparent 60%),
      radial-gradient(1px 1px at 67% 84%, rgba(200,220,255,0.40), transparent 60%),
      radial-gradient(1px 1px at 88% 23%, rgba(255,220,200,0.45), transparent 60%),
      radial-gradient(1px 1px at 37% 71%, rgba(220,200,255,0.35), transparent 60%),
      radial-gradient(2px 2px at 41% 92%, rgba(255,240,200,0.35), transparent 60%),
      radial-gradient(1px 1px at 73% 41%, rgba(220,240,255,0.45), transparent 60%);
    pointer-events: none; z-index: 0;
  }
  /* dust haze */
  body::after {
    content: '';
    position: fixed; inset: 0;
    background:
      radial-gradient(ellipse 60vw 30vh at 50% 100%, rgba(212,175,55,0.05), transparent),
      radial-gradient(ellipse 80vw 40vh at 50% 0%, rgba(136,216,224,0.04), transparent);
    pointer-events: none; z-index: 0;
  }
  main {
    position: relative; z-index: 1;
    width: min(440px, 92vw);
    margin: 70px auto 90px;
    padding: 56px 36px 36px;
    border-left: 1px solid var(--gold-dim);
    border-right: 1px solid var(--gold-dim);
    background:
      linear-gradient(180deg,
        rgba(20,20,30,0.55) 0%,
        rgba(20,20,30,0.30) 50%,
        rgba(20,20,30,0.55) 100%);
    box-shadow:
      0 0 90px rgba(212,175,55,0.05),
      inset 0 0 70px rgba(0,0,0,0.45);
  }
  /* pyramidal cap */
  main::before {
    content: '';
    position: absolute;
    top: -34px; left: 50%; transform: translateX(-50%);
    width: 0; height: 0;
    border-left: 34px solid transparent;
    border-right: 34px solid transparent;
    border-bottom: 34px solid rgba(20,20,30,0.55);
    filter: drop-shadow(0 -1px 8px rgba(212,175,55,0.18));
  }
  /* base plinth */
  main::after {
    content: '';
    position: absolute;
    bottom: -6px; left: -14px; right: -14px;
    height: 14px;
    border-top: 1px solid var(--gold-dim);
    background: linear-gradient(180deg, rgba(212,175,55,0.10), transparent);
  }
  /* etched vertical groove */
  .groove {
    position: absolute; top: 8px; bottom: 8px; left: 50%;
    width: 1px;
    background: linear-gradient(180deg,
      transparent 0%, var(--gold-faint) 12%, var(--gold-faint) 88%, transparent 100%);
    pointer-events: none; opacity: 0.5;
  }
  .sigil {
    display: flex; flex-direction: column; align-items: center;
    gap: 14px; margin-bottom: 40px;
    position: relative;
  }
  .sigil .seal {
    font-size: 38px; color: var(--gold); letter-spacing: 0;
    text-shadow: 0 0 22px rgba(212,175,55,0.55);
    animation: pulse 5.5s ease-in-out infinite;
  }
  .sigil .glyph-row {
    display: flex; gap: 22px;
    color: var(--gold-dim); font-size: 14px;
    letter-spacing: 0.4em;
  }
  .sigil .title {
    font-family: 'Cinzel', serif; font-weight: 300;
    font-size: 17px; letter-spacing: 0.55em;
    color: var(--gold); text-transform: uppercase;
  }
  .sigil .subtitle {
    font-style: italic; font-size: 13px;
    color: var(--parchment-dim); letter-spacing: 0.12em;
  }
  @keyframes pulse {
    0%,100% { opacity: 0.85; text-shadow: 0 0 22px rgba(212,175,55,0.50); }
    50%     { opacity: 1.0;  text-shadow: 0 0 38px rgba(212,175,55,0.95); }
  }
  ul.scroll {
    list-style: none;
    border-top: 1px solid var(--gold-faint);
    border-bottom: 1px solid var(--gold-faint);
    padding: 18px 0;
    min-height: 90px;
    position: relative;
  }
  .inscription {
    display: flex; align-items: baseline; gap: 16px;
    padding: 12px 4px;
    border-bottom: 1px dashed rgba(212,175,55,0.06);
    cursor: pointer;
    animation: emerge 0.7s ease-out;
    transition: opacity 0.35s, transform 0.35s, background 0.3s;
  }
  .inscription:last-child { border-bottom: none; }
  .inscription:hover { background: rgba(212,175,55,0.025); }
  .inscription .glyph {
    font-size: 18px; color: var(--cyan);
    text-shadow: 0 0 9px rgba(136,216,224,0.45);
    width: 22px; text-align: center;
    transition: text-shadow 0.3s, transform 0.3s;
  }
  .inscription:hover .glyph {
    text-shadow: 0 0 18px rgba(136,216,224,0.95);
    transform: scale(1.08);
  }
  .inscription .text {
    flex: 1; font-size: 17px; line-height: 1.55;
    color: var(--parchment); letter-spacing: 0.025em;
  }
  .inscription.consigned { opacity: 0.32; }
  .inscription.consigned .text {
    text-decoration: line-through;
    text-decoration-color: rgba(212,175,55,0.55);
    text-decoration-thickness: 1px;
    color: rgba(232,217,176,0.65);
  }
  .inscription.consigned .glyph {
    color: rgba(212,175,55,0.40); text-shadow: none;
  }
  .inscription .erase {
    color: rgba(232,217,176,0.18);
    font-size: 13px; padding: 0 6px; cursor: pointer;
    transition: color 0.3s, transform 0.3s;
    font-family: 'Cinzel', serif;
  }
  .inscription:hover .erase { color: rgba(212,90,80,0.78); }
  .inscription .erase:hover { transform: rotate(90deg); }
  @keyframes emerge {
    from { opacity: 0; transform: translateY(-8px); filter: blur(2px); }
    to   { opacity: 1; transform: translateY(0);    filter: blur(0); }
  }
  .ritual {
    display: flex; gap: 0; margin-top: 28px;
    border: 1px solid var(--gold-dim);
    background: rgba(0,0,0,0.32);
  }
  .ritual input {
    flex: 1; background: transparent; border: none; outline: none;
    color: var(--parchment);
    font-family: 'Cormorant Garamond', serif;
    font-size: 16px; padding: 14px 16px; letter-spacing: 0.03em;
  }
  .ritual input::placeholder {
    color: rgba(232,217,176,0.22); font-style: italic;
  }
  .ritual button {
    background: transparent; border: none;
    border-left: 1px solid var(--gold-dim);
    color: var(--gold);
    font-family: 'Cinzel', serif; font-size: 11px;
    letter-spacing: 0.45em; padding: 0 22px; cursor: pointer;
    text-transform: uppercase;
    transition: background 0.3s, text-shadow 0.3s;
  }
  .ritual button:hover {
    background: rgba(212,175,55,0.05);
    text-shadow: 0 0 14px rgba(212,175,55,0.7);
  }
  .void {
    text-align: center; color: var(--parchment-dim);
    font-style: italic; padding: 30px 0;
    font-size: 14px; letter-spacing: 0.18em;
  }
  .epitaph {
    text-align: center; margin-top: 22px;
    font-size: 10px; letter-spacing: 0.55em;
    color: var(--gold-dim); font-family: 'Cinzel', serif;
    text-transform: uppercase;
  }
</style>
</head>
<body>
<main>
  <div class="groove"></div>
  <div class="sigil">
    <div class="seal">⧬</div>
    <div class="glyph-row">✶ ✷ ✴ ✷ ✶</div>
    <div class="title">Stele</div>
    <div class="subtitle">— inscriptions of the seventh cycle —</div>
  </div>
  <ul class="scroll" id="scroll"></ul>
  <div class="ritual">
    <input id="input" type="text" placeholder="inscribe an intention…" autofocus>
    <button id="add">Inscribe</button>
  </div>
  <div class="epitaph" id="epitaph">·   ·   ·</div>
</main>
<script>
  var GLYPHS = ['◇','◈','⬡','⬢','✦','✧','◉','◯','⟁','⌖'];
  var KEY = 'stele.inscriptions.v1';
  var legacy = localStorage.getItem('codex.inscriptions.v1');
  if (legacy && !localStorage.getItem(KEY)) {
    localStorage.setItem(KEY, legacy);
    localStorage.removeItem('codex.inscriptions.v1');
  }
  var scrollEl = document.getElementById('scroll');
  var inputEl = document.getElementById('input');
  var addBtn = document.getElementById('add');
  var epitaphEl = document.getElementById('epitaph');

  function load() {
    try { return JSON.parse(localStorage.getItem(KEY) || '[]'); }
    catch (e) { return []; }
  }
  function save(items) {
    try { localStorage.setItem(KEY, JSON.stringify(items)); } catch (e) {}
  }
  function glyphFor(i) { return GLYPHS[i % GLYPHS.length]; }

  var items = load();

  function render() {
    while (scrollEl.firstChild) scrollEl.removeChild(scrollEl.firstChild);
    if (items.length === 0) {
      var empty = document.createElement('li');
      empty.className = 'void';
      empty.textContent = '⋯ the scroll is empty ⋯';
      scrollEl.appendChild(empty);
    } else {
      items.forEach(function (it, i) {
        var li = document.createElement('li');
        li.className = 'inscription' + (it.done ? ' consigned' : '');
        var g = document.createElement('span');
        g.className = 'glyph';
        g.textContent = glyphFor(i);
        var t = document.createElement('span');
        t.className = 'text';
        t.textContent = it.text;
        var x = document.createElement('span');
        x.className = 'erase';
        x.textContent = '✕';
        x.title = 'erase from memory';
        li.appendChild(g); li.appendChild(t); li.appendChild(x);
        li.addEventListener('click', function (e) {
          if (e.target === x) return;
          it.done = !it.done; save(items); render();
        });
        x.addEventListener('click', function (e) {
          e.stopPropagation();
          items.splice(i, 1); save(items); render();
        });
        scrollEl.appendChild(li);
      });
    }
    var total = items.length;
    var done = items.filter(function (it) { return it.done; }).length;
    epitaphEl.textContent = total
      ? '·  ' + done + ' consigned   /   ' + (total - done) + ' awaiting  ·'
      : '·   ·   ·';
  }

  function add() {
    var v = inputEl.value.replace(/^\\s+|\\s+$/g, '');
    if (!v) return;
    items.push({ text: v, done: false });
    save(items);
    inputEl.value = '';
    render();
  }

  addBtn.addEventListener('click', add);
  inputEl.addEventListener('keydown', function (e) {
    if (e.key === 'Enter') add();
  });
  render();
</script>
</body>
</html>`;
  document.open();
  document.write(html);
  document.close();
})();
