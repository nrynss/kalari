# The Vultr VM

## Decided

| | |
|---|---|
| Plan | **`vx1-g-2c-8g-120s`**: VX1, 2 vCPU (AMD, `svm`), 8 GB, 120 GB disk, **$0.076/h** (~$55 for 30 days) |
| Why not 4 vCPU | `vx1-g-4c-16g-240s` is $0.153/h: the deployment must stay up through judging within the credit, and 8 GB holds several 256 MB microVMs plus the Lean build. Resize later if load demands it |
| Avoid | VX1 plans without a `-120s`/`-240s` suffix have a 1 GB disk |
| Region | **`ewr`** (New Jersey). VX1 isn't offered in any Indian region (US, Europe, Tokyo, Sydney only). The judges and the on-site event are in the US; `fra` is the alternative for lower SSH latency from India |
| OS | Ubuntu 24.04 LTS x64 (image `2284`), as in Vultr's sandboxing guide. Kernel 6.8.0 (see `sandbox.md`, Kernels) |
| Network | IPv4 only |

## Access: Tailscale only

- **SSH goes over the tailnet** (`ssh <user>@kalari`). `tailscaled` is enabled at boot; the path is direct (UDP 41641), not relayed.
- **The Vultr firewall group has no rules**, so nothing is reachable from the internet and a changed home IP can't lock SSH out. Open 80 and 443 when Caddy goes in.
- A non-root sudo user (`NOPASSWD`, in the `kvm` group); root login and password logins are off (`/etc/ssh/sshd_config.d/10-kalari.conf`).
- Tailscale key expiry defaults to 180 days: disable it for the node if the VM outlives that.
- **The Vultr account API key is limited by IP (Access Control).** If the laptop's IP changes, `vultr-cli` stops working until the new IP is added in the console. Tailscale doesn't help with this one.
- The VM's public IP still matters inside: a sandbox in Microsandbox's default network mode reaches it (hairpin traffic skips the Vultr firewall). See `sandbox.md`.

## Traps hit

- `vultr-cli firewall rule create` takes the group ID as a **positional argument**; the `--id` in its own examples is rejected.
- `tailscale up` blocks until login: run it detached and read the login URL from its log.
- Ubuntu's default umask (`0002`) breaks Microsandbox's storage check: see `sandbox.md`.

## Day to day

```bash
vultr-cli instance list
vultr-cli instance get <instance-id>
vultr-cli account info                 # remaining credit
ssh <user>@kalari 'msb list'           # leftover sandboxes
```

Teardown (billing stops): `vultr-cli instance delete <instance-id>`, then the firewall group and the SSH key. The full setup, in order, is in `commands.md`.
