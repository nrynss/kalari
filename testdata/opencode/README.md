# OpenCode 2.2.5 as an MCP client (T0.5)

What OpenCode sends to a local MCP server: the contract `kalari serve`'s MCP side (T4.1) must meet. Recorded on the Vultr VM with `stub_mcp.py` standing in for Kalari (one tool, `what_changed`, returning a fixed change), OpenCode run headless (`opencode run --standalone --format json --auto`, per-run `XDG_*` directories, DeepSeek V4.1 Flash on Vultr), the prompt asking it to call `what_changed` and report.

| File | Contents |
|---|---|
| `codemode.mcp.jsonl` | Every message between OpenCode and the server, Code Mode on (the default): `{"t", "dir": "in"/"out", "msg"}` |
| `direct.mcp.jsonl` | The same with `"codemode": false` on the server |
| `*.events.jsonl` | OpenCode's own event stream for each run |
| `stub_mcp.py` | The stub server |

What it sends, both modes: `initialize` (with its `protocolVersion` and `clientInfo`), `notifications/initialized`, `tools/list`, then `tools/call` with the arguments the model chose. No `ping`, no resources or prompts requests.

- **Code Mode on:** the model reaches the tool through `execute` scripts (`tools.kalari.what_changed(...)`); the server still sees a plain `tools/call`.
- **Code Mode off:** the tool is declared to the model as **`kalari_what_changed`** (`<server>_<tool>`). The model still tried `execute` first.
- OpenCode closes the server's stdin at the end of the run; nothing was left running.
