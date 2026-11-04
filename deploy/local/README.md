# Local preset

Run Kalari on a laptop. This preset does not need KVM. The demo path stays Microsandbox, on a host that has it. A laptop without KVM uses this Docker backend.

## Build

The Lean toolchain is pinned in `lean-toolchain`.

```sh
lake build
```

`lake build` also runs this backend's checks. They replay `deploy/local/recordings/` and do not start a container. `./tools/check.sh` is the full gate.

## Run the Docker backend

Set `sandbox.backend` to `docker` and `sandbox.allowlist` to `[]`. A non-empty allowlist is refused. Docker has no per-IP allow rule. This backend does not start an egress proxy and does not apply nftables. The container's network is `--network none`.

The image is `debian:stable-slim`. It must already be on the laptop. The backend does not pull it.

`Kalari.Sandbox.Docker.live` is the runner that calls `docker`. Pass it a `PATH` that contains `docker`, such as `/usr/bin:/bin`. The parent environment is not inherited. The build checks do not call `live`.

A run's command is:

```text
docker run --name <name> --rm --network none --read-only --memory <mib>m --pids-limit 256 -v <host-path>:/workspace:rw debian:stable-slim <command...>
```

- `--network none` is the only network mode. The argv has no other network flag.
- `--read-only` is the root filesystem. The workspace is mounted writable at `/workspace`.
- `--memory` is the run's `memory_mib`. `--pids-limit` is 256.
- `--rm` removes the container when the command exits. A name left behind is removed with `docker rm -f <name>`.

The recorded run is `deploy/local/recordings/kalari-docker-record.stdout`, `.stderr`, and `.exit`: name `kalari-docker-record`, command `echo kalari-docker`, exit 0.
