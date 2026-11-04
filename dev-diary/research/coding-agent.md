# The coding agent

## Decided: OpenCode 2, pinned at 2.2.5, for both comparison arms

Compared with Pi 1.0.2 and Claude Code. All three can run on Vultr Inference: Claude Code through Vultr's Anthropic-format `/v1/messages`, where a DeepSeek `tool_use` came back valid.

| | OpenCode 2.2.5 | Pi 1.0.2 | Claude Code |
|---|---|---|---|
| Licence | MIT | MIT | Proprietary |
| Kalari plugs in via | MCP (`mcp.servers`) | MCP (`mcp.json`) or an extension | MCP, plus hooks |
| Large MCP servers | Code Mode by default: tools grouped behind `execute` scripts | `codemode` / `deferred` by default; `direct` per tool | Every tool sent with every request |
| Control over agent tools | `permissions` rules deny or hide tools, the host shell included | Extensions: a `tool_call` handler can change or block any call | `PreToolUse` hooks; the agent loop is closed |
| Safety model | Permission prompts; `--auto` approves what isn't explicitly denied | No prompts; its docs say only a VM or sandbox is a boundary | Permission prompts |
| Headless and resume | `run --format json --auto`, `-s <id>`, `-c` | `--print`, `--mode json/rpc`, `--session`, `--fork` | `-p`, `--resume` |
| Prompt overhead per step | Medium | Small | Large, tuned for Claude |
| Fit | **Vultr's reference setup** | Leaves it | Leaves it |

**Why OpenCode 2:** the baseline stays "Vultr's own setup, with and without Kalari"; it is open source and current; Code Mode and `permissions` handle a 70-tool MCP server and a denied host shell. **Pi** is the natural second integration (an extension could route every `bash` and `edit` call through the gate and a microVM). **Claude Code** is out: its harness can't be modified, its prompt is costly on per-token billing, and it muddies the "Vultr stack" story.

## Installing 2.x

- npm's `opencode-ai` and `opencode.ai/install` give **only the 1.x line** (1.19.5). GitHub's "Latest" label marks 1.x too.
- 2.x: `opencode.ai/v2/install`, Homebrew `anomalyco/tap/opencode-v2`, AUR `opencode-beta`, or the release tarballs. Kalari pins the tarball and checks its SHA-256 (`commands.md`).

## Configuring 2.x

The 2.x shape differs from Vultr's guide (`mcp.<name>` and a literal key there):

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "providers": {
    "vultr": {
      "name": "Vultr Serverless Inference",
      "env": ["VULTR_INFERENCE_API_KEY"],               // the key by name, never its value
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": { "baseURL": "https://api.vultrinference.com/v1" },
      "body": { "reasoning_effort": "low" },
      "models": { "deepseek-v4.1-flash-1017": { "name": "DeepSeek V4.1 Flash" } }
    }
  },
  "model": "vultr/deepseek-v4.1-flash-1017",
  "mcp": { "servers": { "microsandbox": { "type": "local", "command": ["npx", "-y", "microsandbox-mcp@0.7.13"] } } },
  "permissions": [
    { "action": "shell", "resource": "*", "effect": "deny" },
    { "action": "webfetch", "resource": "*", "effect": "deny" },
    { "action": "websearch", "resource": "*", "effect": "deny" },
    { "action": "external_directory", "resource": "*", "effect": "deny" },
    { "action": "microsandbox_runtime_install", "resource": "*", "effect": "deny" }
  ]
}
```

Permission rules combine in order, last match wins. A deny removes the tool: a call to it fails with "No tool named … is currently available". In 2.x a call to `bash` runs as `shell`, with the same permissions. Denying `execute` removes Code Mode entirely.

## B5: the reference run

**A stack check, not a comparison.** The task was easy on purpose (the server's source in the workspace, the end rule in a changelog, the count asked for), so its pass says nothing about Kalari against the baseline. The comparison's rules are in [`../../bench/README.md`](../../bench/README.md).

OpenCode 2.2.5 + `microsandbox-mcp` 0.7.13 + DeepSeek V4.1 Flash (`low`), headless, on the task in `bench/reference-paging/`.

| | |
|---|---|
| Task | The v1 importer exits 0 with "imported 100 items" while 2,331 of 2,431 records are lost, because the API now pages |
| Result | **Passed the hidden grader on the first attempt: 2,431 records, 2,431 unique.** The fix follows `next_page_token`, and the agent added protection against a repeating token unasked |
| Run | 30 s, 18 steps, 21 tool calls, Code Mode throughout (`execute` scripts calling `tools.microsandbox.*`) |
| Tokens (`/v1/usage` delta) | **331,501 input, 4,383 output** (1,688 reasoning). OpenCode's own count: 28,909 uncached input + 302,592 cache reads (91%). ~18.4k input tokens per step |
| Cost | **~$0.05** at list price, no cache discount assumed |

What it showed:
- **The denied host shell held.** The model's first call was `bash` (`ls -la`, `cat API_CHANGES.md`); OpenCode refused it (`executed: false`), and every later run went through microVMs.
- **The reference setup's network limit is the agent's choice.** It created its sandbox (`cpus: 2, memoryMib: 1024`) with **no network setting, so default mode**: the internet and the VM's own public IP reachable. Nothing in Vultr's setup can stop that; Kalari's `run_in_sandbox` sets the policy itself. For a fair comparison, the baseline's egress still has to be limited outside the agent, or the gap reported as a result.
- Its first `sandbox_create` failed on a missing `workdir` (`/app`); it retried without one, and removed the sandbox at the end.

## As an MCP client (T0.5)

OpenCode 2.2.5 sends `initialize`, `notifications/initialized`, `tools/list`, then `tools/call`, and closes stdin at the end (`testdata/opencode/`). With Code Mode on (the default) the model calls MCP tools from `execute` scripts; with `"codemode": false` on the server, each tool is declared to the model as `<server>_<tool>` (`kalari_what_changed`). For Kalari's five tools, `codemode: false` is likely better: few tools, and the model sees their schemas directly. T4.7 decides.

## The background daemon

**`opencode run` (2.2.5) starts `opencode serve --service`, which outlives the run.** Found half an hour after B5, re-parented to PID 1, with `microsandbox-mcp` still under it, and **the inference key in both processes' environments**. Not written to disk: its database, logs and the run's output were scanned for the key. Sessions accumulate in one shared `~/.local/share/opencode/opencode.db`.

- **`opencode run --standalone`** runs a private server that exits with the run (verified: nothing left running).
- Per-run **`XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`** isolate the database (verified).

**T5.1, condition 3, one fresh session of each upgrade.** OpenCode 2.2.5, `--standalone`, its own `XDG_*` directories, a 20-minute cap. Payouts: grader PASS, 2,431 of 2,431, right first time, 1 sandbox run, 29.265 s, 0 stuck, 577,808 in / 7,804 out, $0.091354. Settlements: grader PASS, 1,873 of 1,873, right first time, 2 sandbox runs, 27.722 s, 0 stuck, 452,070 in / 8,629 out, $0.072988. The usage delta matched OpenCode's own step tokens. The reference arm chooses its sandbox network, so it could reach the grading API. The hidden grade does not use that check. Nothing the harness started was left running.

**T5.2, the condition rows.** Forty reference sessions, $3.55. Conditions 2, 3, and 6 passed 10 of 10. Right first time missed twice, both with no consumer run against v2: condition 3 settlements repeat 1, and condition 6 payouts repeat 2. Condition 1 payouts passed 5 of 5. Condition 1 settlements resumed that session and failed 5 of 5 with grade note `no consumer output`. Condition 3 payouts repeat 5 hit the 20-minute cap and still graded PASS. The single-behaviour rows were captured separately with a restricted adapter. See [the pilot summary](../../bench/pilot/SUMMARY.md) for both sets and their comparability limits.
- `opencode service stop` stops a daemon that was started anyway.

## Running it

- **Send the prompt as a file.** Arguments after an `ssh` command are joined into one remote command string: a `;` in the prompt runs as a shell command on the VM.
- **Pipe the key over SSH stdin**, never in a command line or a file on the VM.
- `/v1/usage` is account-wide: run nothing else while measuring.

Commands in `commands.md` and `bench/reference-paging/README.md`.
