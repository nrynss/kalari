# P7: Ship

Everything the submission needs. Most of it is the user's.

Read first: [`../product.md`](../product.md) (Hackathon rules), [`../bench/RESULTS.md`](../bench/RESULTS.md).

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
requires:   [T6.3, T5.6]
fixture-ok: no
size:       M · user
owns:       docs/video.md
status:     not-started
```
The user records it. Centred on the containment moment: a real run where the aashaan's time cap kills a runaway loop, with the cap visible. Then the measured difference on upgrade two. The orchestrator drafts the script in `docs/video.md`.

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

## Exit Criteria

- [ ] Submitted, with a live demo URL and a judges' page.
