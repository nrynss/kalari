#!/usr/bin/env bash
# Run the benchmark APIs on the Vultr VM, each in its own microVM (bench/README.md, The network route).
#
#   deploy.sh up <vm-public-ip>     start all four: live (v1 on) and grading (v1 retired)
#   deploy.sh down                  stop and remove them
#   deploy.sh status                list them
#
#   payouts      live :18080   grading :18090
#   settlements  live :18081   grading :18091
#
# Egress is denied (--no-net would also block the published port), and each port is published on
# the VM's public IP only: not loopback, not the tailnet, and dropped from the internet by the
# Vultr firewall. No arm can read the servers: their code exists only inside these microVMs.
#
# Each server writes a host-owned retry journal at /srv/retry-journal.jsonl in its own guest.
# The journal holds request digests only, never a cursor, a request body or a token. The
# harness truncates it at a phase start and reads it at a phase end over `msb exec`.
set -euo pipefail
umask 022
cd "$(dirname "$0")"

names=(api-payouts-live api-payouts-grading api-settlements-live api-settlements-grading)
JOURNAL=/srv/retry-journal.jsonl

start() {  # start <name> <api> <host-port> <v1 on|off> <ip>
  local name=$1 api=$2 port=$3 v1=$4 ip=$5
  msb create --name "$name" --cpus 1 --memory 256M --net-default-egress deny -p "$ip:$port:8080" python >/dev/null
  msb exec "$name" -- mkdir -p /srv
  msb copy -q "$api/server.py" "$name:/srv/server.py"
  msb copy -q "$api/data.py" "$name:/srv/data.py"
  if [[ $api == settlements ]]; then
    msb copy -q vendor/graphql_core-3.3.1-py3-none-any.whl "$name:/srv/graphql_core-3.3.1-py3-none-any.whl"
  fi
  # Redirect the server's output, or msb exec waits on the held pipe forever.
  msb exec "$name" -- sh -c "(nohup python3 -I /srv/server.py --bind 0.0.0.0 --port 8080 --v1 $v1 --retry-journal $JOURNAL >/srv/server.log 2>&1 &)"
  for _ in $(seq 1 50); do
    if curl -s -o /dev/null --max-time 2 "http://$ip:$port/"; then echo "$name: http://$ip:$port (v1 $v1)"; return; fi
    sleep 0.2
  done
  echo "$name: did not come up" >&2; msb exec "$name" -- cat /srv/server.log >&2; return 1
}

case "${1:-}" in
  up)
    ip=${2:?usage: deploy.sh up <vm-public-ip>}
    start api-payouts-live        payouts     18080 on  "$ip"
    start api-payouts-grading     payouts     18090 off "$ip"
    start api-settlements-live    settlements 18081 on  "$ip"
    start api-settlements-grading settlements 18091 off "$ip"
    ;;
  down)
    for n in "${names[@]}"; do msb stop "$n" >/dev/null 2>&1 || true; msb remove "$n" >/dev/null 2>&1 || true; done
    msb list
    ;;
  status)
    msb list
    ;;
  *)
    sed -n '2,14p' "$0"; exit 2
    ;;
esac
