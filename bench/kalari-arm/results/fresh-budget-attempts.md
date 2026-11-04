# Fresh-budget live attempts

Four bounded attempts were made under a new $5 allowance. These are not
benchmark runs. Tool transcripts contain names and statuses only. Each attempt
used isolated standalone OpenCode and a private session; none produced a
candidate output for the hidden grader. Account-wide deltas can include other
work and the prices below are the project-recorded $0.15 per million input and
$0.60 per million output tokens, not a provider bill.

1. The 60-second watchdog stopped OpenCode after it saw no Kalari tools; it
   used built-in tools to search for them. The tool transcript is
   `fresh-budget-first-tools.jsonl`. The hidden guest reported `EXIT 1`, with
   no output. The delta was 1,797,954 input and 24,408 output tokens (about
   $0.2843), with zero Clef tokens. Cleanup found no sandbox left but reported
   a failed removal of an already removed grader sandbox.
2. A loopback bootstrap gate prevented any provider request because it did not
   see all five tools. OpenCode hit the 60-second watchdog; the only tool call
   was the synthetic README read (`fresh-budget-2-tools.jsonl`). The grader had
   no output and reported `EXIT 1`. The account delta was 359,973 input and
   4,122 output tokens (about $0.0565); a concurrent benchmark was active, so
   this delta is not attributable to this attempt. Clef was zero. Cleanup
   reported one tracked sandbox, none left and no errors.
3. After resolving the trusted aashaan symlink to its canonical path, the gate
   forwarded a request containing all five tools. The 60-second watchdog fired
   with no completed provider step or Kalari call (`fresh-budget-3-tools.jsonl`).
   The grader had no output and reported `EXIT 1`. The account delta was 40,376
   input and 636 output tokens (about $0.0064), with zero Clef tokens. Cleanup
   reported one tracked sandbox, none left and no errors.
4. With a 120-second watchdog, OpenCode exited after 97.004 seconds with
   `provider.invalid-output`: the HTTP 200 chat stream ended without a
   `finish_reason`. There were no Kalari calls or candidate output
   (`fresh-budget-4-tools.jsonl`); the grader reported `EXIT 1`. The account
   delta was 63,371 input and 1,049 output tokens (about $0.0101), with zero
   Clef tokens. Cleanup reported one tracked sandbox, none left and no errors.

Summed account-wide deltas are approximately $0.3573 at the recorded rates,
including the overlapping benchmark. The detached session process was reaped;
a final process inspection found only the four pre-existing API sandboxes.
The five-tool transcript, hidden grade and complete measures required by T4.7
remain unmet.

An actual standalone OpenCode run against a local fake provider reproduced the
MCP startup race, then confirmed that the gate and canonical aashaan path expose
all five tools in the first forwarded request with the same guarded tool layout.
A delayed-chunk fake upstream and timed local stream test confirmed the proxy
forwards the first chunk before the second arrives. These checks spent no
provider inference tokens. The source of the final truncated real stream is not
established by these checks.
