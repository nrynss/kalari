# Research: what the stack actually does

Measured before any Kalari code, on the real accounts and the real VM. Each file is one area: what was decided, the evidence, the traps already hit, and the commands to reproduce it. **Read the file for your area before you build.**

| File | Area | Settles |
|---|---|---|
| [`vultr-inference.md`](vultr-inference.md) | Vultr Serverless Inference | Model IDs, tool calling, Clef's answer shape, embeddings, limits, prices, the measured budget |
| [`vultr-vm.md`](vultr-vm.md) | The VM | Plan and region, access over Tailscale only, the firewall, the user, teardown |
| [`sandbox.md`](sandbox.md) | Microsandbox and the aashaan | KVM, start-up and teardown times, the network policy and its traps, overcommit, umask, kernels |
| [`lean.md`](lean.md) | Lean 4.35.0 | What `Std` gives (HTTP server, processes, async), what it lacks (HTTP client, TLS), binary sizes, API drift, upstream issues |
| [`lambo.md`](lambo.md) | Lambo 0.8.0 | Configuration, GC survival, Solo promotion timing, recall ranking on Qwen, the filed issues |
| [`coding-agent.md`](coding-agent.md) | The coding agent | Why OpenCode 2 over Pi and Claude Code; the reference run's result, tokens and containment gap |
| [`commands.md`](commands.md) | Everything run | Every command, in order, to rebuild the setup |

The reference run's task (a paging upgrade with a hidden grader) is in [`../../bench/reference-paging/`](../../bench/reference-paging/README.md).

**Versions measured:** Lean 4.35.0, Microsandbox (`msb`, `microsandbox-mcp`) 0.7.13, Lambo 0.8.0, Vimanam 2.0.0, OpenCode 2.2.5, vultr-cli 3.11.0, Ubuntu 24.04.5 with kernel 6.8.0. A finding may not hold on another version: re-measure before relying on it.

Placeholders: `<vm-public-ip>`, `<vm-tailnet-ip>`, `<laptop-ip>`, `<instance-id>`, `<firewall-group-id>`, `<ssh-key-id>`. The real values are kept outside this public repository.
