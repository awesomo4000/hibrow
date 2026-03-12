# Realtime UI Builder

Build browser UIs by dispatching parallel Claude subagents that each own a
web component. You drive feedback from the live browser; agents iterate
independently until every piece looks and feels right. Then extract the
components as standalone files — no untangling needed because they were
never tangled.

## Architecture

```
You (feedback)
  │
  ├──> Agent: top-nav     ──> hibrow eval canvas "customElements.define('top-nav', ...)"
  ├──> Agent: sidebar      ──> hibrow eval canvas "customElements.define('side-bar', ...)"
  ├──> Agent: main-content ──> hibrow eval canvas "customElements.define('main-content', ...)"
  └──> Agent: footer       ──> hibrow eval canvas "customElements.define('app-footer', ...)"
                                        │
                                        ▼
                                  ┌───────────┐
                                  │  Browser   │  (live preview)
                                  │            │
                                  │ <app-shell>│
                                  │   <top-nav>│  ← shadow DOM isolation
                                  │   <side-bar>│
                                  │   <main-content>│
                                  │   <app-footer>│
                                  │ </app-shell>│
                                  └───────────┘
```

## Why Web Components

- **Shadow DOM isolation** — each agent's CSS is jailed in its shadow root.
  Agent A can't blow up agent B's layout. This is what makes parallel work safe.
- **Self-contained output** — a `customElements.define(...)` call is a complete
  unit: markup, styles, event handlers, state. Nothing to extract or untangle.
- **Hot-reloadable** — re-defining a component (or replacing its shadow DOM)
  updates the live page instantly. Agents iterate without full page reloads.
- **Natural agent boundary** — one tag name = one agent = one file. The mapping
  is obvious and enforced by the browser itself.

## How It Works

### 1. Bootstrap the shell

Launch a browser and inject a minimal app shell with slots:

```bash
hibrow launch canvas
hibrow nav canvas "about:blank"
hibrow eval canvas "
document.title = 'UI Builder';
document.body.innerHTML = \`
  <app-shell>
    <top-nav slot='header'></top-nav>
    <side-bar slot='sidebar'></side-bar>
    <main-content slot='main'></main-content>
    <app-footer slot='footer'></app-footer>
  </app-shell>
\`;

// Shell component: CSS grid layout with named slots
customElements.define('app-shell', class extends HTMLElement {
  connectedCallback() {
    this.attachShadow({mode:'open'}).innerHTML = \`
      <style>
        :host { display:grid; grid-template-rows:auto 1fr auto; grid-template-columns:240px 1fr;
                height:100vh; margin:0; font-family:system-ui,sans-serif; }
        ::slotted([slot=header])  { grid-column:1/-1; }
        ::slotted([slot=sidebar]) { grid-row:2; }
        ::slotted([slot=main])    { grid-row:2; grid-column:2; overflow-y:auto; }
        ::slotted([slot=footer])  { grid-column:1/-1; }
      </style>
      <slot name='header'></slot>
      <slot name='sidebar'></slot>
      <slot name='main'></slot>
      <slot name='footer'></slot>
    \`;
  }
});
'shell ready'
"
```

### 2. Assign agents to components

Each agent gets a tag name and a brief. It calls `hibrow eval` to define
and iterate on its component:

```bash
# Agent working on <top-nav>
hibrow eval canvas "
customElements.define('top-nav', class extends HTMLElement {
  connectedCallback() {
    this.attachShadow({mode:'open'}).innerHTML = \`
      <style>
        :host { display:flex; align-items:center; padding:0 20px;
                height:56px; background:#1a1a2e; color:#eee; }
        .logo { font-weight:700; font-size:18px; }
        nav { margin-left:auto; display:flex; gap:16px; }
        a { color:#aaa; text-decoration:none; font-size:14px; }
        a:hover { color:#fff; }
      </style>
      <div class='logo'>MyApp</div>
      <nav>
        <a href='#'>Dashboard</a>
        <a href='#'>Settings</a>
        <a href='#'>Help</a>
      </nav>
    \`;
  }
});
'top-nav defined'
"
```

Agents work in parallel. The gateway serializes CDP writes (~1000/sec),
but agent think-time dwarfs write-time so this is invisible.

### 3. Iterate with feedback

You look at the browser. You say "header needs more padding" or "sidebar
should be collapsible." That feedback routes to the owning agent, which
re-evals its component definition. The browser updates live.

To re-define a component that already exists (browsers don't allow
re-calling `customElements.define` for the same tag), agents replace the
shadow DOM contents instead:

```bash
hibrow eval canvas "
document.querySelector('top-nav').shadowRoot.innerHTML = \`
  <style>
    :host { display:flex; align-items:center; padding:0 32px;
            height:64px; background:#1a1a2e; color:#eee; }
    /* ... updated styles ... */
  </style>
  <!-- ... updated markup ... -->
\`;
'top-nav updated'
"
```

### 4. Extract components

When the UI looks right, dump each component's source. Since each agent's
output was always a self-contained `customElements.define(...)` call, the
"extraction" step is trivial — save each agent's final eval payload as a
`.js` file:

```
components/
  app-shell.js
  top-nav.js
  side-bar.js
  main-content.js
  app-footer.js
index.html        # just the <app-shell> skeleton + <script> tags
```

Or dump the live DOM as a snapshot:

```bash
hibrow eval canvas "document.documentElement.outerHTML"
```

## Key Constraints

- **CDP is serialized per-browser** — the gateway queues concurrent writes.
  At ~1000 writes/sec this is fine; agent think-time is the real bottleneck.
- **`customElements.define` is once-per-tag** — agents must update via
  `shadowRoot.innerHTML` after initial definition. Or use a wrapper that
  deletes and re-creates the element.
- **No cross-component state** — agents communicate through the DOM (reading
  attributes, dispatching events), not shared JS variables. This is a feature:
  it enforces the same decoupling you want in production.
- **Shadow DOM style isolation is real** — global styles don't pierce shadow
  roots. Agents must include all their CSS. Shared design tokens can live on
  `:root` as custom properties (`var(--color-primary)`).

## Testing Strategy

Use the same pattern as e2e tests: script the agents with `hibrow eval`,
read back DOM state to verify, screenshot for visual regression.

```bash
# Verify component rendered
out=$(hibrow eval canvas "document.querySelector('top-nav').shadowRoot.querySelector('.logo').textContent")
assert_equals "$out" "MyApp" "top-nav logo text"

# Verify layout (computed styles)
out=$(hibrow eval canvas "getComputedStyle(document.querySelector('top-nav')).height")
assert_equals "$out" "64px" "top-nav height"
```

## Future Ideas

- **File watcher mode** — agent writes `components/top-nav.js`, watcher
  auto-evals it into the browser. Skip the eval-from-agent step entirely.
- **Visual diff** — screenshot before/after each agent iteration, flag
  unintended changes to other regions.
- **Component marketplace** — agents pull from a library of pre-built
  web components and customize them rather than starting from scratch.
- **State management layer** — shared reactive store that components
  subscribe to, enabling cross-component coordination without tight coupling.
