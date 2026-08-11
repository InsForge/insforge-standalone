# Podman / quadlet runtime profile

The Ubuntu 24.04 + podman variant of a project instance. Selected by which AMI
the control plane launches; nothing in the control plane needs to know which
one it got, because every operation goes through `insforge-ctl`, which detects
the runtime on the instance itself.

## Why detection instead of a flag

A project's runtime is not stable over its lifetime. Pausing terminates the
instance and restoring provisions a fresh one from whatever AMI is current, so
a project created on AL2023 + docker-compose can legitimately come back on
Ubuntu + podman with no change to the project itself. Any runtime marker
stored in the control plane is a second source of truth that drifts from the
instance the moment that happens. `insforge-ctl runtime` asks the machine.

## Files

| File | Installed to | Purpose |
|---|---|---|
| `insforge.network` | `/etc/containers/systemd/` | Bridge network for the three services |
| `insforge-postgres.container` | `/etc/containers/systemd/` | Postgres; `--network-alias=postgres` |
| `insforge-postgrest.container` | `/etc/containers/systemd/` | PostgREST; `--network-alias=postgrest` |
| `insforge.container` | `/etc/containers/systemd/` | App; inherits the CloudFront PEM via `-e` |
| `insforge-render-env` | `/usr/local/bin/` | `.env` → per-service env files, secrets drop-in, limit drop-ins |

`../insforge-ctl` → `/usr/local/bin/insforge-ctl` (shared by both runtimes).

## Two non-obvious constraints, both learned the hard way

**Container DNS names are container names, not compose service aliases.** The
app connects to `postgres:5432` and PostgREST to `postgres`, but quadlet
registers the container as `insforge-postgres`. Without
`PodmanArgs=--network-alias=postgres` the app cannot resolve its database and
crash-loops through migrations. Same for `postgrest`.

**Multi-line values cannot travel in an env file.** `AWS_CLOUDFRONT_PRIVATE_KEY`
is a PEM; neither systemd's `EnvironmentFile=` nor podman's `--env-file` parses
a value containing newlines. `insforge-render-env` writes it into
`/etc/systemd/system/insforge.service.d/secrets.conf` as a systemd
`Environment="KEY=…\n…"` string (systemd unescapes `\n` in quoted values), and
the unit passes it through with a valueless `-e AWS_CLOUDFRONT_PRIVATE_KEY`,
which tells podman to inherit it from the process environment. Verified
byte-for-byte inside the container.

## Other things worth knowing before editing these

- Quadlet-generated units **cannot** be `systemctl enable`d ("transient or
  generated"). Boot start comes from `[Install] WantedBy=` inside the
  `.container` file, which quadlet honours at generation time.
- podman 4.9 (what Ubuntu 24.04 ships) has no `Notify=healthy`, so dependent
  units gate on the database with an `ExecStartPre` `pg_isready` loop rather
  than on the container's health status. `Notify=healthy` lands in podman 5.0
  and this can be simplified then.
- Resource limits are cgroup settings on the units, written by
  `insforge-render-env` from the `*_MEMORY` / `*_CPUS` values that
  `auto-scale-memory.sh` puts in `.env` — not `PodmanArgs`. This buys
  `MemoryHigh` (throttle before the OOM killer), which compose could not express.
- `insforge-render-env` runs on every `insforge-ctl restart`, so appending a
  key to `.env` and restarting behaves the way it did under compose.
