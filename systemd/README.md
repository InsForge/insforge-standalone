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

## What the image has to provide

These units are not self-contained — they assume the host image already has
certain things, and each assumption has bitten once. The bake script lives in
insforge-cloud-backend (`config/ami/ubuntu-bake.sh`) because the AMI is only
consumed by that control plane, so this is the contract it has to satisfy:

| Requirement | Why |
|---|---|
| podman ≥ 4.9 with quadlet | These are quadlet `.container` files; quadlet is what generates the units |
| `overlay` storage driver, not `fuse-overlayfs` | fuse-overlayfs adds a userspace daemon per layer stack — the exact overhead this migration exists to remove |
| `postgresql-client` major **16** | `insforge-ctl psql`/`pg_dump` run on the host against the container. pg_dump 17+ emits settings a 15 server rejects, so the client major is pinned deliberately |
| AWS CLI v2 **and** `unzip` | The S3 backup/restore helpers and the SSM-association wait shell out to `aws`. Provisioning installs the CLI if absent, and needs unzip to unpack it — an image with neither killed provisioning three times |
| SSM agent from the **deb**, not snap | Removing the snap agent kills the process executing the user-data script, so the swap only works at bake time |
| `systemd-zram-generator`, `zram-size = ram` | Swap is how a nano survives; installing the generator creates zram0 at ram/2 immediately and the config only takes effect on the next boot |
| `iptables` (the iptables-nft front end Ubuntu ships) | `../insforge-imds-guard` pins one raw-table rule that keeps the Postgres container off the instance metadata service; `insforge-ctl up`/`restart` install and enable it on every run, and without the binary the rule is silently absent |

Anything the units or `insforge-ctl` start depending on has to be added there
and asserted in that script's post-boot checklist, not discovered at 20 seconds
into a provision with the instance already terminated by the rollback.

## Other things worth knowing before editing these

- Quadlet-generated units **cannot** be `systemctl enable`d ("transient or
  generated"). Boot start comes from `[Install] WantedBy=` inside the
  `.container` file, which quadlet honours at generation time.
- podman 4.9 (what Ubuntu 24.04 ships) has no `Notify=healthy`, so dependent
  units gate on the database with an `ExecStartPre` `pg_isready` loop rather
  than on the container's health status. `Notify=healthy` lands in podman 5.0
  and this can be simplified then.
- Resource limits are cgroup settings on the units, written by
  `insforge-render-env` from the `*_MEMORY` values that `auto-scale-memory.sh`
  puts in `.env` — not `PodmanArgs`. This buys `MemoryHigh` (throttle before the
  OOM killer), which compose could not express. **Memory only: no `CPUQuota`.**
  `auto-scale-memory.sh` strips `*_CPUS`, so any default quota would always be
  the one in force, and a percentage cap on a nano is invisible at idle and
  crippling under load — the hardest kind of regression to attribute later.
- `insforge-render-env` runs on every `insforge-ctl restart`, so appending a
  key to `.env` and restarting behaves the way it did under compose.
- `sync_units` also refreshes `/usr/local/bin/insforge-ctl` from the checkout,
  because the elevated process *is* that copy — without it, a fix to this script
  delivered by `git pull` would never run on an existing instance. Note the
  bootstrap: the refresh can only happen from a version that already contains it,
  so an instance whose installed copy predates this stays on the old one until it
  is replaced. That is fine today because no instance is on podman in production
  yet; every one will be provisioned with this version by `podman.sh`.
- `insforge-postgres.container` is installed `0600`, not `0644` like the other
  units: `app.encryption_key` is a server start parameter, so it cannot come
  from an `EnvironmentFile` and ends up on the unit's `Exec` line.
- `insforge-ctl` installs these files as root from a checkout `ec2-user` can
  write, and then executes `insforge-render-env` as root. Worth naming, but it is
  not a boundary being crossed: SSM runs commands as root and the control plane
  drops to `ec2-user` by choice, so anything that can act as `ec2-user` on a
  project instance is already root. Note this also means the root-owned copy at
  `/usr/local/bin` is not a protection — `sync_units` overwrites it from the
  checkout on every restart. Its purpose is a stable path for one sudoers rule,
  not immutability.
- `sync_units` therefore **warns** about uncommitted changes under `systemd/` or
  `insforge-ctl` and installs them anyway. Refusing would be worse than what it
  prevents: `sync_units` is what makes a version bump take effect, its callers do
  not check its status, so a refusal would silently skip the sync — and making it
  fatal would break every restart on an instance someone hand-patched during an
  incident. The warning reaches the SSM output and the journal, which is what
  makes an unexpected edit visible.
