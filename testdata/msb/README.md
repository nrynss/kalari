# msb recordings (T0.5)

What Microsandbox's CLI (msb 0.7.13) prints, for the Microsandbox backend (T2.3) to replay: `<case>.stdout`, `<case>.stderr`, and `index.json` with each case's `argv`, `exit` and `ms`. Recorded on the Vultr VM, non-interactive (no TTY), the VM's IP replaced with `203.0.113.10`.

| Case | Exit | Notes |
|---|---|---|
| `create-ok` | 0 | `--no-net --net-rule allow@<ip>/32:tcp:18090-18091 python:3.13-slim`, ~460 ms |
| `create-duplicate` | 1 | `error: sandbox already exists: … remove it, start the stopped sandbox, or recreate with .replace()` |
| `list-text`, `list-json` | 0 | **Only `list` has machine output** (`--format json`: `name`, `image`, `status`, `created_at`). Every other command is text |
| `copy-in-ok`, `copy-in-unknown` | 0, 1 | |
| `exec-ok` | 0 | |
| `exec-exit3` | **3** | `msb exec` passes the command's exit code through, stdout and stderr kept apart |
| `exec-unknown` | 1 | `error: sandbox not found: <name>` |
| `exec-held-pipe` | 124 | A background child without redirected output: `exec` never returns (killed by `timeout 5`) |
| `exec-redirected-bg` | 0 | The same with output redirected: returns at once |
| `exec-sysctl` | 0 | `echo 1 > /proc/sys/vm/overcommit_memory` works as the guest's root |
| `copy-out-ok`, `copy-out-missing` | 0, 1 | |
| `stop-ok` | 0 | |
| **`exec-stopped`** | **0** | **`exec` on a stopped sandbox silently starts it again** (517 ms, no output): never treat "stopped" as gone; remove |
| `remove-ok`, `remove-unknown` | 0, 1 | |
| `storage-group-writable` | 1 | `error: io error: catalog ancestor … permits path substitution; use a storage root protected from other accounts` (storage made group-writable for this one command, then restored) |

Errors go to stderr as one line starting `error:`, exit 1. Output carries no ANSI colour when not on a TTY.
