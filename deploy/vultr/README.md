# Vultr preset

The production shape of the demo: a VX1 VM serving the Chaaya front end over
HTTPS, with `kalari serve` as a supervised service and a read-only evidence
API behind Caddy. The benchmark APIs run beside it in their own microVMs
(see `bench/apis/deploy.sh`).

```text
internet ── 80/443 ──▶ Caddy (kalai.nryn.dev, automatic HTTPS)
                        ├── / ── /srv/kalari/www (web/site/, static)
                        └── /api/* ── 127.0.0.1:18001 ── kalari-api (read-only)
kalari.service: kalari serve as user kalari (MCP over stdio, Lambo child)
  evidence: /var/lib/kalari/evidence/.kalari/evidence.jsonl (shared with kalari-api)
  lambo store: /var/lib/kalari/lambo.db
```

SSH stays on the tailnet only. The Vultr firewall group holds exactly two
rules: inbound TCP 80 and 443 from anywhere. There is no SSH rule.

## Fresh VX1 to a running deployment

Prerequisites on the laptop: `ssh`, `rsync`, `curl`, `secret-tool`,
`vultr-cli`, and the two keys in the keyring (`secret-tool lookup service
vultr-inference account kalari` and `service vultr-api account kalari`).
The VM is Ubuntu 24.04 with KVM (`vx1-g-2c-8g-120s`, `ewr`). SSH to it works
(`ssh kalari` below stands for the SSH target). VM creation and tailnet
setup are in `dev-diary/research/commands.md` and `dev-diary/research/vultr-vm.md`.

1. Point DNS at the VM: a `kalai.nryn.dev` A record with the VM's public IP.
   Caddy will not serve HTTPS until this resolves to the VM from the public
   internet (`dig +short kalai.nryn.dev` from the laptop).
2. Open the web ports. This step is the operator's own call; SSH stays
   tailnet-only, so no SSH rule is added:

   ```sh
   export VULTR_API_KEY="$(secret-tool lookup service vultr-api account kalari)"
   GROUP=<firewall-group-id>
   vultr-cli firewall rule create "$GROUP" --ip-type v4 --protocol tcp \
     --subnet 0.0.0.0 --size 0 --port 80 --notes "kalari demo HTTP"
   vultr-cli firewall rule create "$GROUP" --ip-type v4 --protocol tcp \
     --subnet 0.0.0.0 --size 0 --port 443 --notes "kalari demo HTTPS"
   ```

   The group takes the ID as a positional argument. If `vultr-cli` fails
   with an access-control error, the account key is IP-restricted: add the
   laptop's IP in the Vultr console and retry. Stop and report anything else
   instead of working around it.
3. Start the benchmark APIs (their own preset; each in a `--no-net` microVM
   with its port published on the VM's public IP):

   ```sh
   ssh kalari 'umask 022; cd ~/kalari-src/bench/apis && ./deploy.sh up <vm-public-ip>'
   ```

   On a fresh VM, Microsandbox for the operator user comes first
   (`dev-diary/research/commands.md`, B1: the user-space installer, umask
   022, then `msb pull` with retries until the image is cached and runs use
   `--pull never`). This preset's `install.sh` does the equivalent for the
   `kalari` user on its own.
4. Run the installer from a Kalari checkout on the laptop:

   ```sh
   ./tools/check.sh                       # the gate passes before a deploy
   deploy/vultr/install.sh --host kalari
   ```

   `install.sh` builds `kalari` and `kalari-aashaan` from the checkout's
   source on the VM (a laptop binary would not run there: its glibc is
   newer), installs Caddy from the official apt repository and allows the
   same two ports in the host firewall when it is active, downloads Lambo
   0.9.0 after checking its sha256, provisions the Lambo store, copies the
   site and the configs, sends the inference key to
   `/etc/kalari/kalari.env` over SSH stdin only, and enables and starts the
   three units. Re-running refreshes binaries, units, the site and the API
   without touching the evidence store, the Lambo store, or the benchmark
   sandboxes. The script sets `umask 022` throughout; both units carry
   `UMask=0022`, which Microsandbox's storage check requires.
5. Verify from the laptop's public path (not the tailnet):

   ```sh
   curl -sS https://kalai.nryn.dev/ | head -c 300; echo
   curl -sS https://kalai.nryn.dev/api/runs; echo
   curl -sS https://kalai.nryn.dev/api/benchmark; echo
   ```

   The first page is titled "For judges · Kalari". `/api/benchmark` answers
   `[]` until the benchmark producer writes records; the judges page shows
   its not-yet-published panel meanwhile, which is the expected state, not
   a failure. On the VM: `systemctl is-active caddy kalari kalari-api`
   (all `active`) and `journalctl -u kalari -u kalari-api -u caddy --since
   "10 minutes ago"` for the logs.

## Restart and recovery

A restart brings everything back; the benchmark sandboxes are untouched by
these units:

```sh
ssh kalari 'sudo systemctl restart caddy kalari kalari-api'
ssh kalari 'sudo systemctl is-active caddy kalari kalari-api'
```

then repeat the public `curl` checks above. If Caddy serves HTTP but not
yet HTTPS, its ACME challenge has not completed: confirm port 80 is open
from the internet and the A record resolves to the VM, then `systemctl
restart caddy` and watch `journalctl -u caddy`.

If `kalari` fails to start, the usual cause is the key file: check that
`/etc/kalari/kalari.env` exists, is `600 kalari:kalari`, and names the
variable (print only the name, never the value:
`sudo awk -F= '{print $1}' /etc/kalari/kalari.env`). `kalari serve`
refuses to start without the variables its config names.

## What lives where

| File here | Installed path | Notes |
|---|---|---|
| `Caddyfile` | `/etc/caddy/Caddyfile` | `kalai.nryn.dev` only; static root plus `/api` reverse proxy |
| `kalari-api.py` | `/opt/kalari/bin/kalari-api.py` | Loopback-only evidence API; no key, no writes |
| `kalari.service` | `/etc/systemd/system/kalari.service` | `kalari serve` as `kalari`, key from `kalari.env` |
| `kalari-api.service` | `/etc/systemd/system/kalari-api.service` | The evidence API as `kalari` |
| `kalari.json.example` | `/etc/kalari/kalari.json` | Endpoints and `api_key_env` names only; never values |
| `session.json.example` | `/etc/kalari/session.json` | Idle demo session; a live migration supplies its own |
| `lambo.toml.example` | `/etc/kalari/lambo.toml` | Store, embedder, daemon, serve session |
| `install.sh` | run from the laptop | The only writer of `/etc/kalari/kalari.env` |

Secrets: the inference key lives in the keyring on the laptop and in
`/etc/kalari/kalari.env` (0600, `kalari:kalari`) on the VM. It never
appears in a command line, a unit file, a committed file, or a microVM.

## Notes for the next task

- `/api` is served by `kalari-api.py`, a small loopback shim whose routes
  mirror `Kalari/Http.lean`, because nothing starts `Kalari.Http.serve`
  from `kalari serve` yet (see the T6.1 notes). When that wiring lands,
  point the Caddy `/api` proxy at it and retire the shim.
- The first `kalari serve` start appends one `lesson-policy` provenance
  record to the evidence store (its amended-policy fixture check). It is
  not a `lesson` or `benchmark` record, and the judges page ignores it
  while `/api/benchmark` is empty.
- Serving evidence means serving measurements: seed the store only with
  real run records. The fixture under `web/fixture/` is synthetic and must
  never be copied into `/var/lib/kalari/evidence`.
- This preset adds no Vultr cost beyond the VM itself: no resize, no
  second instance, and nothing here deletes anything.
