# Upgrade-one live attempt

One payout session ran on the benchmark VM with OpenCode 2.2.5, msb 0.7.13,
Lambo 0.9.0 and Vimanam 2.1.0. It was stopped after the agent repeatedly failed
to progress through blast-radius discovery. The sanitized tool-call transcript
is `upgrade-one-tools.jsonl`; it omits inputs and outputs. MCP Code Mode was off:
the three Kalari tools that the agent reached appeared by their individual
names. OpenCode also exposed its built-in `execute` tool. The model passed a
change kind as a change ID on its first blast-radius call; the later two calls
failed because the staged tools omitted `rg`.

The hidden-grader guest ran the final candidate and reported `EXIT 0`. The host
grader returned an error because its fixture data was not staged, so no verdict
or counts were obtained. The temporary output was removed before the problem
was found. Neither `run_in_sandbox` nor `record_lesson` was called; right-first-
time and time-stuck were not established. This does not meet T4.7's done clause.

The session lasted 112.614 seconds before termination. OpenCode's step telemetry
reported 197,832 uncached input tokens, 2,320,256 cache-read input tokens, 9,714
output tokens and 15,700 reasoning tokens. The account-wide delta was 2,627,044
DeepSeek input and 27,912 output tokens; Clef was zero. At the project-recorded
$0.15/$0.60 per million list rates, counting all input at full price, the
account-wide estimate is approximately $0.411. Account-wide usage may include
other sessions and is not an exact attribution. No second inference case ran.

The runner tracked three sandbox names and reported none left. A subsequent VM
process inspection found no OpenCode, Kalari, Lambo or benchmark-runner process;
only the four pre-existing API sandboxes remained. The grader's own sandbox was
also removed.
