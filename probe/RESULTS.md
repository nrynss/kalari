# Auth proxy probe

## Goal
Test host-side auth proxy for sandbox observation.

## Setup
Two brokers on host loopback. Each holds one run user and password from host env. Each writes one trace. Guest allows only TEST-NET-3 port 18080. Guest reaches API only via CONNECT with correct Basic auth. Private API variant lives on Unix socket with mode 600.

## Checks
1. Guest A reaches API via its proxy. Trace A holds its GET. Trace B stays empty.
2. Guest B reaches API via its proxy. Trace B holds its GET. Trace A keeps only its own line.
3. Direct guest without proxy times out. No trace grows. No bypass exists.
4. Wrong user fails closed. Missing auth fails closed. Wrong dest returns 403. No trace grows.
5. Two runs live at once. Traces stay separate. Kill of A leaves B working.
6. Kill of broker closes its port. Guest then fails closed. No new trace. Socket file stays host-only.
7. Guest env holds no password. Guest filesystem holds no password. Traces hold only request lines. Broker logs hold no password.

## Fixes (issues 2, 3)

- Broker no longer invents observations: `broker_unix.py` forwards only a
  complete framed inner request. An empty or incomplete tunnel closes with
  no forward, no trace write, and no inner 200. The `GET /empty` fallback
  is gone; the observer also ignores empty/incomplete connections.
- Transport bounds: 10 s client read deadline on broker and observer,
  16 KiB header cap on both CONNECT and inner blocks (400, no observation
  when exceeded), 64 KiB inner body cap with Content-Length framing.
- Bytes buffered after the CONNECT delimiter seed the inner request, so a
  pipelined CONNECT+GET in one segment is observed exactly once.
- `mini_proxy.py` logs `Proxy-Authorization: [REDACTED]`; values never
  reach the log.
- `probe/run_two_guest.py` reproduces the checks above locally (loopback
  only, no microVM): sanitized creation args, response status lines, trace
  counts, parser checks on both traces, owner-death with observer running,
  private per-run dir (0700) with 0600 sockets, and cleanup results.
  Passwords stay in host env; all logs are scanned for leaks.

## Notes
Passwords lived only in host env and in 600 files under /tmp. No key entered any guest. No VM writes occurred. Sandboxes use --no-net with one allow rule and --pull never.
