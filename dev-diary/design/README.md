# Kalari Visual Identity & Brand Assets (`T7.5`)

This directory holds the canonical SVG marks, diagrams, and CSS palette chosen by the user for **Kalari** (`T7.5`):

1. **Brand Mark — Option 1: *The Kuzhikalari Pit & Urumi***
   - **Stepped earthen pit walls (*Kuzhikalari*):** The sunken earthen training arena in laterite earth (`#a63a2b`) — representing the Microsandbox microVM containment perimeter.
   - **Four corner studs (`#f5f1e8`):** The four machine-checked Lean 4 theorems in [`Kalari/Gate.lean`](../../Kalari/Gate.lean) (`decide_WorkspacePath`, `decide_Allowlist`, `decide_Caps`, `decide_Secrets`), proved with zero `sorry`.
   - **Coiled gold *urumi* ribbon-sword (`#d99b38`):** The flexible, whipping multi-bladed sword — representing the runaway `while cursor:` pagination loop contained inside the pit.
   - **Aashaan's staff strike (`#171a1c` + `#f5f1e8` + `#a63a2b`):** The `kalari-aashaan` supervisor pinning the loop dead-center when a wall-clock or output cap fires.

2. **Color Palette — Option 1: *Laterite Pit & Ola Paper***
   - **Ola Palm-Leaf Paper (`#f5f1e8` / `#ece6da` / `#e4ddd0`):** Warm editorial canvas for prose, tables, and benchmark evidence. Harmonizes directly with Chaaya (`web/site/app.css`).
   - **Sunken Dark Arena (`#121514` / `#1b201e`):** Dark containment frame for the microVM boundary, hero cards, and dark-mode toggle.
   - **Charcoal Soot Ink (`#171a1c` / `#3f4347` / `#64615b`):** High-contrast body ink and 2px solid architectural borders with hard offset shadows (`#090b0c`).
   - **Laterite Earth Red (`#a63a2b` / `#882c20`):** Primary brand accent, pit perimeter, and containment fail/cap stamp (`killed_by_cap`, `FAIL`).
   - **Gold / Brass Urumi Blade (`#d99b38`):** Active candidate arm highlight, loop indicator, and interactive CTAs.
   - **Malabar Evergreen Pass (`#1f5a46`):** `proved` Lean theorems, `PASS` verdicts, and Lambo recall edges.

---

## Files in `dev-diary/design/`

| File | Purpose | Where to copy / use in `T7.5` |
|---|---|---|
| [`kalari-mark.svg`](kalari-mark.svg) | Full `128×128` Kuzhikalari Pit & Urumi emblem | Copy to `site/src/assets/kalari-mark.svg` (used in Starlight `logo.src` and hero) |
| [`favicon.svg`](favicon.svg) | Compact `32×32` Kuzhikalari Pit & Urumi icon | Copy to both `web/site/favicon.svg` and `site/public/favicon.svg` |
| [`containment-loop.svg`](containment-loop.svg) | Responsive `880×185` 5-step Containment & Memory Loop diagram | Embed in `site/src/components/ContainmentLoopSvg.astro` on the landing page and **How it works** |
| [`architecture.svg`](architecture.svg) | Responsive `880×280` 3-plane Architecture diagram (Lean 4 Host / Microsandbox + Aashaan / Caddy + Lambo + Vultr) | Embed in `site/src/components/ArchitectureSvg.astro` on **How it works** |
| [`kalari-palette.css`](kalari-palette.css) | Complete CSS custom properties for both Chaaya (`SECTION A`) and Starlight (`SECTION B`) | Apply `SECTION A` to `web/site/app.css` `:root`; copy `SECTION B` to `site/src/styles/kalari.css` |

---

## Inline Header Wordmark SVG for Chaaya (`web/site/*.html`)

When updating [`web/site/index.html`](../../web/site/index.html), [`web/site/session.html`](../../web/site/session.html), and [`web/site/run.html`](../../web/site/run.html), replace the `<svg viewBox="0 0 24 24" ...>` inside `<a class="wordmark" ...>` with this compact `24×24` Kuzhikalari Pit & Urumi mark, and add the same-origin `<a href="/docs/">Documentation</a>` link inside `<nav class="site-nav" aria-label="Main">`:

```html
<a class="wordmark" href="index.html" aria-label="Kalari, for judges">
  <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
    <rect x="2" y="2" width="20" height="20" rx="3.5" fill="none" stroke="currentColor" stroke-width="1.6" />
    <rect x="5.5" y="5.5" width="13" height="13" rx="1.5" fill="none" stroke="#a63a2b" stroke-width="1.2" />
    <circle cx="5.5" cy="5.5" r="1.2" fill="#f5f1e8" />
    <circle cx="18.5" cy="5.5" r="1.2" fill="#f5f1e8" />
    <circle cx="5.5" cy="18.5" r="1.2" fill="#f5f1e8" />
    <circle cx="18.5" cy="18.5" r="1.2" fill="#f5f1e8" />
    <path
      d="M 12 7.5 C 15.2 7.5, 16.5 9.6, 16.5 12 C 16.5 14.6, 14.2 16.5, 11.6 16.5 C 9 16.5, 7.5 14.4, 7.5 12 C 7.5 9.9, 9.4 8.9, 11.3 9.4"
      fill="none"
      stroke="#d99b38"
      stroke-width="1.5"
      stroke-linecap="round"
    />
    <line x1="12" y1="3" x2="12" y2="21" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
    <circle cx="12" cy="12" r="2" fill="#a63a2b" />
  </svg>
  <span>Kalari</span>
</a>
```

After updating `web/site/favicon.svg`, `web/site/app.css`, and `web/site/*.html`, always regenerate the snapshot manifest and run the gate:

```bash
node web/fixture/render.mjs
./web/check.sh
```
