# Commands

Every command run in the day-one checks, in order, so the setup can be rebuilt. Private values are placeholders (see `README.md`). Keys never appear: they live in the keyring and are read into a variable per command. The supervisor's source is `Aashaan/Main.lean`, its cases `tests/aashaan-cases.sh` and `tests/live/microvm-cases.sh`; the B5 task is `bench/reference-paging/`.

## 0. Setup

1. **Create an inference API key** in the Vultr console → Serverless Inference. It covers model calls only, not the Vultr account.
2. **Keep it out of shell history and out of files you commit:**

   ```bash
   read -rs VULTR_INFERENCE_API_KEY && export VULTR_INFERENCE_API_KEY
   ```

   Every command below reads `$VULTR_INFERENCE_API_KEY`. Lambo and OpenCode read the same variable by name.
3. Tools on the laptop: `curl`, `jq`.

```bash
V=https://api.vultrinference.com/v1
AUTH="Authorization: Bearer $VULTR_INFERENCE_API_KEY"
```

---

## Part A: Vultr Inference, from the laptop (well under $1)

### A1. Model IDs

```bash
curl -s $V/models -H "$AUTH" | jq -r '.data[].id' | sort
curl -s $V/embeddings/models -H "$AUTH" | jq .
```

**Record:** exact IDs for DeepSeek V4.1 Flash (docs show `deepseek-v4.1-flash-1017`), `clef`, and BGE M3. Also each model's context window if listed (`curl -s $V/models/<id> -H "$AUTH" | jq .`).

### A2. DeepSeek V4.1 Flash drives tool calls

OpenCode depends on tool calling. Test a forced call and a model-chosen call, at two reasoning efforts.

```bash
tool_req() {  # $1 = reasoning effort, $2 = tool_choice JSON
cat <<EOF
{
  "model": "deepseek-v4.1-flash-1017",
  "reasoning_effort": "$1",
  "messages": [
    {"role": "system", "content": "You are a coding agent. Use tools to act."},
    {"role": "user", "content": "The list endpoint now pages its results with next_page_token. Run the import script in the sandbox to check every record is imported."}
  ],
  "tools": [{
    "type": "function",
    "function": {
      "name": "run_in_sandbox",
      "description": "Run a command in an isolated sandbox and return its verdict and output.",
      "parameters": {
        "type": "object",
        "properties": {
          "command": {"type": "string"},
          "timeout_ms": {"type": "integer"}
        },
        "required": ["command"]
      }
    }
  }],
  "tool_choice": $2
}
EOF
}

for effort in low medium; do
  echo "== auto, $effort"
  tool_req $effort '"auto"' | curl -s $V/chat/completions -H "$AUTH" -H 'Content-Type: application/json' -d @- \
    | jq '{finish: .choices[0].finish_reason, calls: .choices[0].message.tool_calls, usage}'
done
echo "== forced, low"
tool_req low '{"type":"function","function":{"name":"run_in_sandbox"}}' \
  | curl -s $V/chat/completions -H "$AUTH" -H 'Content-Type: application/json' -d @- \
  | jq '{finish: .choices[0].finish_reason, calls: .choices[0].message.tool_calls, usage}'
```

**Look for:** `finish_reason: "tool_calls"`, a `run_in_sandbox` call whose `arguments` parse as JSON with a sensible `command`. In `usage`: `completion_tokens_details.reasoning_tokens` at `low` vs `medium` (reasoning is billed as output), and `prompt_tokens_details.cached_tokens` (send the same request twice: does the second show cached tokens?).

**Fail:** no tool call under `auto`, or malformed arguments → fallback model Qwen 3.8 27B; repeat A2 with its ID.

### A3. Clef answers in System One format

```bash
curl -s $V/systemone -H "$AUTH" -H 'Content-Type: application/json' -d @- <<'EOF' | jq .
{
  "model": "clef",
  "state": {
    "change": "GET /items now pages its results: response has items[] and next_page_token; the old endpoint returned all items at once.",
    "run": {
      "verdict": "exited",
      "exit_code": 0,
      "check": "every record imported exactly once",
      "check_result": "failed: imported 100 of 2,431 records",
      "stderr": ""
    },
    "code_hit": "resp = client.get('/items'); for item in resp.json()['items']: save(item)"
  },
  "questions": {
    "failure_cause": {
      "type": "choice",
      "instructions": "Why did this run fail?",
      "criteria": {
        "api_change": "the consumer does not handle the API change",
        "test_setup": "our test environment or fixtures are wrong",
        "flaky": "a transient or timing failure that would pass on retry",
        "unrelated_bug": "a bug in the consumer unrelated to the API change"
      }
    },
    "calls_changed_operation": {
      "type": "noul",
      "instructions": "Does the code_hit call the operation described in change?"
    },
    "lesson_applies": {
      "type": "noul",
      "instructions": "Does this lesson apply to the change: 'When a list endpoint starts paging, follow next_page_token until it is absent; every record must be imported exactly once.'"
    }
  }
}
EOF
```

**Look for:** `answers.failure_cause` with `choice: "api_change"`, per-option `probabilities` and a `confidence`; `answers.calls_changed_operation` and `answers.lesson_applies` as a yes-probability (`noul`, no confidence). `usage.input_tokens` billed, `output_tokens` 0. **Record the exact answer JSON shape**: the docs don't show it.

### A4. BGE M3 embeddings

```bash
BGE=<BGE M3 id from A1>
curl -s $V/embeddings -H "$AUTH" -H 'Content-Type: application/json' -d @- <<EOF | jq '{model, n: (.data|length), dims: (.data[0].embedding|length), usage}'
{"model": "$BGE", "input": [
  "When a list endpoint starts paging, follow the page token until it is absent.",
  "Every record must be imported exactly once.",
  "pagination_changed"
]}
EOF
```

**Look for:** `dims: 1024` (Lambo's `dim`). **Fail:** another width, or the model missing → Lambo falls back to `llama-server` with a BGE-M3 GGUF on the VM.

### A5. Spend

```bash
curl -s $V/usage -H "$AUTH" | jq .
```

**Look for:** spend matching A2–A4 token counts at list prices, and whether cached input from A2's repeat was charged less.

---

## Part B: on a Vultr VM

### B0. Create the VM

- **Vultr VX1 Cloud Compute, Ubuntu 24.04** (the instance type Vultr's sandboxing guide uses). Start with 4 vCPU / 8 GB if offered; check the hourly price in the console. **Destroy it when idle** (billed hourly).
- Add your SSH key at creation. Create a non-root sudo user (the guide assumes one). Firewall: SSH only for now (Vultr firewall group, or `ufw allow OpenSSH && ufw enable`).

### B1. KVM for Microsandbox

```bash
sudo usermod -aG kvm $USER    # then log out and back in (newgrp would stop a pasted block here)
ls -l /dev/kvm
umask 022                     # Ubuntu's 0002 makes msb's storage group-writable, which msb refuses
curl -fsSL https://install.microsandbox.dev | sh
chmod -R go-w ~/.microsandbox
export PATH="$HOME/.local/bin:$PATH"   # also put this and `umask 022` at the top of ~/.bashrc
msb --version
msb doctor
msb run debian -- echo "hello from microsandbox"
```

**Look for:** `msb doctor` passes the virtualization and `/dev/kvm` checks (the guide's sample shows `svm`); the debian microVM prints its line. A reflink warning is informational. **Fail:** no usable `/dev/kvm` on VX1 → Docker backend for the sandbox; record it.

### B2. Can Microsandbox restrict outbound network?

The guide says sandboxes have outbound internet by default and doesn't cover restricting it.

```bash
msb --help
msb create --help        # look for network / egress / allowlist options
msb create --name nettest --cpus 1 --memory 256M debian
msb exec nettest -- bash -c "timeout 5 bash -c '</dev/tcp/example.com/80' && echo REACHABLE || echo BLOCKED"
```

**Record:** which flag or config restricts egress (none / all / allowlist), and that `BLOCKED` results when applied. **If none exists:** restrict at the host with nftables on the microVMs' interface or address range, allowing only the test APIs; find the range with `msb exec nettest -- hostname -I`. Clean up: `msb stop nettest && msb remove nettest`.

### B3. kalari-aashaan inside a microVM

On the VM, install Lean and build the supervisor from the appendix:

```bash
curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain none
source ~/.elan/env
mkdir -p ~/aashaan && cd ~/aashaan
# create lakefile.toml, lean-toolchain and Main.lean from the appendix
lake build && cp .lake/build/bin/kalari-aashaan . && strip kalari-aashaan
ls -l kalari-aashaan          # expect ~3.3 MB
```

Run it inside a microVM and time the start-up:

```bash
time msb create --name aashaan --cpus 1 --memory 256M --no-net debian
msb copy ./kalari-aashaan aashaan:/usr/local/bin/kalari-aashaan
msb copy ./cases.sh aashaan:/root/cases.sh           # appendix
msb exec aashaan -- chmod +x /usr/local/bin/kalari-aashaan
# Required: Lean can't start threads under the guest's default heuristic overcommit (no swap)
msb exec aashaan -- sh -c 'echo 1 > /proc/sys/vm/overcommit_memory'
time msb exec aashaan -- bash /root/cases.sh
msb stop aashaan && msb remove aashaan
```

**Without the overcommit line, every case aborts** with `lean::exception: failed to create thread: Resource temporarily unavailable` (exit 134), even in a 1 GB microVM. `ulimit -s`, `LEAN_NUM_THREADS=1` and more memory don't help; `vm.overcommit_memory=1` does.

**Look for:** the eight cases match the expected verdicts in the appendix, inside the microVM; `cgroup_memory_limit` reflects the microVM's memory; **start-up time** of `msb create` plus first `exec`. That is the per-run sandbox cost. Then confirm teardown: after the escape case, `msb stop` + `msb remove` leaves nothing running on the host (`ps aux | grep 'sleep 104'` on the host shows nothing; it never ran there).

### B4. Lambo on the VM

```bash
curl -fsSL https://github.com/nrynss/lambo/releases/latest/download/install.sh | sh
lambo --version          # 0.9.0 (B4 first ran on 0.8.0)
```

`~/kalari-lambo/lambo.toml`:

```toml
promotion_policy = "Solo"          # top-level: must come before the first [table]

[store]
kind = "sqlite"
path = "./kalari.db"

[embedder]
kind = "openai"                    # same adapter as bge_m3; appends /v1/embeddings to url
url = "https://api.vultrinference.com"
model = "qwen3-embedding-4b"       # BGE M3 isn't served on Vultr (A4)
dim = 2560                         # Qwen's full width; 0.9.0 also takes `dimensions = 1024` with `dim = 1024`
api_key_env = "VULTR_INFERENCE_API_KEY"

[daemon]
gc_interval = 1                    # TEST ONLY: sweep after every mutation
```

**Provision the store first:** `lambo provision --config ~/kalari-lambo/lambo.toml`. Without it, `lambo serve` refuses a brand-new store: since 0.9.0 with "no schema yet … Run `lambo provision`", on 0.8.0 with a misleading "provisioned by an older lambo" ([lambo#222](https://github.com/nrynss/lambo/issues/222)).

Connect an MCP client to `lambo serve` over stdio (the local Claude Code session works: add Lambo as an MCP server; see [Lambo's MCP docs](https://nrynss.github.io/lambo/mcp/)), then:

1. **Embeddings through Vultr (Qwen3 Embedding 4B, not Lambo's calibrated BGE M3):** check recall still ranks the lesson first for a paging query worded differently. `lambo_derive` one concept; startup and the derive succeed with no embedder error. The embedder canary pins the contract on first writer attach.
2. **Change kind as a resource, lesson, evidence:**
   - `lambo_derive` `{content: "pagination_changed", concept_type: "resource"}`
   - `lambo_derive` `{content: "When a list endpoint starts paging, follow next_page_token until absent; every record imported exactly once. check: chk-paging-001", concept_type: "constraint", depends_on: ["pagination_changed"]}`
   - `lambo_derive` `{content: "run r-001: naive migration imported 100 of 2,431 records; fixed version passed", concept_type: "observation", depends_on: [<lesson id>]}`
3. **GC survival:** make a few more unrelated derives so sweeps run (`gc_interval = 1`), then `lambo_stats` (the `gc` line shows sweeps) and `lambo_inspect` on `pagination_changed` and the lesson. **Look for:** all three still present; `pagination_changed` lists the lesson among its `dependents`.
4. **Solo promotion:** cite the lesson from a second, independent interaction (a second "upgrade": another observation with `depends_on` the lesson), then `lambo_inspect` the lesson. **Look for:** the `canonization (Solo): …` line and its gates; record whether it is promoted, or which gate fails and by how much.

**Then set `gc_interval` back** (remove the line) before any real use.

### B5. OpenCode reference run (Vultr's guide, on OpenCode 2)

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource.sh && sudo -E bash /tmp/nodesource.sh
sudo apt-get install -y nodejs                # npx, for microsandbox-mcp
# OpenCode 2.2.5 from the GitHub release (npm and opencode.ai/install give only 1.x)
curl -fsSL -o oc.tar.gz https://github.com/anomalyco/opencode/releases/download/v2.2.5/opencode-linux-x64.tar.gz
echo "09f44302c10fd036912f59c81fd1aef5df45dd06f649197f9dfc9bbe2a79614e  oc.tar.gz" | sha256sum -c -
tar -xzf oc.tar.gz && install -m 755 opencode ~/.local/bin/opencode
```

Vultr's guide config, **reshaped for 2.x** (`providers`, `mcp.servers`) and **with the key named, not written** (`env`). The task repo, its `opencode.jsonc`, the prompt and the hidden grader are in the appendix ("B5 task"). The permissions deny the host shell, web and paths outside the project, so all code runs through `microsandbox-mcp`.

Run it with the key piped over SSH (never in a file or a command line on the VM), and `/v1/usage` read before and after on the laptop:

```bash
printf '%s\n' "$VULTR_INFERENCE_API_KEY" | ssh <user>@kalari 'read -r VULTR_INFERENCE_API_KEY; export VULTR_INFERENCE_API_KEY
  cd ~/b5/repo && timeout 840 opencode run --format json --auto --title b5-reference "$(cat ~/b5/prompt.txt)" > ~/b5/events.jsonl'
ssh <user>@kalari '~/b5/grader/grade.sh'        # hidden grader: fresh --no-net microVM, 2,431 records exactly once
```

Send the prompt as a file: arguments after an `ssh` command are joined into the remote command string, so a `;` in the prompt runs as a shell command on the VM.

**Record:** it calls the sandbox tools; the run completes; the grader verdict; total tokens and cost for the task. That number replaces the ~2M-tokens-per-run estimate in the brief.

---

## Every command, in order

Everything run during the day-one checks, in order, so the setup can be repeated or rebuilt. Keys never appear in files, commands or output: they live in the desktop keyring (secret-tool) and are read into an environment variable per command.

### Keys (laptop)

```bash
# Serverless Inference key (Vultr console → Serverless Inference)
secret-tool store --label='Vultr Inference API key (Kalari)' service vultr-inference account kalari
# Account API key (Account → API → Enable API; Access Control lists allowed IPs)
secret-tool store --label='Vultr account API key (Kalari)' service vultr-api account kalari

# Check a key is stored without printing it (36 bytes each)
secret-tool lookup service vultr-inference account kalari | wc -c

# Per command or shell
export VULTR_INFERENCE_API_KEY="$(secret-tool lookup service vultr-inference account kalari)"
export VULTR_API_KEY="$(secret-tool lookup service vultr-api account kalari)"   # read by vultr-cli
```

The account key is limited to the IPs in Access Control. **If the laptop's IP changes, `vultr-cli` stops working** until the new IP is added there; Tailscale doesn't help with this one.

### Part A extras (laptop)

Model IDs with context lengths, and the embeddings list:

```bash
V=https://api.vultrinference.com/v1; AUTH="Authorization: Bearer $VULTR_INFERENCE_API_KEY"
curl -s $V/models -H "$AUTH" | jq -r '.data[] | [.id, (.context_length // "")] | @tsv' | sort
curl -s $V/embeddings/models -H "$AUTH" | jq -c '.data[] | {id, context_length, pricing}'
```

Qwen at 1024 dims (Qwen truncates when asked; Lambo asks from 0.9.0, `[embedder] dimensions`):

```bash
curl -s $V/embeddings -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-embedding-4b","dimensions":1024,"input":["pagination_changed"]}' \
  | jq '{dims: (.data[0].embedding|length)}'
```

Raw Qwen cosine, to tell embedder ranking from Lambo's fusion (the lambo#221 evidence):

```python
# python3 -I cosine.py  (VULTR_INFERENCE_API_KEY set)
import json, os, urllib.request, math
Q = "the orders API now returns results one page at a time with a cursor; how should the importer handle it?"
docs = ["When a list endpoint starts paging, follow next_page_token until absent; every record imported exactly once. check: chk-paging-001",
        "The demo API v1 returns all items in one response.", "The web app front end is built with Chaaya.",
        "run r-001: naive migration imported 100 of 2,431 records; fixed version passed", "pagination_changed",
        "Caddy terminates TLS on the VM."]
req = urllib.request.Request("https://api.vultrinference.com/v1/embeddings",
    data=json.dumps({"model": "qwen3-embedding-4b", "input": [Q] + docs}).encode(),
    headers={"Authorization": "Bearer " + os.environ["VULTR_INFERENCE_API_KEY"], "Content-Type": "application/json"})
v = [d["embedding"] for d in json.load(urllib.request.urlopen(req))["data"]]
cos = lambda a, b: sum(x*y for x, y in zip(a, b)) / math.sqrt(sum(x*x for x in a) * sum(y*y for y in b))
for s, d in sorted(((cos(v[0], e), d) for e, d in zip(v[1:], docs)), reverse=True):
    print(f"{s:.3f}  {d[:70]}")
```

### B4: Lambo on the laptop

Lambo 0.8.0 was already installed (`~/.local/bin/lambo`). Throwaway store in a scratch directory:

```bash
mkdir -p ~/kalari-lambo && cd ~/kalari-lambo
# lambo.toml as in B4 (qwen3-embedding-4b, dim = 2560, Solo, gc_interval = 1)
lambo provision --config ./lambo.toml          # required on a new store (lambo#222)
```

Driver: a minimal MCP stdio client. It starts `lambo serve`, initializes, then runs a JSON list of tool calls (`{"tool", "args", "label"}`, or `{"sleep": seconds}` to let background writes apply).

```python
# python3 -I mcp_b4.py <workdir> <config> <steps.json>
import json, subprocess, sys, time

workdir, config, steps_path = sys.argv[1:4]
steps = json.load(open(steps_path))
p = subprocess.Popen(
    ["lambo", "serve", "--config", config, "--session", "kalari-b4", "--agent", "kalari"],
    cwd=workdir, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(f"{workdir}/serve.err", "a"),
    text=True, bufsize=1,
)
nid = 0

def call(method, params=None, notify=False):
    global nid
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        msg["params"] = params
    if not notify:
        nid += 1
        msg["id"] = nid
    p.stdin.write(json.dumps(msg) + "\n"); p.stdin.flush()
    if notify:
        return None
    while True:
        line = p.stdout.readline()
        if not line:
            raise SystemExit("lambo serve exited; see serve.err")
        r = json.loads(line)
        if r.get("id") == nid:
            return r

call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "b4", "version": "0"}})
call("notifications/initialized", notify=True)
for s in steps:
    if s.get("sleep"):
        time.sleep(s["sleep"]); continue
    args = dict(s["args"], agent_id="kalari")
    r = call("tools/call", {"name": s["tool"], "arguments": args})
    res = r.get("result") or r.get("error")
    out = res.get("structuredContent") if isinstance(res, dict) and res.get("structuredContent") else res
    if isinstance(out, dict) and "content" in out:
        out = "\n".join(c.get("text", "") for c in out["content"])
    print(f"===== {s['tool']} {s.get('label', '')}")
    print(out if isinstance(out, str) else json.dumps(out, indent=1)[:4000])
p.stdin.close(); p.wait(timeout=60)
```

Sequence run (four `steps.json` files, one `serve` process each):

1. `lambo_derive` `pagination_changed` (`resource`); the lesson (`constraint`, `depends_on: ["pagination_changed"]`); evidence r-001 (`observation`, `depends_on` the lesson's exact text); five unrelated `observation` fillers. Sleep 3 s between writes, then `lambo_stats`, `lambo_inspect` on both, and `lambo_recall` with a reworded paging query.
2. Evidence r-002 and r-003, each `depends_on: ["0bd9ef07"]` (the lesson's short id), with `lambo_inspect` after each.
3. After 60 s: `lambo_inspect` again (now eligible).
4. A `serve` kept up for 75 s so a canonization cycle runs, then `lambo_stats`, `lambo_inspect` (Candidate), `lambo_recall`.

**The 0.9.0 re-run (T0.4)** used `testdata/lambo/driver.py`: the same client, plus a transcript of every JSON-RPC line and a `"receipt": true` step that passes the last ack's receipt to `lambo_stats`. The steps are in `testdata/lambo/steps/`: the whole sequence in one `serve` (`b4-full.json`, with the promotion waits), a receipt read, a contradiction on a restarted `serve`, and recall at 1024 and with `calibration = "off"`. The 0.9.0 binary was downloaded beside the installed one and checked against its `.sha256`:

```bash
gh release download v0.9.0 -R nrynss/lambo -p 'lambo-0.9.0-linux-x86_64*'
sha256sum -c lambo-0.9.0-linux-x86_64.sha256
```

### B0: the VM (laptop)

```bash
sudo pacman -S vultr-cli                         # v3.11.0, in CachyOS/Arch extra
vultr-cli account info                           # balance -205.00 = $205 credit

A="Authorization: Bearer $VULTR_API_KEY"
# VX1 plans with location counts (the -120s/-240s ones have real disks; the others 1 GB)
curl -s "https://api.vultr.com/v2/plans?per_page=500" -H "$A" \
  | jq -r '.plans[] | select(.id|test("^vx1")) | [.id,.vcpu_count,.ram,.disk,.monthly_cost,.hourly_cost,(.locations|length)] | @tsv'
curl -s "https://api.vultr.com/v2/plans?per_page=500" -H "$A" \
  | jq -r '.plans[] | select(.id=="vx1-g-2c-8g-120s") | .locations | join(" ")'   # no Indian region
curl -s "https://api.vultr.com/v2/os?per_page=500" -H "$A" | jq -r '.os[] | select(.family=="ubuntu") | "\(.id) \(.name)"'
curl -s "https://api.vultr.com/v2/regions" -H "$A" | jq -r '.regions[] | "\(.id) \(.city)"'

vultr-cli ssh-key create --name kalari --key "$(cat ~/.ssh/id_ed25519.pub)"
vultr-cli firewall group create --description kalari
# Group ID is a positional argument (the --id in vultr-cli's own examples is wrong)
vultr-cli firewall rule create <group-id> --protocol tcp --port 22 --ip-type v4 \
  --subnet "$(curl -s -4 https://api.ipify.org)" --size 32 --notes "ssh from laptop"   # later removed

vultr-cli instance create --region ewr --plan vx1-g-2c-8g-120s --os 2284 --label kalari --host kalari \
  --tags kalari --ssh-keys <ssh-key-id> --firewall-group <group-id> --ipv6=false
vultr-cli instance get <instance-id> -o json | jq '.instance | {status, server_status, main_ip}'   # poll until "ok"
```

First login as root, then a sudo user and SSH hardening:

```bash
ssh root@<vm-public-ip> '
adduser --disabled-password --gecos "" <user>
usermod -aG sudo,kvm <user>
echo "<user> ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-kalari-user && chmod 440 /etc/sudoers.d/90-kalari-user && visudo -cf /etc/sudoers.d/90-kalari-user
install -d -m 700 -o <user> -g <user> ~/.ssh
install -m 600 -o <user> -g <user> /root/.ssh/authorized_keys ~/.ssh/authorized_keys'

ssh <user>@<vm-public-ip> 'printf "PermitRootLogin no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n" \
  | sudo tee /etc/ssh/sshd_config.d/10-kalari.conf && sudo sshd -t && sudo systemctl reload ssh'
```

### Tailscale-only SSH

```bash
ssh <user>@<vm-public-ip> 'curl -fsSL https://tailscale.com/install.sh | sudo sh'    # 1.104.5
# tailscale up blocks until login, so run it detached and read the URL from its log
ssh <user>@<vm-public-ip> 'sudo sh -c "nohup timeout 900 tailscale up --hostname=kalari >/tmp/ts-up.log 2>&1 &"
  sleep 5; grep -o "https://login.tailscale.com/[^ ]*" /tmp/ts-up.log'
# open the URL, approve the device in the Tailscale account, then:
tailscale status | grep kalari                    # <vm-tailnet-ip>
ssh <user>@kalari 'echo ok'
vultr-cli firewall rule delete <group-id> 1       # close public SSH; the group now has no rules
tailscale ping -c 3 kalari                        # direct via <public-ip>:41641
```

### B1: Microsandbox (on the VM, as <user>)

```bash
curl -fsSL https://install.microsandbox.dev -o /tmp/msb-install.sh   # read it first: user-space, no sudo
sh /tmp/msb-install.sh                                               # msb 0.7.13 into ~/.microsandbox
chmod -R go-w ~/.microsandbox                                        # else: "permits path substitution"
sed -i '1i umask 022\nexport PATH="$HOME/.local/bin:$PATH"\n' ~/.bashrc
printf '\numask 022\n' >> ~/.profile
msb doctor
msb run debian -- echo "hello from microsandbox"
msb run debian -- sh -c 'uname -r; nproc'                           # 6.12.113, 1
```

Kernel checks behind the "stay on 6.8" decision:

```bash
apt-cache policy linux-generic-hwe-24.04          # candidate 7.0.0-42 (not installed)
# laptop: which kernel each libkrunfw release bundles
for t in v5.6.2 v5.4.0 v5.0.0 v4.10.0; do
  gh api "repos/libkrun/libkrunfw/contents/Makefile?ref=$t" -q .content | base64 -d | grep -m1 '^KERNEL_VERSION'
done
```

### B2: egress probe

Run from the `python` image; it reports a response only when data comes back (a bare connect "succeeds" even when policy denies).

```python
#!/usr/bin/env python3
# p.py host,port,path,tls ...   e.g. 10.0.0.1,80,/,0 api.vultrinference.com,443,/v1/health,1
import socket, ssl, sys
def get(host, port, path, tls):
    try:
        s = socket.create_connection((host, port), timeout=6)
        if tls: s = ssl.create_default_context().wrap_socket(s, server_hostname=host)
        s.sendall(("GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n" % (path, host)).encode())
        d = b""
        while len(d) < 600:
            c = s.recv(600)
            if not c: break
            d += c
        return d.decode(errors="replace").replace("\r\n", " | ")[:260]
    except Exception as e: return "blocked (%s: %s)" % (type(e).__name__, str(e)[:60])
for a in sys.argv[1:]:
    h, p, path, tls = a.split(",")
    print("  %s:%s%s -> %s" % (h, p, path, get(h, int(p), path, tls == "1")))
```

```bash
# --script-raw keeps the file as is (--script decodes \r\n escapes and breaks the Python)
run() { msb run "$@" --script-raw p="$(cat p.py)" python -- /.msb/scripts/p \
  example.com,443,/,1 api.vultrinference.com,443,/v1/health,1 169.254.169.254,80,/v1.json,0 10.0.0.1,80,/,0; }
run                                                                         # default: public open, VM public IP open
run --no-net                                                                # nothing out
run --no-net --net-rule allow@dns --net-rule allow@api.vultrinference.com:tcp:443   # domain rule: SSLEOFError
run --no-net --net-rule allow@155.138.237.57/32:tcp:443                     # IP rule: works
curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://169.254.169.254/v1.json # host: 200; guests get msb's 403
```

To SSH-banner-test the VM's own public IP from a guest, add a TCP read of `<vm-public-ip>:22`.

### B3: supervisor in a microVM

```bash
# laptop: pull the four files out of the appendix above, copy them over
python3 -I - the day-one runbook ./aashaan <<'PY'
import re, sys, pathlib
src, out = sys.argv[1], pathlib.Path(sys.argv[2]); out.mkdir(exist_ok=True)
text = open(src).read().split("## Appendix: kalari-aashaan probe", 1)[1]
for name in ["lean-toolchain", "lakefile.toml", "Main.lean", "cases.sh"]:
    m = re.search(r"`%s`[^\n]*\n\n```[a-z]*\n(.*?)```" % re.escape(name), text, re.S)
    (out / name).write_text(m.group(1))
PY
ssh <user>@kalari 'mkdir -p ~/aashaan' && scp ./aashaan/* <user>@kalari:aashaan/

# VM
curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain none
. ~/.elan/env && cd ~/aashaan && lake build && cp .lake/build/bin/kalari-aashaan . && strip kalari-aashaan
# then the B3 block above (create, copy, chmod, overcommit 1, cases, stop, remove)
```

Diagnosing the thread failure (in the guest):

```bash
msb exec aashaan -- bash -c 'ulimit -u -s; grep -E "CommitLimit|MemTotal" /proc/meminfo; cat /proc/sys/vm/overcommit_memory'
msb exec aashaan -- bash -c 'LEAN_NUM_THREADS=1 kalari-aashaan 2000 4096 sh -c "echo hi"'   # still fails
msb exec aashaan -- bash -c 'echo 1 > /proc/sys/vm/overcommit_memory; kalari-aashaan 2000 4096 sh -c "echo hi"'   # works
# after the cases: the escaped job is alive in the guest, gone from the host after teardown
msb exec aashaan -- sh -c 'for p in /proc/[0-9]*; do tr "\0" " " < $p/cmdline; echo; done | grep "sleep 10"'
msb stop aashaan && msb remove aashaan && pgrep -fc 'sleep 10[1-4]'           # 0 on the host
```

### B5: OpenCode 2 reference run

Install as in B5 above. **Task repo** (`~/b5/repo`, committed as "v1 consumer" so `git diff` shows the agent's change):

`API_CHANGES.md`:

```markdown
# Items API v2

- `GET /items` now returns at most 100 items per response: `{"items": [...], "next_page_token": "..."}`.
- Pass `?page_token=<next_page_token>` to get the next page. The last page has no `next_page_token`.
- v1 returned every item in one response. v1 is retired; `api_v2.py` is the server.
```

`api_v2.py` (2,431 items, 100 per page):

```python
"""Items API v2: GET /items pages its results (100 per page) with next_page_token."""
import base64, json
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

ITEMS = [{"id": f"item-{i:05d}", "value": i * 7 % 1000} for i in range(2431)]
PAGE = 100

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        if url.path != "/items":
            self.send_error(404); return
        token = parse_qs(url.query).get("page_token", [None])[0]
        start = int(base64.urlsafe_b64decode(token).decode()) if token else 0
        body = {"items": ITEMS[start:start + PAGE]}
        if start + PAGE < len(ITEMS):
            body["next_page_token"] = base64.urlsafe_b64encode(str(start + PAGE).encode()).decode()
        data = json.dumps(body).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass

if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 8080), Handler).serve_forever()
```

`import_items.py`, the v1 consumer the agent must fix:

```python
"""Import every item from the items API into items.jsonl. Written for API v1."""
import json, sys, urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080"

def main():
    with urllib.request.urlopen(f"{BASE}/items") as resp:
        items = json.load(resp)["items"]
    with open("items.jsonl", "w") as out:
        for item in items:
            out.write(json.dumps(item) + "\n")
    print(f"imported {len(items)} items")

if __name__ == "__main__":
    main()
```

`opencode.jsonc` (OpenCode 2 shape):

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "providers": {
    "vultr": {
      "name": "Vultr Serverless Inference",
      "env": ["VULTR_INFERENCE_API_KEY"],
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": { "baseURL": "https://api.vultrinference.com/v1" },
      "body": { "reasoning_effort": "low" },
      "models": { "deepseek-v4.1-flash-1017": { "name": "DeepSeek V4.1 Flash" } }
    }
  },
  "model": "vultr/deepseek-v4.1-flash-1017",
  "mcp": {
    "servers": {
      "microsandbox": { "type": "local", "command": ["npx", "-y", "microsandbox-mcp@0.7.13"] }
    }
  },
  // All code runs in microVMs: no host shell, no web, nothing outside the project.
  "permissions": [
    { "action": "shell", "resource": "*", "effect": "deny" },
    { "action": "webfetch", "resource": "*", "effect": "deny" },
    { "action": "websearch", "resource": "*", "effect": "deny" },
    { "action": "external_directory", "resource": "*", "effect": "deny" },
    { "action": "microsandbox_runtime_install", "resource": "*", "effect": "deny" }
  ]
}
```

`~/b5/prompt.txt`:

```text
The items API was upgraded to v2; see API_CHANGES.md. Update import_items.py so it imports every item from the v2 API into items.jsonl. You cannot run commands on this machine: use the microsandbox tools to run code. Create a sandbox from the python image, write api_v2.py and import_items.py into it, start the API server, run the importer, and confirm how many items were imported. Remove the sandbox when you are done. Finish by reporting the count.
```

Hidden grader, `~/b5/grader/grade.sh` (the server's output must be redirected, or `msb exec` waits on its held pipe forever):

```bash
#!/bin/sh
# Hidden grader: fresh microVM, no network, the agent's import_items.py against api_v2.py.
set -e
cd "$(dirname "$0")/../repo"
name="grade-$$"
msb create --name "$name" --cpus 1 --memory 512M --no-net python >/dev/null 2>&1
trap 'msb stop "$name" >/dev/null 2>&1; msb remove "$name" >/dev/null 2>&1' EXIT
msb exec "$name" -- mkdir -p /w
msb copy -q api_v2.py "$name":/w/api_v2.py
msb copy -q import_items.py "$name":/w/import_items.py
msb exec "$name" -- sh -c 'cd /w && (python3 api_v2.py >/dev/null 2>&1 &) && sleep 1 && timeout 60 python3 import_items.py >/w/out.txt 2>&1; echo "exit $?" >> /w/out.txt'
msb exec "$name" -- python3 -c '
import json
ids = [json.loads(l)["id"] for l in open("/w/items.jsonl")]
u = set(ids)
print("importer:", open("/w/out.txt").read().strip().replace("\n", " | "))
print("records:", len(ids), "unique:", len(u), "expected: 2431")
print("GRADE:", "PASS" if len(ids) == 2431 and len(u) == 2431 else "FAIL")'
```

Run, measure, inspect:

```bash
# laptop: token counts before and after (account-wide, so run nothing else meanwhile)
curl -s $V/usage -H "$AUTH" | jq -c '.usage.current_month.chat_usage' > usage-before.json
printf '%s\n' "$VULTR_INFERENCE_API_KEY" | ssh <user>@kalari 'read -r VULTR_INFERENCE_API_KEY; export VULTR_INFERENCE_API_KEY
  cd ~/b5/repo && timeout 840 opencode run --format json --auto --title b5-reference "$(cat ~/b5/prompt.txt)" > ~/b5/events.jsonl'
curl -s $V/usage -H "$AUTH" | jq -c '.usage.current_month.chat_usage' > usage-after.json
jq -n --slurpfile b usage-before.json --slurpfile a usage-after.json \
  '[$a[0][] as $x | ($b[0][] | select(.model==$x.model)) as $y | {model: $x.model, input: ($x.input_tokens - $y.input_tokens), output: ($x.output_tokens - $y.output_tokens)}]'

# VM: what the agent did
cd ~/b5 && jq -r .type events.jsonl | sort | uniq -c
jq -r 'select(.type=="tool_use") | .part.tool + "  " + ((.part.state.input|tostring)[:110])' events.jsonl
jq -s '[.[]|select(.type=="step_finish")|.part.tokens] | {steps: length, input: (map(.input)|add), output: (map(.output)|add), cache_read: (map(.cache.read)|add)}' events.jsonl
jq -r 'select(.type=="text") | .part.text' events.jsonl
cd repo && git diff && ~/b5/grader/grade.sh
git checkout import_items.py                  # reset for the next run
```

The `microsandbox-mcp` tool list (70 tools, ~67 KB of schemas) came from a short stdio client: `initialize`, `notifications/initialized`, `tools/list` against `npx -y microsandbox-mcp`, the same pattern as the B4 driver.

### Day-to-day operations

```bash
ssh <user>@kalari                                    # Tailscale only
vultr-cli instance list
vultr-cli instance get <instance-id>
ssh <user>@kalari 'msb list'                         # leftover sandboxes
ssh <user>@kalari 'msb stop <name> && msb remove <name>'

# When Caddy goes in: open the web ports to everyone
vultr-cli firewall rule create <firewall-group-id> --protocol tcp --port 80 --ip-type v4 --subnet 0.0.0.0 --size 0
vultr-cli firewall rule create <firewall-group-id> --protocol tcp --port 443 --ip-type v4 --subnet 0.0.0.0 --size 0

# Spend: Vultr credit, and inference token counts
vultr-cli account info
curl -s https://api.vultrinference.com/v1/usage -H "Authorization: Bearer $VULTR_INFERENCE_API_KEY" | jq .

# Destroy everything when done (billing stops)
vultr-cli instance delete <instance-id>
vultr-cli firewall group delete <firewall-group-id>
vultr-cli ssh-key delete <ssh-key-id>
```

### The network route for the benchmark (proved)

```bash
# On the VM. A test API: GET anything → {"service": NAME, "path": PATH}
# api.py <bind-addr> <port> <name>   (python3 http.server; see bench/README.md)

# Route A: a host process bound to the public IP only (fallback)
timeout 600 python3 api.py <vm-public-ip> 18080 route-A-host >/dev/null 2>&1 &

# Route B: its own microVM. --no-net would deny ingress too, so deny egress only.
msb create --name route-b --cpus 1 --memory 256M --net-default-egress deny \
  -p <vm-public-ip>:18081:8080 python
msb copy -q api.py route-b:/srv-api.py
msb exec route-b -- sh -c "(timeout 600 python3 /srv-api.py 0.0.0.0 8080 route-B-microvm >/dev/null 2>&1 &)"

# The arms, probing each target with a real request (probe.py: host,port,label …)
T="<vm-public-ip>,18080,A <vm-public-ip>,18081,B <vm-public-ip>,22,VM-ssh 127.0.0.1,18080,loopback <vm-tailnet-ip>,22,tailnet 169.254.169.254,80,metadata 1.1.1.1,443,internet"
msb run --script-raw p="$(cat probe.py)" python -- /.msb/scripts/p $T                        # reference arm
msb run --no-net --net-rule allow@<vm-public-ip>/32:tcp:18080-18081 \
  --script-raw p="$(cat probe.py)" python -- /.msb/scripts/p $T                              # Kalari arm

# From the laptop: no answer on the public IP (firewall), refused on the tailnet (bound to the public IP)
curl -s -m 6 -o /dev/null -w '%{http_code}\n' http://<vm-public-ip>:18080/x
curl -s -m 6 -o /dev/null -w '%{http_code}\n' http://<vm-tailnet-ip>:18080/x

# Clean up
msb stop route-b && msb remove route-b; pkill -f '^python3 api.py <vm-public-ip>'
```

### OpenCode's background daemon

```bash
pgrep -af 'opencode serve|microsandbox-mcp'        # after a plain `opencode run`: still there
# Is the key in its environment? (count only, never the value)
tr '\0' '\n' < /proc/<pid>/environ | grep -c '^VULTR_INFERENCE_API_KEY='
# Was the key written anywhere? (the key arrives on stdin; only file names come back)
printf '%s\n' "$VULTR_INFERENCE_API_KEY" | ssh <user>@kalari 'read -r K; grep -rlaF -- "$K" ~/.local/share/opencode ~/.cache ~/.config ~/b5 || echo none'
opencode service stop                              # or kill the pid

# The fix: a private server per run, and per-run state directories
D=$(mktemp -d)
XDG_DATA_HOME=$D/data XDG_STATE_HOME=$D/state XDG_CACHE_HOME=$D/cache \
  opencode run --standalone --format json --auto "$(cat prompt.txt)"
pgrep -af 'opencode serve|microsandbox-mcp' || echo none   # nothing left
```
