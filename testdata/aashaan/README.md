# kalari-aashaan verdicts (T0.5)

`verdicts.jsonl`: the eight cases run inside a Microsandbox microVM on the Vultr VM (`debian` image, 1 vCPU, 256 MB, `--no-net`, `vm.overcommit_memory=1`), one line per case: `{"case", "argv", "verdict"}`, where `verdict` is the aashaan's JSON exactly as printed. For `Kalari/Model.lean` (T1.1: they must parse as `Verdict`) and the backends' fakes.

| Case | Verdict |
|---|---|
| normal | `exited` 0, stdout `hello`, stderr `warn` |
| exit3 | `exited` 3 |
| loop, trapterm, fork | `killed_timeout` at ~808 ms |
| flood | `killed_output_cap`, `stdout_truncated: true` |
| secret | `exited` 0, stdout `key=[]` |
| escape | `killed_timeout`, `pipe_held_open: true` |

Re-record with `tests/live/microvm-cases.sh` after changing `Aashaan/`. (The trap script must be copied into the microVM as a file: quoting it through `msb exec … bash -s` broke it once, giving `exited 2`.)
