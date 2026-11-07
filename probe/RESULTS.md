# Auth proxy probe

## Goal
Host-side authenticated broker for sandbox observation. One real
payouts consumer produces an attributable valid payouts observation
trace through the broker; the production observer stays refused.

## Setup
Brokers on host loopback. Each holds one run user and password from host
env only (never in args, files, or logs). Each writes one trace. The
CONNECT destination allowlisted per broker is the API address the guest
dials. The guest reaches the API only through the host proxy with
host-injected auth; the guest itself sends ordinary requests with no
credentials. The private API lives on a Unix socket (mode 600) in a
private per-run dir (mode 700). No microVM writes occur in the loopback
suite; the microVM suites use cached images with `--pull never`.

Host proxy auth (msb 0.7.13): guests are created with
`--proxy http://127.0.0.1:<broker-port>`,
`--http-connect-username <run-user>`, and
`--http-connect-password-env <host-env-var>`. The msb runtime builds the
authenticated CONNECT; the guest builds none. The API destination is a
non-loopback TEST-NET-1 address (`192.0.2.1:18080`) so the guest dial
leaves the guest via the proxy instead of hitting guest loopback.

## Suites (all reproducible locally)

- `probe/run_two_guest.py` — local broker regression suite (loopback
  clients, not microVMs). Sanitized creation args (env names, never
  values), response status lines, trace counts, and cleanup.
- `probe/owner_death.py` — true owner SIGKILL ownership (two owners, each
  with a private dir and unique ports/users/sockets/traces).
- `probe/run_two_microvm.py` — two real microVM guests via `msb`
  (`--no-net`, destination rules for the API address, `--pull never`,
  host proxy auth, bounded exec, empty guest env, umask 022).
- `probe/run_payouts_validation.py` — real payouts handler through the
  broker via `probe/payouts_unix_adapter.py` (Unix-only, reuses
  `bench/apis/payouts/server.py` unmodified), host-side traversal,
  validated with the production Lean parser
  (`Kalari/Tools/Run.pageObservations`).
- `probe/run_guest_payouts.py` — real guest payouts traversal through the
  complete path: the correct consumer runs inside a real microVM via
  host-injected auth through the broker to the Unix adapter, validated
  with the production Lean parser.

## Checks

1. Client A reaches its API via its broker; trace A holds its GET.
2. Client B reaches its API via its broker; traces stay separate.
3. Wrong user, missing auth, wrong dest (403), and non-CONNECT (405) fail
   closed with no trace growth.
4. Empty close and incomplete tunnel write nothing: no observation, no
   inner 200, no `/empty` line.
4b. Oversize CONNECT and oversize inner fail 400 with zero trace growth
   (16 KiB header cap).
4c. Framing refusals fail 400 with zero trace growth and no inner 200:
   any Transfer-Encoding, duplicate Content-Length (even identical),
   invalid or over-cap lengths, malformed request/header lines. Includes
   Repro A (authenticated CONNECT then POST /incomplete with chunked,
   close with no chunks) and Repro B (authenticated CONNECT then POST
   /conflicting with two Content-Length headers, close with no body).
   Each refusal asserts: no request reaches the observer, neither trace
   grows, no inner 200, clean close (400, never 200).
5. Both runs live at once; traces stay separate.
5b. Bytes buffered after CONNECT are preserved (pipelined send in one
   segment observed once).
6. Broker-death: killing broker A (observer still running) fails closed;
   broker B keeps serving. This is a broker-only kill, not ownership
   proof; see owner-death below.
7. Socket/dir modes (0600/0700), logs free of passwords and Basic values,
   `mini_proxy` redaction (`Proxy-Authorization: [REDACTED]`).
8. Probe trace spot checks (request-line shape only, not the Kalari
   page-observation parser).

Owner death (separate binary, not a finally-block):
- Two owners each start one broker+observer pair (private dir, unique
  ports/users/env names/sockets/traces). Children carry
  PR_SET_PDEATHSIG=SIGTERM with prctl return checked and expected parent
  PID verified, so the kernel reaps them on owner death and the
  fork-vs-exit race cannot run without the link.
- Controller SIGKILLs owner A while children run, then verifies: broker
  listener closed (TCP refused), observer exited, Unix socket removed,
  trace byte-identical, direct dial fails closed, owner B still serves
  (new event on trace B only). Cleanup targets only the two owners, their
  PIDs, and the two private dirs.

Two microVMs (real `msb` guests, host-only credential boundary):
- Image pulled once with retries (setup), creates use `--pull never`.
- Guests carry no credential by design: the guest probe sends ordinary
  GET with no auth header, no stdin, no secret. The host runtime builds
  CONNECT with per-guest host-env auth.
- Guest A reaches own observer via host-injected auth, guest B reaches
  own observer; overlap keeps traces separate.
- Host-side B creds on A broker, missing auth, wrong auth fail closed
  (407); guest wrong-dest via proxy and host wrong-dest fail closed
  (broker 403 / proxy refused) with zero growth and no inner 200.
- Direct (non-CONNECT) GET from the host gets 405 and never reaches the
  private Unix observer. A guest cannot send non-CONNECT: the host
  runtime always sends CONNECT first.
- Credential hygiene: no credential value in guest config (`msb inspect`
  shows env names only), guest args, guest env (`env`), guest output,
  copied files, host logs, or the transcript. The guest probe contains
  no proxy-auth header construction, no Basic value, no stdin reading,
  no base64.

Real payouts (Unix adapter, no frozen-file change):
- Adapter imports `bench/apis/payouts/server.py`, pins `trace_client` to
  `127.0.0.1` (never trusts guest identity headers), serves Handler on a
  Unix socket only. Broker is the only entry. Auth never appears in
  responses or the trace.
- Correct traversal (limit 1000, follow cursor, dedupe, one 429 retry)
  through authenticated CONNECT tunnels captures real page and retry
  events; the Lean `pageObservations` parser accepts the trace.
- Unauthorized (wrong/missing auth, wrong dest) add no events.

Real guest payouts (complete path, host-only credential boundary):
- Same adapter and broker, plus one real microVM with host proxy auth.
  The correct consumer (`bench/apis/payouts/reference/correct.py`,
  unmodified) runs inside the guest with an ordinary base URL; the host
  injects auth. The consumer source carries no credential handling.
- The Lean `pageObservations` parser accepts the guest-produced trace.
- Host-side wrong/missing auth and wrong dest, plus guest wrong-dest via
  proxy, add no events. No raw cursors, tokens, or credentials in output.

## Reproducible commands (sanitized)

- `python3 probe/run_two_guest.py`
- `python3 probe/owner_death.py`
- `umask 022; python3 probe/run_two_microvm.py`
- `python3 probe/run_payouts_validation.py`
- `umask 022; python3 probe/run_guest_payouts.py`
- `export PATH="$HOME/.elan/bin:$PATH"; ./tools/check.sh`

Creation args show env names (for example `--pwenv KALARI_MICROVM_PW_A`
and `--http-connect-password-env KALARI_MICROVM_PW_A`), never values.
Responses show status lines and lengths only. Traces show counts and
request lines (probe) or event counts and parser facts (payouts). No raw
cursors, tokens, credentials, or personal data are recorded here; run
the commands for the full sanitized transcripts.

## Last measured results (this checkout)

- `run_two_guest.py`: `RESULT: PASS 15/15` — includes `framing: PASS 8/8
  refused 400, zero trace growth, no inner 200` (Repro A/B plus
  identical-dup, TE+CL, bad length, over-cap, bad line, bad header) and
  `broker-death: PASS`.
- `owner_death.py`: `RESULT: PASS 6/6` — `owner-ready`, `owner-both-serve`
  (trace-a=1 trace-b=1), `owner-death` (SIGKILL reaps pair, TCP refused,
  Unix refused, socket removed, trace stable), `owner-dead-closed`,
  `owner-other-keeps-working` (trace-a=1 trace-b=2), `owner-hygiene`.
- `run_two_microvm.py`: `RESULT: PASS 11/11` — `microvm-reach-own`
  (trace-a=1 trace-b=1), `microvm-overlap` (2/2),
  `microvm-fail-closed` (host B-creds/missing/wrong 407, guest+host
  wrong-dest closed), `microvm-direct-closed` (405, zero growth),
  `microvm-by-design`, `microvm-hygiene`, `microvm-modes` (0600/0700).
- `run_payouts_validation.py`: `RESULT: PASS 6/6` — traversal
  `pages=25 rows=2431 retries=1 drained=True`, trace `26 events
  statuses={200: 25, 429: 1}`, parser
  `VALID [boundary_overlap_one, final_page_token, rate_limit_retry]`,
  unauth `407/407/403 stable=True`.
- `run_guest_payouts.py`: `RESULT: PASS 10/10` — guest traversal
  `synced 2431 payouts`, trace `26 events statuses={200: 25, 429: 1}`,
  parser `VALID [boundary_overlap_one, final_page_token,
  rate_limit_retry]`, unauth `407/407/403 stable=True`.
- Gate: `./tools/check.sh` passes (see handoff for the commit hash).

## Fixes (issues 2, 3, framing, host-auth boundary, owner race)

- Broker forwards only one complete framed inner request. Empty or
  incomplete tunnels close with no forward, no trace write, no inner 200.
  The `GET /empty` fallback is gone; the observer also ignores
  empty/incomplete connections.
- Strict framing before observation: every Transfer-Encoding refused;
  duplicate Content-Length refused (including identical); empty,
  non-digit, comma-list, and over-cap (>64 KiB) lengths refused;
  malformed request lines (`METHOD SP TARGET SP HTTP/x`) and malformed
  header lines (no colon, bad field token, leading whitespace) refused.
  All framing refusals are 400 with no forward and no trace growth.
- Transport bounds kept: 10 s read deadline, 16 KiB header cap on both
  blocks (400, no observation), 64 KiB body cap with Content-Length
  framing. Buffered bytes after CONNECT seed the inner request.
- Observer socket cleanup on SIGTERM/SIGINT (for the owner PDEATHSIG
  path); normal loopback behavior otherwise unchanged.
- Host-only credential boundary: guests are created with msb host proxy
  auth (`--proxy` plus `--http-connect-username` plus
  `--http-connect-password-env`); the guest probe makes ordinary GET
  with no credential handling and no stdin. Stdin credential passing is
  removed; guest proxy-auth header construction is removed. The guest
  holds no credential by design, proven by source inspection plus hygiene
  scans of config, args, env, output, files, and logs.
- Owner startup race fixed: the preexec checks the prctl return value
  and verifies the expected parent PID after registration; a reparented
  child exits instead of running without the ownership link. SIGKILL
  behavior is unchanged.
- Real guest payouts added: the correct consumer runs inside the guest
  via host-injected auth through the broker to the Unix adapter; the
  production parser validates the trace; unauthorized adds nothing.
- `mini_proxy.py` logs `Proxy-Authorization: [REDACTED]`; values never
  reach the log. Probe runner descriptions now say loopback clients, not
  microVMs; `owner-death` renamed to `broker-death`; the request-line
  regex is documented as probe shape only.

## Notes
Passwords live only in host env. No key enters any guest; guest env is
empty of credentials and the guest probe carries none (no stdin, no
header construction, never logged). No VM writes occurred in the loopback
suites. MicroVM suites use `--no-net` with destination rules, host proxy
auth, and `--pull never`. The six API microVMs,
`/var/lib/kalari/evidence`, and film/t54 bins were not touched.
Production `kalari serve` still refuses every observer
(`observer requires verified exclusive guest source isolation`).

## Dead code removed
Legacy `probe/broker.py` (pre-fix direct-trace broker) deleted earlier:
no references from the runner, which uses `broker_unix.py` and
`obs_unix.py` only. `mini_origin.py` and `mini_proxy.py` stay — spawned
by `run_two_guest.py` for the proxy-redaction check.
