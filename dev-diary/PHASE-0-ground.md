# P0: Ground

What every later phase codes against: the measured stack, the benchmark's APIs, and recordings of each outside tool in `testdata/`, so most tasks run offline.

Read first: [`research/`](research/README.md) (all of it), [`../bench/README.md`](../bench/README.md), [`../docs/lean.md`](../docs/lean.md).

---

### T0.1: Day-one checks
```yaml
requires:   []
fixture-ok: no
size:       L · frontier
owns:       dev-diary/research/
status:     done
```
Vultr Inference, the VM, Microsandbox, the aashaan in a microVM, Lambo, the coding agent: every check in `research/`, with its commands.

**Done when:** every check has a result in `research/` (done; B4 re-runs in T0.4).

---

### T0.2: Benchmark APIs ★
```yaml
requires:   [T0.1]
fixture-ok: yes
size:       L · frontier
owns:       bench/apis/, bench/workspaces/, bench/graders/, bench/prompts/, bench/tests/
status:     done
```
The payouts (REST) and settlements (GraphQL) services with v1 and v2, the arms' workspaces, the hidden grader, the prompts, reference consumers for each behaviour, and `bench/tests/quirks.sh` in the gate. Deployed on the VM (`bench/apis/deploy.sh`).

**Done when:** each obvious consumer fails the grader as `QUIRKS.md` predicts and the correct one passes, locally and from a Kalari-arm sandbox on the VM (done).

---

### T0.3: Vimanam on the benchmark specs ★
```yaml
requires:   [T0.2]
fixture-ok: no
size:       S · mid
owns:       testdata/vimanam/, dev-diary/research/vimanam.md
status:     done
```
Install Vimanam 2.0.0 (the local `target/release` binary is a stale 1.4.2 build; `~/.local/bin/vimanam` is 1.7.0, before GraphQL). Run `vimanam diff` on both workspaces' v1 and v2 specs with `--format json` (contract v2) and `--context --max-tokens`. Record the outputs in `testdata/vimanam/`.

The question that matters: **does it report `pagination_changed`** on `GET /v2/payouts` (OpenAPI; its pagination inference is conservative) and on `Query.settlements` (GraphQL, a Relay-style connection)? If not on one of them, record exactly what it does report, and write the Vimanam issue text in your report. Don't change the specs to suit Vimanam without the orchestrator: the specs are frozen with the pair (bench/README.md, Protocol 7).

**Done when:** both diffs are recorded; `research/vimanam.md` says which change kinds came back and with which IDs; any gap has issue text.

---

**Notes (done):** 2.0.0 from crates.io has no GraphQL (#133 merged after the tag); `main` does. **`pagination_changed` is reported for neither spec as built**: payouts' versioned paths are matched as removed + added, and its `cursor` field isn't on the continuation list; settlements' `nodes`-only connection isn't recognised without `edges`. Probes show each rule firing once its condition is met. Findings, rules and three issue texts in `research/vimanam.md`; recordings in `testdata/vimanam/`. **User decision raised:** fix Vimanam, adopt detectable real-world spec shapes before the pilot, or both.

---

### T0.6: Vimanam on its next release
```yaml
requires:   [T0.3]
fixture-ok: no
size:       S · mid
owns:       testdata/vimanam/, dev-diary/research/vimanam.md
status:     blocked
```
Blocked on a Vimanam release that fixes [vimanam#136](https://github.com/noemaforge/vimanam/issues/136)–[#139](https://github.com/noemaforge/vimanam/issues/139) (user decision: wait for Vimanam; the specs stay as built). Re-run T0.3's diffs on it, and the matrices in the issues. Re-record `testdata/vimanam/`.

**Done when:** `pagination_changed` is reported on both workspaces' specs as built, with the change IDs recorded; if one is still missed, the gap is reported back on its issue and this task stays blocked.

---

### T0.4: Lambo on its next release
```yaml
requires:   [T0.1]
fixture-ok: no
size:       S · mid
owns:       testdata/lambo/, dev-diary/research/lambo.md
status:     blocked
```
Blocked on the Lambo release with fixes for lambo#221 and lambo#222. Re-run B4 (`research/commands.md`) on it: provisioning a new store, embeddings on Qwen3 Embedding 4B, GC survival, Solo promotion, and the reworded-query recall ranking. Record the MCP transcripts Kalari's Lambo client (T3.2) will replay: `initialize`, `tools/list`, `lambo_derive`, `lambo_inspect`, `lambo_recall`, `lambo_stats` with a receipt.

**Done when:** the B4 table in `research/lambo.md` has the new release's results, including whether the lesson ranks first; transcripts are in `testdata/lambo/` with no key.

---

### T0.5: Recordings of the other outside tools ★
```yaml
requires:   [T0.1]
fixture-ok: no
size:       M · mid
owns:       testdata/clef/, testdata/msb/, testdata/opencode/, testdata/aashaan/
status:     claimed:claude-opus-5-5
```
What later tasks replay instead of calling the real thing:
- **Clef:** `/v1/systemone` replies for the three questions (why did a run fail; does this code call the changed operation; does this lesson apply), on realistic inputs from the benchmark. A handful each, including an `unrelated_bug` and a `flaky` case.
- **msb:** the stdout, stderr and exit codes of `create`, `copy`, `exec`, `stop`, `remove`, `list` (success and the failures already met: path substitution, a held pipe, an unknown sandbox).
- **OpenCode as an MCP client:** what OpenCode 2.2.5 sends to a local MCP server (initialize, tools/list, a tools/call, shutdown), captured with a logging stub server. This is the contract `kalari serve`'s MCP side must meet.
- **The aashaan:** its JSON verdicts for the eight cases, from inside a microVM.

**Done when:** each directory has its recordings and a README saying how each was made; no key in any file (grep, file names only).

---

## Exit Criteria

- [x] T0.1, T0.2 done.
- [x] Vimanam's verdict on the benchmark specs is known (T0.3).
- [ ] Vimanam re-checked on its next release (T0.6).
- [ ] Lambo re-checked on its next release (T0.4).
- [ ] Clef, msb, OpenCode and aashaan recordings in `testdata/` (T0.5).
