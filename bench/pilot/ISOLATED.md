# Single-behaviour pilot isolation

The single-behaviour rows use condition 3, a fresh OpenCode session and one
variant on both the live and grading endpoints. Their result files identify the
behaviour. They are separately labelled because their sandbox surface differs
from the earlier condition rows: the pilot adapter exposes a fixed, run-owned
Python guest and a small subset of the Microsandbox MCP tools. It copies the
workspace into that guest before execution; guest writes do not sync back to the
host workspace. The original reference sessions could select a sandbox and a
host bind mount and had a broader tool and network surface. These differences
can affect the comparison.

The guest uses `--no-net` with an allow rule for the dedicated live endpoint.
The grading guest permits only the dedicated grading endpoint. The API guests
publish their own ports with default egress denied. The adapter does not expose
snapshot, restore, mount, secret, image mutation, SSH, or port-publishing
operations; the inference key and the redaction copy are removed from its
environment. Cleanup targets only sandboxes created by the run. The first nine variant
sessions used a private process group, but OpenCode also creates separate
sessions; each of those nine exited normally and a subsequent process check
found no pilot processes. Later sessions use a uniquely named transient user
systemd scope to stop and verify all owned descendants, including detached
ones. API and guest names are unique; the pilot refuses occupied ports.

Before paid runs, each live and grading endpoint was checked with its
behaviour's characteristic reference consumer. The B2, B3, and B4 checks
matched the exact expected missing, duplicate and mismatch counts; both B1
checks timed out as expected. A separate guest check reached its allowed API,
was denied access to the pre-existing shared API port, and executed a copied
workspace file. A scope preflight captured and stopped a detached child. The adapter smoke test checked key absence and refused a foreign
sandbox and restore operation. No inference was used for those checks.

The first session, payouts B1 repeat 1, cost $0.033182 at the recorded list
price. Together with the 40 earlier rows, measured spend was $3.578824. At
$0.25 for each of 29 remaining sessions the projection was $10.828824, below
the $16 budget. `run-missing.sh` preserves existing rows, checks the projection
before each session using the greater of $0.25 and the largest measured
variant cost, and leaves a pending marker after an interrupted run for spend
reconciliation before resumption. A projection is an estimate, not a hard cap
on an individual inference session.

After the ninth variant, process inspection showed that OpenCode starts separate
sessions beyond the original process group. The active run was allowed to finish,
then the next wrapper was deliberately prevented from executing; no inference
was made for that pending row. A later process check found no remaining pilot
processes or sandboxes. A no-inference scope probe captured a detached child and
verified its removal after the original leader exited. The remaining sessions
use that scope and record `cleanup.scope_verified` accordingly. The first nine
rows retain `false` for that field; their measures were not changed.

For the first 19 variants, private copies of the API and grader sources remained
in a staging directory outside the workspace while the arm ran; OpenCode's
external-directory permission denied access to that directory. Subsequent
sessions remove those staged source copies after provisioning the API guests
and before starting the arm. The grading runner remains staged, while the
hidden grader itself runs locally after the session.
A separate copy of the payouts server from the initial no-inference preflight
also remained outside the workspace until it was removed during the twentieth
variant session; the same external-directory restriction applied.
