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

## Notes
Passwords lived only in host env and in 600 files under /tmp. No key entered any guest. No VM writes occurred. All sandboxes used --no-net with one allow rule and --pull never.
