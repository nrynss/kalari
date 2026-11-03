# P2: Containment

The gate, the aashaan and the sandbox backend: what must hold in every run. The product's safety claims live here, so they are proved where they can be and tested where they can't.

Read first: [`research/sandbox.md`](research/sandbox.md), [`../docs/lean.md`](../docs/lean.md) (Proofs, Processes), `Examples/Gate.lean`, `Aashaan/Main.lean`, [`../AGENTS.md`](../AGENTS.md) (Sandboxes).

---

### T2.1: The gate ★
```yaml
requires:   [T1.5]
fixture-ok: yes
size:       M · frontier
owns:       Kalari/Gate.lean
status:     done
```
The decision every `run_in_sandbox` call passes before it reaches a backend: writes only inside the workspace, network only to the allowlisted hosts and ports, no secret in any argument (no value of a configured key variable, no string matching a key's shape), and every run capped (time, output, memory) within configured maximums. A plain, total `Bool` function over `RunRequest` and the config, and a reason when it refuses.

**Theorems, checked at build time:** anything allowed writes inside the workspace; connects only to an allowlisted host and port; is capped within the maximums; carries no configured key value in its arguments. `#guard` cases for concrete allows and refusals, including one that a trivially-refusing gate would fail.

**Done when:** the four theorems are proved with no `sorry`; the `#guard`s pass; a refusal's reason names the rule; the module imports nothing that touches IO.

Notes:

`decide : RunRequest → Caps → List AllowHost → List String → Bool × Option String`. `(true, none)` allows the run. `(false, some reason)` refuses it. The reason is the word `workspace`, `allowlist`, `caps`, `secret`, or `key-shape`, the first rule that failed, in that order. The `Bool` is the conjunction of those checks. The module imports `Kalari.Model` only. Cap comparisons call `Decidable.decide`, because this module's `decide` would shadow it. The values of configured keys arrive as the `secrets` argument. The function does not read the environment.

Path rule: the workspace must start with `/`, and every segment after that slash must be non-empty and neither `.` nor `..`. The empty string `splitOn` inserts for the leading slash is the root marker, not a path segment; counting it would refuse `/workspace`. An argument is a write path when it starts with `/` or contains the substring `..`. It is inside the workspace when it is the workspace, or the workspace plus `/` plus a relative path with the same segment rule. `/workspace` does not allow `/workspace-evil`. A relative argument with no `..` is not a write path.

Key shape: refuse when the workspace, any command argument, or any allowlist host contains 32 or more ASCII letters or digits in a row (`Char.isAlphanum`). This runs after the configured-secret check. No provider is named.

Surprises:

- `String.contains` takes a pattern. The empty pattern matches every string, so an empty secret has to be skipped before the substring check.
- `Examples/Gate.lean` uses `startsWith`, which treats `/workspace-evil` as inside `/workspace`. The real check requires a `/` on the segment boundary.
- A workspace of `/`, or one with a trailing slash, has an empty segment and is refused.

---

### T2.2: The aashaan, hardened
```yaml
requires:   [T1.5]
fixture-ok: yes
size:       S · frontier
owns:       Aashaan/, tests/aashaan-cases.sh, tests/live/microvm-cases.sh
status:     not-started
```
From the day-one probe to the shipped supervisor: the cap logic as pure functions with theorems (a verdict is `killed_timeout` exactly when the wall-clock cap passed first; `killed_output_cap` exactly when the output cap was crossed first; output returned is never longer than the cap); a stderr cap as well as stdout; a JSON string escaper tested on control characters and non-ASCII. Stays `Std`-only.

**Done when:** the theorems are proved; the eight cases still match in `tests/aashaan-cases.sh` and in a microVM (`tests/live/microvm-cases.sh`); the stripped binary stays under 5 MB.

---

### T2.3: Microsandbox backend ★
```yaml
requires:   [T1.4, T2.1, T0.5]
fixture-ok: yes
size:       M · mid
owns:       Kalari/Sandbox/Microsandbox.lean
status:     done
```
`SandboxBackend` over the `msb` CLI through the process runner: create with `--no-net` and `allow@<IP>/32:tcp:<port>` rules (hostnames resolved on the VM: domain rules fail for TLS), copy the workspace and the aashaan in, set `vm.overcommit_memory=1`, exec the aashaan with the caps, copy results out, stop and remove. Every sandbox is removed, on success, failure or a Kalari crash at the next start (sandboxes are named `kalari-<run-id>`). Runs with umask `0022`.

**Done when:** tests against the msb recordings (T0.5) cover each step, a failed create, and cleanup after a failed exec; the arguments it builds never contain `--net-default allow` or omit `--no-net`.

Notes:

Create argv is `msb create --name <name> --cpus 1 --memory <memory_mib>M --no-net`, then one `--net-rule allow@<host>/32:tcp:<port>` per allowlist entry, then `debian`. The name argument is the `--name`. Callers pass `kalari-<run-id>`. An empty allowlist still passes `--no-net` and passes no `--net-rule`, which is the `create-duplicate` shape. No argv adds `--net-default`. Copy in is `msb copy -q <host> <name>:<guest>`. Copy out is `msb copy -q <name>:<guest> <host>`. Exec is `msb exec <name> -- <command...>`. Destroy is `msb remove <name>`.

Remove is the cleanup, not stop. `exec-stopped` shows `exec` on a stopped sandbox starts it again, so a stopped sandbox is not gone. A run that created a sandbox calls `msb remove` on the way out, including when the job exits 3 (`exec-exit3`) and when a later copy fails. A failed create returns the error and does not exec or remove: `create-duplicate` can be a name this call did not create.

`make` takes a runner `(argv, timeoutMs, outputCap) → IO Result`. `live` binds that runner to `Proc.run` with an explicit `PATH` and `inheritEnv` false. The checks do not call `live`. Exec uses the request `timeout_ms` and `output_cap_bytes`. Create, copy, list, and remove use 30000 ms and that same output cap. The `#eval` runner replays `testdata/msb`. A case it was not given fails the build; it is not an empty success. One script covers create, copy in, the overcommit exec (`exec-sysctl`), the job (`exec-exit3`), copy out, and remove, and checks each result against the recording. The run script does both copies, then the same execs, then remove. A third script is the failed create.

The guest command is `sh -c` with `echo 1 > /proc/sys/vm/overcommit_memory`. The job argv is the caller's. This module does not wrap it, does not call the gate, and does not resolve DNS. `AllowHost.host` is already an IP.

Next start: `kalariNames` keeps `name` from `msb list --format json` (the row also has `image`, `status`, and `created_at`) when the name starts with `kalari-`. `reap` removes only those. The recorded list has none, so reap does not remove.

Umask: the process that starts Kalari uses `UMask=0022`. msb refuses group-writable storage (`storage-group-writable`). `Proc.run` has no umask argument, and this module does not set one.

Surprises:

- `SandboxBackend.exec` does not take a timeout, so `make` closes over the request timeout and the output cap.
- `create-ok` records a port range. `AllowHost` is one port, so each rule is one `tcp:<port>`, not a range.
- `msb exec` forwards the command exit code. Exit 3 is the job's result and is still followed by remove. The run returns that result, not the remove result.
- The overcommit recording also cats the sysctl. The command this module runs is only the write.

---

### T2.3b: Microsandbox backend, live
```yaml
requires:   [T2.3]
fixture-ok: no
size:       S · mid
owns:       tests/live/sandbox.sh
status:     not-started
```
On the VM: a run of `bench/apis/payouts/reference/correct.py` through the backend against the grading API (allowlisted), a run of `cursor_loop.py` killed by the time cap, and a run that tries the VM's SSH, the metadata service and the internet, all refused. `msb list` empty afterwards.

**Done when:** the transcript is in the report; every outcome as stated.

---

### T2.4: Docker backend (the generic fallback)
```yaml
requires:   [T2.3]
fixture-ok: yes
size:       S · mid
owns:       Kalari/Sandbox/Docker.lean, deploy/local/
status:     not-started
```
The same interface on Docker for hosts without KVM: `--network none` plus an allowlist (Docker has no per-IP rule, so a user-defined network with an egress proxy or nftables; the task decides and records why), `--memory`, `--pids-limit`, `--read-only` root with a writable workspace, `--rm`. Not on the demo path: Vultr uses Microsandbox.

**Done when:** tests against recorded `docker` output; `deploy/local/README.md` says how to run Kalari on a laptop.

---

## Exit Criteria

- [x] The gate's four properties proved.
- [ ] The aashaan's cap logic proved, eight cases passing in a microVM.
- [ ] Untrusted code runs only through the Microsandbox backend, always `--no-net`, always removed.
