# Microsandbox and the aashaan

Vultr has no sandbox product of its own. Its agent sandboxing guide uses **Microsandbox**: each sandbox is a microVM (libkrun on KVM) with its own kernel, booted from an OCI image. Kalari drives it through the `msb` CLI; Docker is the generic fallback backend.

## Decided

- **Microsandbox (msb 0.7.13) on the VX1 host.** No host firewall rules needed for egress: msb's own network policy does it.
- **Every untrusted run:** `msb create --no-net --net-rule allow@<IP>/32:tcp:<port> …`, the aashaan inside with its caps, `msb stop` + `msb remove` after.
- **Host kernel stays on Ubuntu 24.04's 6.8.**

## On the laptop too

**Microsandbox runs on the development laptop, not only on the VM** (msb 0.7.13, same user-space install, no sudo). `/dev/kvm` is `crw-rw-rw-` there (no `kvm` group needed), CPU `svm`, `kvm_amd` loaded, umask already `022`. `msb doctor` passes and finds **reflink support** (copy-on-write sandbox roots, unlike the VM). A cached `debian` microVM boots in **~360 ms**; the eight aashaan cases (`tests/live/microvm-cases.sh`) match in ~4.8 s. So live sandbox tests (T2.2's microVM clause, T2.3b, T4.5b's sandbox side) can run here; only what needs the benchmark APIs on the VM's IP, Vultr Inference with the VM's network, or the deployment needs the VM.

The `debian` image has no `python3`, and `--no-net` cannot install it. The live payouts run (`tests/live/sandbox.sh`) removes that sandbox and uses the `python` image, still `--no-net --pull never`. `msb remove` on a running sandbox fails (`sandbox still running`); `msb remove -f` stops it and removes it. A stopped sandbox must not be left behind, because `exec` starts it again. The Microsandbox backend image is `python:3.13-slim` (43069135 bytes, from `msb images`).

**Trap: Docker Hub pulls fail intermittently here.** The first pulls of a new image fail with `registry error: Not authorized: url https://index.docker.io/v2/library/<image>/manifests/<tag>`; the same pull succeeds on the third try (seen for `debian:bookworm`; `debian` also failed once). Never seen on the VM. So: **pull every image once at setup, with retries, and run with `--pull never`** (an msb option), so a run never depends on Docker Hub. AVIC (an optional KVM acceleration) is off on the laptop; leave it, as enabling it is a privileged host-wide change.

## B1: KVM and start-up

- `/dev/kvm` present (`crw-rw---- root kvm`), CPU flag `svm`. `msb doctor`: CPU virtualisation, KVM device and KVM access all pass. One warning: no reflink on the filesystem, so sandbox roots are copied, slower and larger. Informational.
- `msb run debian -- echo …`: 1.62 s including the image pull, **0.54 s cached**. Guest kernel 6.12.113, 1 vCPU by default. `msb run` leaves no sandbox behind.

**Trap: umask.** The first `msb run` failed: `catalog ancestor ~/.microsandbox permits path substitution; use a storage root protected from other accounts`. Ubuntu's umask `0002` made the installer's directories group-writable, and msb refuses that. Fix: `chmod -R go-w ~/.microsandbox`, and `umask 022` at the top of `~/.bashrc` and in `~/.profile`. **Any systemd unit that starts msb needs `UMask=0022`.**

## B2: the network policy

msb 0.7.13 flags: `--no-net` (deny by default), `--net-rule <action>[:<direction>]@<target>[:<proto>[:<ports>]]` (targets: IPs and CIDRs, domains, `*.suffix`, groups such as `public` and `private`, and `dns`), `--net-default[-egress|-ingress]`, DNS rebind protection on by default, `--net-egress-bandwidth`.

Probed with real requests from the `python` image, reading each response:

| Target | Default mode | `--no-net` | `--no-net` + IP rule |
|---|---|---|---|
| Public internet | open | refused, no DNS | only the allowed IP and port |
| **The VM's own public IP** | **open** (got the host's SSH banner) | refused | refused |
| Vultr metadata `169.254.169.254` | denied | denied | denied |
| Private ranges | denied | denied | denied |
| `allow@<IP>/32:tcp:443` to Vultr Inference | — | — | **works** (401 without a key, as expected) |
| `allow@api.vultrinference.com[:tcp:443]` | — | — | **fails: `SSLEOFError`**, with or without `allow@dns` |

- **Never run untrusted code in default mode.** Hairpin traffic to the VM's public IP never meets the Vultr firewall, so a default-mode sandbox reaches Caddy, `kalari` and SSH on the host.
- **Domain rules fail for TLS** in 0.7.13; resolve on the VM and pass IP rules. An upstream issue is still to be written.
- **Denials on port 80 come from msb itself:** `HTTP 403 {"code":"network_policy_denied","domain":"…","message":"Request blocked by network policy."}`. The host gets 200 from the metadata service; guests never do.
- **A bare TCP connect is not a valid probe.** msb's stack accepts the connection and then denies; only a response counts.
- **`--no-net` denies ingress as well as egress.** A server started with it never answers a published port (`-p`). For a server, use `--net-default-egress deny` and publish on the VM's public IP: see `bench/README.md`, The network route.
- **Port ranges work in rules:** `allow@<IP>/32:tcp:18080-18081`.
- **`--script` decodes `\r\n` escapes** in the script body and breaks code that contains them; use `--script-raw` with a `#!` line.

**msb's CLI behaviour (T0.5, `testdata/msb/`):** only `list` has machine output (`--format json`); errors are one `error:` line on stderr, exit 1; `exec` passes the command's exit code through; **`exec` on a stopped sandbox silently starts it again**, so the backend removes sandboxes, never just stops them; `create` with an existing name fails (`sandbox already exists`).

## B3: the aashaan inside a microVM

Built on the VM: `lake build` 6.4 s (peak 650 MB RSS); **3.3 MB stripped**, links glibc only, so use a glibc image (`debian`), not Alpine.

**Trap: overcommit.** Every case first aborted (exit 134): `lean::exception: failed to create thread: Resource temporarily unavailable`. The guest has no swap and heuristic overcommit (`CommitLimit` 133 MB at 256 MB RAM). It fails at 1 GB too; `ulimit -s` and `LEAN_NUM_THREADS=1` don't help. **`echo 1 > /proc/sys/vm/overcommit_memory` in the guest fixes it**, so Kalari sets it as root in every microVM before starting the aashaan.

All eight cases then match:

| Case | Verdict |
|---|---|
| normal | `exited` 0, stdout `hello`, stderr `warn`, ~11 ms |
| exit3 | `exited` 3 |
| loop, trapterm, fork | `killed_timeout` at ~809 ms; SIGTERM trap never fires (it's SIGKILL); forked children gone |
| flood | `killed_output_cap`, `stdout_truncated: true`, ~10 ms |
| secret | `exited` 0, stdout `key=[]`: the environment isn't passed |
| escape (`setsid sleep &`) | `killed_timeout`, **`pipe_held_open: true`**; the escaped process lives in the guest until teardown, never on the host |

Supervisor peak RSS ~5.5 MB. **`cgroup_memory_limit` reads 0 in the guest**: there's no cgroup limit there; the microVM's memory size is the cap.

**Per-run cost:** `msb create` 460 ms, first `exec` 26 ms, `stop` + `remove` 70 ms.

**Trap: a held pipe in `msb exec`.** A background process started inside `msb exec` without redirecting its output keeps the pipe open, and `exec` never returns: `(python3 server.py >/dev/null 2>&1 &)`, not `(python3 server.py &)`.

## Kernels

| Kernel | Version | Set by |
|---|---|---|
| VM host | 6.8.0 | Us. `linux-generic-hwe-24.04` offers 7.0.0; Vultr also has Ubuntu 26.04 (image `2760`) |
| microVM guest | 6.12.113 | Microsandbox's bundled `libkrunfw`, which follows the 6.12 LTS line (upstream v4.10.0 → 6.12.34, v5.6.2 → 6.12.109). **msb has no option to change it** |

Staying on 6.8: KVM works, and nftables, cgroup v2 and Landlock's network rules (6.7) are all there, with security support through 2029. 7.0's additions (KVM and scheduler tuning, confidential VMs, `sched_ext`) aren't used, and the HWE kernel moves with each point release. Containment rests on KVM and the guest's 6.12, which the host kernel doesn't change.

## `microsandbox-mcp` (the reference arm's tools)

0.7.13, `npx -y microsandbox-mcp`: **70 tools, ~67 KB of schemas (~17k tokens).** `sandbox_create` and `sandbox_run` take a `network` object; **the agent decides it**, and in the reference run it passed none. Host copy tools work only on allowlisted host paths.
