#!/usr/bin/env bash
# Run the showcase disbursements API on the VM, in its own microVMs, exactly as
# bench/apis/deploy.sh runs the frozen APIs (bench/README.md, The network route).
#
#   deploy.sh up <vm-public-ip>     start both: live (v1 on) and grading (v1 retired)
#   deploy.sh down                  stop and remove them
#   deploy.sh status                list them
#
#   disbursements  live :18082   grading :18092
#
# Egress is denied (--no-net would also block the published port), and each port is published
# on the VM's public IP only: not loopback, not the tailnet, and dropped from the internet by
# the Vultr firewall. No arm can read the server: its code exists only inside these microVMs.
set -euo pipefail
umask 022
cd "$(dirname "$0")"

names=(api-disbursements-live api-disbursements-grading)

start() {  # start <name> <host-port> <v1 on|off> <ip>
  local name=$1 port=$2 v1=$3 ip=$4
  msb create --name "$name" --cpus 1 --memory 256M --net-default-egress deny -p "$ip:$port:8080" python >/dev/null
  msb exec "$name" -- mkdir -p /srv
  msb copy -q server.py "$name:/srv/server.py"
  msb copy -q data.py "$name:/srv/data.py"
  # Redirect the server's output, or msb exec waits on the held pipe forever.
  msb exec "$name" -- sh -c "(nohup python3 -I /srv/server.py --bind 0.0.0.0 --port 8080 --v1 $v1 >/srv/server.log 2>&1 &)"
  for _ in $(seq 1 50); do
    if curl -s -o /dev/null --max-time 2 "http://$ip:$port/"; then echo "$name: http://$ip:$port (v1 $v1)"; return; fi
    sleep 0.2
  done
  echo "$name: did not come up" >&2; msb exec "$name" -- cat /srv/server.log >&2; return 1
}

case "${1:-}" in
  up)
    ip=${2:?usage: deploy.sh up <vm-public-ip>}
    start api-disbursements-live    18082 on  "$ip"
    start api-disbursements-grading 18092 off "$ip"
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
