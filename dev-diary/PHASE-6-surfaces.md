# P6: Surfaces

What a person sees: the HTTP API, the web app with the judges' page, and the deployment on Vultr.

Read first: [`../product.md`](../product.md) (For judges, Hackathon rules), [`../docs/architecture.md`](../docs/architecture.md), `Examples/HttpServer.lean`, [`research/vultr-vm.md`](research/vultr-vm.md).

---

### T6.1: HTTP API
```yaml
requires:   [T4.2]
fixture-ok: yes
size:       M · mid
owns:       Kalari/Http.lean
status:     done
```
`Std.Http`, bound to 127.0.0.1 behind Caddy, read-only over the evidence store: sessions, runs (with verdict, checks, logs, timings, tokens), lessons, and the benchmark results. Body caps and 400/404/413 as in `Examples/HttpServer.lean`. No write endpoint: the web app shows; agents act through MCP.

**Done when:** each endpoint tested against a fixture evidence store; oversized and malformed requests answered correctly.

Implementation: `Kalari.Http.serve` binds loopback and reads a shared evidence store. GET `/api/sessions`, `/api/runs`, `/api/lessons`, `/api/benchmark`, `/api/sessions/<id>` and `/api/runs/<id>` return JSON; details retain all associated records. Benchmark results are records of kind `benchmark`; no benchmark producer currently writes that kind. Empty request bodies are required; methods other than GET have no route. Fixture checks cover all routes and missing and malformed paths. Automated HTTP handler regression checks a 4096-byte body is accepted by the cap (then rejected as an unexpected nonempty body with 400) and a 4097-byte body receives 413. A local HTTP probe observed 200 for `/api/runs`, 400 for an empty run ID, 404 for POST, and 413 for a 4097-byte body. Follow-up work remains to start `Kalari.Http.serve` from `kalari serve`, and to add a producer that writes `benchmark` records; neither is owned by T6.1.

---

### T6.2: The web app and the judges' page ★
```yaml
requires:   [T6.1]
fixture-ok: yes
size:       L · frontier
owns:       web/
status:     done
```
Chaaya. The first screen is **"For judges: start here"**: the measured before-and-after, each condition's result, the containment moment (a real run where the time cap fired), and links to every run. Then a session view: the change list, the blast radius, the recalled checks, each sandbox run with its verdict and logs, the retry loop, and the lesson written. Clef's probabilities labelled as a model's opinion, never as a measurement. A product-style experience, not a dashboard of raw JSON.

**Done when:** the pages render from the fixture evidence store; every number on the judges' page links to its run.

**Notes:** Chaaya is static HTML, CSS and ES modules under `web/site/`. The fixture store and server sit under `web/fixture/`, outside the published root. The fixture server injects a visible banner and serves no fixture file. The published pages never carry the banner. There are three views: the judges page, the session view and the run view.

The judges page shows 70 measured pilot rows, the baseline contrast for settlements, the containment run and a run index built from `/api/runs`. Condition 1 is marked invalid. The illustrative walkthrough is labelled wherever its numbers appear. Conditions 4 and 5 show explicit not-run rows. The frozen comparison shows a not-yet-published panel until T5.6 writes records. Clef percentages sit in a labelled opinion block and never in a table or a verdict.

`web/check.sh` hashes every served file and every rendered page. It validates every snapshot input against the benchmark contract. It compares every table value and measure link to the record named by its run link, and computes each median from the records. It fetches every run link and requires 200. It redacts every display path. It scans every served file for external URLs and navigation sinks, and asserts the CSP. A separate browser check loads five pages and fails a request outside the page origin.

Four review rounds blocked the first three commits. The final commit is `335bf2f`. The blockers were the fixture server serving `web/fixture/rendered/`, probability and banner checks that read only markers, a run id that resolved to a 404, hardcoded page counts, popup and navigation escapes, an invalid `repeat: 6` fixture, and an extra median anchor. Each fix is pinned by the mutation that used to pass.

`web/check.sh` now runs in `tools/check.sh`. The browser check stays separate because it needs Chrome.

Residual: no task writes `benchmark` records yet. T5.6 must write them or extend this contract. Caddy must serve `web/site/` in T6.3. The synthetic snapshots are view fixtures, not measurements.

---

### T6.3: Deploy on Vultr ★
```yaml
requires:   [T6.2, T2.3b]
fixture-ok: no
size:       M · mid
owns:       deploy/vultr/
status:     done
```
The Vultr preset: `kalari serve` as a systemd unit (`UMask=0022`, its own user, the key from a credentials file only that user reads, never in the unit), Caddy for TLS in front of the HTTP API, Lambo's store on the VM, and the benchmark APIs (`bench/apis/deploy.sh`). **Opening ports 80 and 443 in the Vultr firewall is the user's call**; SSH stays Tailscale-only. A domain name for the demo URL is the user's choice.

**Infrastructure: reuse the current VM only.** No resize and no second instance. Stop before any change that would increase its cost.

**Done when:** the demo URL serves the web app over HTTPS from the VM; a restart brings everything back; `deploy/vultr/README.md` takes a fresh VX1 to a running deployment.

**Notes:** `deploy/vultr/` holds the preset: `README.md` (fresh-VX1 path), `install.sh` (builds kalari from source on the VM, installs Caddy from the official apt repo, Lambo 0.9.0 after a sha256 check against the published release hash, msb plus the sandbox image for the kalari user, the units, the site, and the key over SSH stdin), `Caddyfile` (hostname only, static root plus `/api` reverse proxy), `kalari.service` (kalari serve as user kalari, UMask=0022, key from a 0600 EnvironmentFile, stdin held open since serve speaks MCP over stdio), `kalari-api.service`, `kalari-api.py` (loopback-only evidence API mirroring Kalari/Http.lean routes; verified response-identical to the fixture server on every route and status), and `*.example` configs (endpoints and `api_key_env` names only, never values). The demo serves HTTPS with an ACME certificate; `/api/benchmark` is empty so the judges page shows the not-yet-published panel, the expected state until T5.6. A restart of all three units brings everything back; firewall group and host filter hold inbound 80/443 only, SSH unchanged. Four install runs converged on this state: they caught a mistyped Lambo hash (retyped, then verified against the release asset), the stock Caddy config surviving `enable --now` (restart after installing the Caddyfile, plus a content check, not just status), an `admin off` block that broke every later reload (removed; admin stays on loopback), a `:80`-only local check behind the new HTTP-to-HTTPS redirect (checks now go through TLS with SNI to loopback), and an apostrophe in an in-quote comment that broke the script parse. Residual, not owned here: nothing starts `Kalari.Http.serve` from `kalari serve` yet (T6.1 note), so `/api` is the shim until that wiring lands; the first serve start appends one `lesson-policy` provenance record, which the judges page ignores while `/api/benchmark` is empty.

---

### T6.4: Publish benchmark evidence to the demo ★
```yaml
requires:   [T5.6, T6.3]
fixture-ok: no
size:       S · mid
owns:       bench/produce-evidence.py, bench/tests/produce-evidence-check.sh, deploy/vultr/ship-evidence.sh
status:     not-started
```
The live demo serves an empty evidence store: `/api/benchmark` is `[]` and `/api/runs` holds one provenance record, so the judges page cannot show the frozen comparison. Convert the 60 frozen rows (`bench/runs/kalari/*.json`, `bench/runs/reference/*.json`) into `benchmark` evidence records in the `web/README.md` contract and ship them to the VM store at `/var/lib/kalari/evidence/.kalari/evidence.jsonl`. Keep the existing `lesson-policy` provenance record. The ship step is idempotent: it replaces previously shipped benchmark records by run id, never duplicates. No inference calls. No key on the VM beyond what T6.3 provisioned.

After shipping, the judges page must render the frozen comparison with working run links on the live demo, and the empty-store panel must be gone. Report the unknown retry windows as unknown, never zero. Keep the containment demonstration (T5.6a) and its label separate: this task ships only frozen comparison rows.

**Live budget: $0.** Stop and report if any step needs inference or spend.

**Done when:** live `/api/benchmark` returns the shipped records; the live judges page shows the frozen comparison with every number linking to its run; the producer, its check, and a sanitized ship transcript are committed; `./tools/check.sh` passes.

---

---

## Exit Criteria

- [ ] A public, product-style web app on Vultr, with the judges' page first.
