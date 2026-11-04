# Interrupted retry

A bounded retry was started after a process check found no competing OpenCode
or Kalari session. The SSH command exited 143 approximately 30 seconds later.
The signal source is unknown. The runner produced no transcript, token measures,
grade, or sandbox ledger, and deleted its temporary raw events. Because the
runner's signal handler exits with this status from its OpenCode loop, inference
may have started; the retry's cost is unknown. No further inference was run.

A subsequent process and sandbox inspection found no session processes and
only the four pre-existing API sandboxes. The private result directory was
empty. The runner now saves the usage-before token counts and preserves a
sanitized partial transcript and measures on handled interruption. That change
cannot recover the lost retry evidence or establish its cost.
