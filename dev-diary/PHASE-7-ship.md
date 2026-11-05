# P7: Ship

Everything the submission needs. Most of it is the user's.

Read first: [`../product.md`](../product.md) (Hackathon rules), [`../bench/RESULTS.md`](../bench/RESULTS.md), [`design/README.md`](design/README.md) (for T7.5).

## Documentation style (all P7 writing)

Keep every sentence within 30 words. Never use an em dash or a semicolon. Prefer active voice. Use plain words. Keep comma-separated phrases to a minimum. These rules cover the README, the video script, the slides, the diary, and every report.

---

### T7.1: The README ★
```yaml
requires:   [T5.6, T6.3]
fixture-ok: yes
size:       S · frontier
owns:       README.md
status:     not-started
```
Setup docs for both presets; which Vultr services are used and how they power the solution (the rules require it); the architecture; the use case; the result with its numbers and links; what is proved and what isn't (the gate and the aashaan, not the agent's code); the libraries named with their licences (Vimanam Apache-2.0, Lambo, Microsandbox, graphql-core MIT).

**Done when:** a reader can set up the Vultr preset from the README alone; every claim links to evidence.

---

### T7.2: The video
```yaml
requires:   [T6.3, T5.6, T5.6a]
fixture-ok: no
size:       M · user
owns:       (none)
status:     not-started
```
The user records it. As for Doyle (user decision), the script, shot list, cut table, takes and capture rig live in the demo-shoot folder outside the repository, never committed; the repository links to the finished video. The orchestrator drafts the script there. Sessions are filmed on the VM, where the benchmark ran; host names and IPs are blurred in post (user decision). T5.6a's live run is filmed as it happens.

Use T5.6a's cursor-loop failure as the central scene. Show the configured cap, measured elapsed time, timeout verdict, and failed consumer outcome. Follow with the observed network boundary and verified cleanup.

Then show T5.6's measured comparison and its zero-lesson limitation. Link the demonstration separately from benchmark rows. Record output and memory caps as configuration.

**Done when:** the user has the recording.

---

### T7.3: Public repository
```yaml
requires:   [T7.1]
fixture-ok: yes
size:       XS · user
owns:       (none)
status:     not-started
```
Before the user makes it public: a scan for any key value (file names only), IP address, instance ID, account detail or private repository name in the tree and the history.

**Done when:** the scan is clean, and the user has made the repository public.

---

### T7.4: Submit
```yaml
requires:   [T7.2, T7.3]
fixture-ok: no
size:       XS · user
owns:       (none)
status:     not-started
```
The user submits on lablab.ai: title, short and long descriptions, **Vultr's technology tagged** (VM, Serverless Inference, the sandbox; not the coding tools), cover image, video, slides, the public repository, the demo URL.

**Done when:** submitted.

---

### T7.5: Public documentation site
```yaml
requires:   [T5.6, T5.6a, T6.3, T7.3]
fixture-ok: yes
size:       M · mid
owns:       site/, .github/workflows/pages.yml, deploy/vultr/install.sh, web/site/, web/fixture/rendered/
status:     not-started
```
Build a static Astro and Starlight documentation site in `site/` and serve it on **both** GitHub Pages (`.github/workflows/pages.yml`) and the Vultr VM at `https://kalari.nryn.dev/docs/` alongside the live Chaaya judge console at `https://kalari.nryn.dev/`:

- **Dual deployment (`ASTRO_SITE` / `ASTRO_BASE`).** Parameterize `site/astro.config.mjs` via `ASTRO_SITE` and `ASTRO_BASE` so `.github/workflows/pages.yml` builds for GitHub Pages (with CTAs and run links pointing to `https://kalari.nryn.dev/`), while `deploy/vultr/install.sh` builds with `ASTRO_BASE=/docs` and syncs `site/dist/` into `/srv/kalari/www/docs/` behind the existing Caddy `file_server`. Add a same-origin `/docs/` link in `web/site/index.html` so Chaaya and the docs cross-link without violating `web/check.sh`'s zero-external-URL or `default-src 'self'` CSP rules.
- **Visual identity (`dev-diary/design/`).** Use the canonical SVG and CSS files in [`design/`](design/README.md) — do not invent new icons, colors, or diagrams:
  - Copy [`design/kalari-mark.svg`](design/kalari-mark.svg) (`128×128` **Kuzhikalari Pit & Urumi** emblem) to `site/src/assets/kalari-mark.svg`.
  - Copy [`design/favicon.svg`](design/favicon.svg) (`32×32` compact emblem) to both `web/site/favicon.svg` and `site/public/favicon.svg`, and replace the inline header `<svg>` in `web/site/index.html`, `web/site/session.html`, and `web/site/run.html` with the `24×24` wordmark snippet in [`design/README.md`](design/README.md).
  - Apply `SECTION A` of [`design/kalari-palette.css`](design/kalari-palette.css) (**Laterite Pit & Ola Paper** `:root` tokens: `--paper: #f5f1e8`, `--ink: #171a1c`, `--accent: #a63a2b`, `--brass: #d99b38`, `--pass: #1f5a46`, `--dark: #121514`) to `web/site/app.css` and regenerate `web/fixture/rendered/` via `node web/fixture/render.mjs`.
  - Copy `SECTION B` of [`design/kalari-palette.css`](design/kalari-palette.css) to `site/src/styles/kalari.css` and wire [`design/containment-loop.svg`](design/containment-loop.svg) and [`design/architecture.svg`](design/architecture.svg) into `site/src/components/ContainmentLoopSvg.astro` and `site/src/components/ArchitectureSvg.astro`.
- **Start here.** Explain the use case, walk judges through the live console at `https://kalari.nryn.dev/`, and link to the repository and video when available.
- **How it works.** Explain the Lean 4 gate (linking the 4 proved theorems in `Kalari/Gate.lean`), the `kalari-aashaan` and Microsandbox microVM boundary, and how Lambo recall informs a run.
- **Run it yourself.** Document both presets, configuration, and `./tools/check.sh`. Keep the README usable on its own.
- **Containment walkthrough.** Use T5.6a for one cursor-loop timeout scene, followed by boundary and cleanup evidence. Show configured and measured timing together. Link its evidence separately from benchmark rows.
- **Evidence and limits.** Explain the benchmark method, cite T5.6 for measured claims and link to individual runs on `https://kalari.nryn.dev/`. Distinguish the observer rehearsal from current production behavior.

**Done when:** the Pages build and `/docs/` build both pass, `./web/check.sh` passes with the updated Chaaya theme and `/docs/` link, navigation and links work on both GitHub Pages and `https://kalari.nryn.dev/docs/`, the judge walkthrough reaches the public demo and run evidence, and the published site passes the same privacy scan as the repository.

---

### T7.5a: Chaaya re-theme ★
```yaml
requires:   []
fixture-ok: yes
size:       S · mid
owns:       web/site/, web/fixture/rendered/
status:     done
```
Apply the decided visual identity to the live console, ahead of the docs site. Copy SECTION A of `dev-diary/design/kalari-palette.css` (Laterite Pit and Ola Paper `:root` tokens) into `web/site/app.css`. Copy `dev-diary/design/favicon.svg` to `web/site/favicon.svg` and replace the inline header SVG in `web/site/index.html`, `web/site/session.html`, and `web/site/run.html` with the wordmark snippet in `dev-diary/design/README.md`. Regenerate with `node web/fixture/render.mjs`. No new icons, colors, or diagrams. No `/docs/` link here; that ships with T7.5 once `site/` exists.

**Done when:** `./web/check.sh` passes with the new theme; the rendered snapshots match; the privacy scan stays clean. No live spend.

Notes. Replaced the `:root` block in `web/site/app.css` with SECTION A from `dev-diary/design/kalari-palette.css`. Kept every other rule unchanged. Added back `--brass` and `--shadow` tokens from SECTION A. No rule used a removed token, so no rule needed a rewrite. Copied `dev-diary/design/favicon.svg` to `web/site/favicon.svg`. Replaced the inline header mark in `index.html`, `session.html`, and `run.html` with the `24x24` wordmark snippet. Kept the CSP meta tags and the nav unchanged. Added no `/docs/` link. Ran `node web/fixture/render.mjs`. Only `manifest.json` hashes changed. The rendered page output did not change. Ran `./web/check.sh`. It passed. Ran `./tools/check.sh`. It passed. The accent moves from muted rust to laterite red. The fail color now matches the accent. The dark panel turns a touch greener. The header mark shows the pit, the brass coil, and the staff pin. The favicon shows the compact pit emblem.

---

## Exit Criteria

- [ ] Submitted, with a live demo URL and a judges' page.
