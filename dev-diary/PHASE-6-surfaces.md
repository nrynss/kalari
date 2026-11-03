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
status:     not-started
```
`Std.Http`, bound to 127.0.0.1 behind Caddy, read-only over the evidence store: sessions, runs (with verdict, checks, logs, timings, tokens), lessons, and the benchmark results. Body caps and 400/404/413 as in `Examples/HttpServer.lean`. No write endpoint: the web app shows; agents act through MCP.

**Done when:** each endpoint tested against a fixture evidence store; oversized and malformed requests answered correctly.

---

### T6.2: The web app and the judges' page ★
```yaml
requires:   [T6.1]
fixture-ok: yes
size:       L · frontier
owns:       web/
status:     not-started
```
Chaaya. The first screen is **"For judges: start here"**: the measured before-and-after, each condition's result, the containment moment (a real run where the time cap fired), and links to every run. Then a session view: the change list, the blast radius, the recalled checks, each sandbox run with its verdict and logs, the retry loop, and the lesson written. Clef's probabilities labelled as a model's opinion, never as a measurement. A product-style experience, not a dashboard of raw JSON.

**Done when:** the pages render from the fixture evidence store; every number on the judges' page links to its run.

---

### T6.3: Deploy on Vultr ★
```yaml
requires:   [T6.2, T2.3b]
fixture-ok: no
size:       M · mid
owns:       deploy/vultr/
status:     not-started
```
The Vultr preset: `kalari serve` as a systemd unit (`UMask=0022`, its own user, the key from a credentials file only that user reads, never in the unit), Caddy for TLS in front of the HTTP API, Lambo's store on the VM, and the benchmark APIs (`bench/apis/deploy.sh`). **Opening ports 80 and 443 in the Vultr firewall is the user's call**; SSH stays Tailscale-only. A domain name for the demo URL is the user's choice.

**Done when:** the demo URL serves the web app over HTTPS from the VM; a restart brings everything back; `deploy/vultr/README.md` takes a fresh VX1 to a running deployment.

---

## Exit Criteria

- [ ] A public, product-style web app on Vultr, with the judges' page first.
