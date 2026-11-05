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

Installation must start with a verified release archive and checksum. Explain binary placement, supported hosts, external dependencies, configuration, and MCP registration. Include source-build instructions for contributors.

Show one complete migration on a supported local machine and the Vultr path. Link detailed setup and troubleshooting from T7.5. Keep enough instructions here for independent setup.

**Done when:** a reader can install and configure the Vultr preset from the README alone. The documented release exists and its checksum verifies. Every claim links to evidence.

---

### T7.2: The video
```yaml
requires:   [T6.3, T5.6, T5.6a]
fixture-ok: no
size:       M · user
owns:       (none)
status:     done
```
The user records it. As for Doyle (user decision), the script, shot list, cut table, takes and capture rig live in the demo-shoot folder outside the repository, never committed; the repository links to the finished video. The orchestrator drafts the script there. Sessions are filmed on the VM, where the benchmark ran; host names and IPs are blurred in post (user decision). T5.6a's live run is filmed as it happens.

Use T5.6a's cursor-loop failure as the central scene. Show the configured cap, measured elapsed time, timeout verdict, and failed consumer outcome. Follow with the observed network boundary and verified cleanup.

Then show T5.6's measured comparison and its zero-lesson limitation. Show the containment runs as runs, apart from the benchmark rows. Record output and memory caps as configuration.

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
status:     in-review:t7-5
```
Build a static Astro and Starlight documentation site in `site/` and serve it on **both** GitHub Pages (`.github/workflows/pages.yml`) and the Vultr VM at `https://kalari.nryn.dev/docs/` alongside the live Chaaya judge console at `https://kalari.nryn.dev/`:

- **Dual deployment (`ASTRO_SITE` / `ASTRO_BASE`).** Parameterize `site/astro.config.mjs` via `ASTRO_SITE` and `ASTRO_BASE` so `.github/workflows/pages.yml` builds for GitHub Pages (with CTAs and run links pointing to `https://kalari.nryn.dev/`), while `deploy/vultr/install.sh` builds with `ASTRO_BASE=/docs` and syncs `site/dist/` into `/srv/kalari/www/docs/` behind the existing Caddy `file_server`. Add a same-origin `/docs/` link in `web/site/index.html` so Chaaya and the docs cross-link without violating `web/check.sh`'s zero-external-URL or `default-src 'self'` CSP rules.
- **Visual identity (`dev-diary/design/`).** Use the canonical SVG and CSS files in [`design/`](design/README.md) — do not invent new icons, colors, or diagrams:
  - Copy [`design/kalari-mark.svg`](design/kalari-mark.svg) (`128×128` **Kuzhikalari Pit & Urumi** emblem) to `site/src/assets/kalari-mark.svg`.
  - Copy [`design/favicon.svg`](design/favicon.svg) (`32×32` compact emblem) to both `web/site/favicon.svg` and `site/public/favicon.svg`, and replace the inline header `<svg>` in `web/site/index.html`, `web/site/session.html`, and `web/site/run.html` with the `24×24` wordmark snippet in [`design/README.md`](design/README.md).
  - Apply `SECTION A` of [`design/kalari-palette.css`](design/kalari-palette.css) (**Laterite Pit & Ola Paper** `:root` tokens: `--paper: #f5f1e8`, `--ink: #171a1c`, `--accent: #a63a2b`, `--brass: #d99b38`, `--pass: #1f5a46`, `--dark: #121514`) to `web/site/app.css` and regenerate `web/fixture/rendered/` via `node web/fixture/render.mjs`.
  - Copy `SECTION B` of [`design/kalari-palette.css`](design/kalari-palette.css) to `site/src/styles/kalari.css` and wire [`design/containment-loop.svg`](design/containment-loop.svg) and [`design/architecture.svg`](design/architecture.svg) into `site/src/components/ContainmentLoopSvg.astro` and `site/src/components/ArchitectureSvg.astro`.
- **Start here.** Explain the use case, walk judges through the live console at `https://kalari.nryn.dev/`, and link to the repository and video when available.
- **Architecture (its own page, user decision).** A dedicated page, linked from the top navigation and from "Start here", that a judge can read in five minutes. Derive every statement from the code and `docs/architecture.md`, `product.md` (Shape) and `dev-diary/research/`; link each claim to its file on GitHub. Cover:
  - **The picture.** `design/architecture.svg` first: the coding agent connecting over MCP; `kalari serve` on the VM; one Microsandbox microVM per run with `kalari-aashaan` inside; Vultr Serverless Inference; Lambo as a child process; Vimanam and `msb` as subprocesses; Caddy and the read-only web app. Then `design/containment-loop.svg` for one run.
  - **Two Lean programs, and why Lean.** `kalari` (the MCP service, the gate, the run pipeline, the evidence store) and `kalari-aashaan` (the supervisor inside every microVM). Lean 4 native executables so the containment logic carries theorems checked at build time ("proved, not just tested"), and so the supervisor is a small static binary (about 3 MB, `Std` only, no compiler runtime) that starts inside each guest. State honestly what the proofs cover (the gate's decision and the aashaan's caps) and what they do not (the agent's generated code, the sandbox backend).
  - **The gate and its four theorems.** `decide_workspace`, `decide_network`, `decide_caps`, `decide_secrets` in `Kalari/Gate.lean`: what each guarantees, in plain words, with the theorem lines linked.
  - **A run, step by step.** The gate check; hostname resolution to IP rules; `msb create … --no-net` plus one allow rule; copying the workspace and the aashaan in; `vm.overcommit_memory=1`; `kalari-aashaan <timeout> <output-cap> <cmd>` with an empty environment and explicit `PATH`; the verdicts (`exited`, `killed_timeout`, `killed_output_cap`); the trusted checks (candidate truth and the differential against v1 in fresh guests); the artifact read and its failure messages (0.1.2); teardown. Use the T5.6a runs as the worked example.
  - **The five tools.** What each MCP tool does, what it calls (Vimanam, code search, Lambo, the sandbox), and what it returns, including `blast_radius`'s per-ID statuses (0.1.1).
  - **Memory.** Lambo as Kalari's single writer, lessons keyed by change kind, why lookup is by traversal from the change kind, and the measured limit: zero published lessons in the frozen runs.
  - **Judgement calls.** Clef's three questions: a model's opinion, logged, never in the gate and never the verdict.
  - **Security boundaries.** No key in any guest; per-run network policy versus the reference setup's agent-chosen network; what `--no-net` denies; the TLS domain-rule limitation and the IP-rule workaround; Caddy terminating TLS; SSH over Tailscale only.
  - **Deployment.** The Vultr preset (VX1 VM, systemd units, `UMask=0022`, the key from a credentials file), the generic local preset, and what "runs on Vultr, and anywhere else" means in practice.
  - **Dependencies.** Each with its version, how it is invoked (subprocess, child process, CLI) and why, from `docs/architecture.md` (Dependencies).
- **Run it yourself.** Document both presets, configuration, and `./tools/check.sh`. Keep the README usable on its own.

  Installation and setup must cover the following topics. Derive commands from the implementation and verify them. Mark unavailable release assets and untested platforms explicitly.

  - **Release installation.** Link the published version, archive, and checksums. Show checksum verification, extraction, executable permissions, PATH setup, version checks, upgrade, and removal. Cover both executables. Do not require Lean for binary users. Document the actual architecture, operating system, libc floor, and dynamic libraries from release validation.
  - **Host requirements.** Explain CPU virtualization, accessible `/dev/kvm`, disk needs, and `msb doctor`. Distinguish the host running the coding agent from the host running Kalari. State what has been tested on Linux. Explain macOS, Windows, WSL, and remote Linux options only where verified. Do not imply a remote MCP connection exists without working transport instructions.
  - **Dependencies and ownership.** Give tested versions and installation checks for Microsandbox, Lambo, Vimanam, curl, and required language runtimes. Explain which host needs each tool. Explain how Lambo runs as a child process. Identify optional model and deployment components. State who pays for each service.
  - **Sandbox preparation.** Document `umask 0022`, writable storage, image caching with retries, and execution with `--pull never`. Explain guest `vm.overcommit_memory=1` and how the production path sets it. Show how runtimes, dependencies, code, and the aashaan reach the guest. Identify unsupported consumer runtimes and dependency installation limits.
  - **Network setup.** Explain host endpoints versus guest endpoints, API reachability, and separate baseline and candidate allowlists. Show IP-and-port rules and hostname resolution. Explain the recorded TLS domain-rule limitation. Cover local APIs and remote APIs with working examples. Keep keys outside guests.
  - **Configuration reference.** Document every supported field in both JSON files, its type, default, constraints, and path interpretation. Cover model endpoints, key environment names, Lambo configuration, sandbox limits, and executable paths. Use `deploy/vultr/*.example`, `Kalari/Model.lean`, and the actual parser as sources. Explain that deployment placeholders need replacement.
  - **Bring your own migration.** List required inputs: old and new specifications, baseline and candidate workspaces, consumer command and arguments, output artifact, check workspace, evidence workspace, session identity, and repository scope. Explain baseline isolation, comparable input data, credentials, and API availability. Show how to preserve a baseline before editing.
  - **Verification harness.** Explain the candidate and baseline executions, trusted checks, differential comparison, artifact format, and pass criteria. State current comparison assumptions and supported specification formats. Explain which checks Kalari supplies and which adapters the developer must write. Show a minimal consumer adapter that emits the supported artifact. Keep benchmark hidden grading distinct from a user's verification harness.
  - **Coding-agent integration.** Give copyable OpenCode MCP configuration invoking `kalari serve <config.json> <session.json>`. Use absolute paths and show environment handling. Verify initialization and discovery of all five tools. Explain agent restart and how the agent selects tools. Add other clients only after testing their configuration.
  - **First successful run.** Provide a small reproducible migration using recorded or local replies without production credentials. Show the initial request, expected tool sequence, successful artifact, failed check, and timeout interpretation. State exactly which steps require network access, KVM, or paid services.
  - **Evidence and interface.** Explain where records and logs live, how sessions map to runs, and how developers inspect them. Document the current read-only web deployment and API shim accurately. Distinguish starting the MCP server from serving the web interface.
  - **Limits and troubleshooting.** Explain observer rejection and zero published lessons in measured production runs. Cover missing KVM, image pulls, permissions, guest PATH, TLS allowlists, absent artifacts, baseline failures, and interrupted-run cleanup. Use real errors and recovery commands. Avoid presenting planned `kalari check` as implemented.
  - **Contributor and deployment paths.** Include pinned Lean source builds and `./tools/check.sh`. Separate offline checks from optional live tests and their budgets. Explain the Vultr service user, key delivery, restart, and public HTTPS setup.

  **Setup acceptance.** Record exact host versions and commands used to validate the guide. A clean supported host must install the release without Lean, discover five MCP tools, and complete the documented sample. Verify one failure and evidence inspection. Report every unverified platform or step. If an example needs new code outside task ownership, request an ownership extension before implementing it.

- **Judges walkthrough (its own page, user decision).** One page, second in the navigation after "Start here", that walks a judge through every result in the order of the demo video, each figure linked to its run on `https://kalari.nryn.dev/` and to its file on GitHub pinned to a commit. Numbers come from a build-time data step that reads the committed evidence (`bench/frozen-evidence.jsonl`, `bench/RESULTS.md`, `tests/live/containment-evidence/`, `bench/showcase/disbursements/runs/`, `bench/reference-paging/README.md`), never typed by hand; the build fails if a computed figure disagrees with `RESULTS.md`. In order:
  - **The problem:** the reference run: `imported 100 items`, exit 0, 2,331 of 2,431 records lost (DeepSeek V4.1 Flash, OpenCode with microsandbox-mcp).
  - **The frozen comparison:** both arms OpenCode 2.2.5 with DeepSeek V4.1 Flash on Vultr Serverless Inference; 60 sessions (Kalari 20, reference 40); the hidden grader passed every session in both arms; cost per session about $0.019 against $0.082 (4.2× cheaper); wall time about 26 s against 84 s (3.3× faster); time stuck 0 s against 799 s; the per-condition table. Say plainly why sandbox runs are higher for Kalari (it also runs v1 for the differential) and why token columns are not compared across arms (`RESULTS.md` §4).
  - **The zero-lesson finding:** no lesson was published in the frozen runs, so memory showed no benefit there (`RESULTS.md` §1).
  - **Containment:** run 1 (the reference `cursor_loop.py` crashed on the API's 429 after 437 ms) and run 2 (killed by the aashaan at 5,009 ms against the 5,000 ms cap, 68 pages, `passed=false`); the boundary (one allowed port answered, four targets refused); cleanup (no sandbox, no process left).
  - **Across models (the showcase, a manufactured scenario):** the grid of the 14 committed runs: GLM 5.3 Flash, Qwen3.8 27B, Muse Glimmer 30B, MiMo V2.6 Flash and DeepSeek V4.1 Flash, OpenCode alone against OpenCode with Kalari; silent corruption without Kalari, every affected session flagged with Kalari, fixed in 1 of 4; DeepSeek alone right 3 of 3. Link `QUIRKS.md`.
  - **What this does not show:** the limits, stated in the same tone as the results (memory, the manufactured scenario, five repeats per condition, `RESULTS.md` §7).
  - **Where to look next:** the live judges page, the run pages, the Architecture page, the video.
- **Diagrams in Mermaid, in the palette (user decision).** Besides the canonical `design/*.svg` (architecture and containment loop stay as drawn), the docs use Mermaid for every other diagram, rendered at build time to inline SVG (no client-side Mermaid, no CDN: it must work on GitHub Pages and behind the VM's same-origin rules). Theme it from `design/kalari-palette.css` through Mermaid `themeVariables` (paper background, ink text and lines, rule borders) and a fixed set of `classDef`s used the same way everywhere: `kalari` in pass green, `reference` in rust, `gate` in brass, `neutral` in ink on paper; a dark variant from section B for dark mode. Every diagram has a one-line caption and a text alternative, and passes contrast. At least:
  - **System context** (flowchart): the coding agent, `kalari serve`, Lambo, Vimanam, `msb` and the microVMs, Vultr Serverless Inference, Caddy and the web app.
  - **One `run_in_sandbox` call** (sequence diagram): agent → kalari → gate → msb create → aashaan → candidate and baseline → trusted checks → artifact → evidence store → teardown.
  - **Verdicts** (state diagram): `exited`, `killed_timeout`, `killed_output_cap`, and how each maps to `passed`.
  - **The showcase, two paths** (flowchart): OpenCode alone (rust): dedupe keep-first → `/v2/verify` passes → "verified" → grader FAIL, 23 changed; OpenCode with Kalari (green): differential "23 changed" → fix keep-last → "0 changed" → grader PASS.
  - **The benchmark design** (flowchart): the six conditions, the frozen pair, the hidden grader.
  - **Deployment** (flowchart): the Vultr VX1 VM, systemd units, the API microVMs on published ports, Tailscale SSH, Caddy TLS.
- **Containment walkthrough.** Use T5.6a for one cursor-loop timeout scene, followed by boundary and cleanup evidence. Show configured and measured timing together. Link its evidence separately from benchmark rows.
- **Evidence and limits.** Explain the benchmark method, cite T5.6 for measured claims and link to individual runs on `https://kalari.nryn.dev/`. Distinguish the observer rehearsal from current production behavior.

**Done when:** the Pages build and `/docs/` build both pass, `./web/check.sh` passes with the updated Chaaya theme and `/docs/` link, navigation and links work on both GitHub Pages and `https://kalari.nryn.dev/docs/`, the judge walkthrough reaches the public demo and run evidence, the Architecture page is in the navigation with both diagrams and every claim linked to its source, the Judges walkthrough's figures are computed from the committed evidence and match `RESULTS.md`, every Mermaid diagram renders at build time in the palette with a caption and text alternative, and the published site passes the same privacy scan as the repository.

Notes (T7.5 report). Built a static Astro and Starlight site in `site/`. The Pages build uses base `/kalari`. The VM build uses base `/docs`. Both produce 9 pages. A build-time data step reads only committed evidence and fails on mismatch with `RESULTS.md`. Six Mermaid diagrams render at build time with `mmdc` and system Chrome. No Mermaid runs in the browser. Canonical SVGs ship as Astro components. The Chaaya shells link `/docs/` with same-origin paths, and `./web/check.sh` passes. The installer builds the docs and syncs `site/dist/` into `/srv/kalari/www/docs/`. The Vultr page names Cloud Compute, Serverless Inference, and the firewall group with repo links. Setup acceptance records verified steps on the laptop and names each unverified step on its page. The video link stays text until the recording lands.
- `site/`, `.github/workflows/pages.yml`, `deploy/vultr/install.sh`, `web/site/`, `web/fixture/rendered/`

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
