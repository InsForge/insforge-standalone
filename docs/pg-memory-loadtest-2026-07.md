# Why the nano Postgres memory settings matter — load-test evidence (2026-07)

## TL;DR

The tuned `docker-init/db/postgresql.conf` (shared_buffers 32MB, RAM-scaled
`max_connections`, maintenance_work_mem 16MB — introduced 2026-02, connection
scaling refined in #98) is **load-test verified** on a 512MB nano instance.
Under a 90-connection storm, stock Postgres defaults (`shared_buffers=128MB`,
`max_connections=100`) inside a ~150MB container limit get the DB
**OOM-killed** — restart, 11 TPS, 6s+ average latency, clients hung for
minutes. The tuned config **fails fast and stays healthy**: excess clients
get `FATAL: sorry, too many clients already`, memory stays bounded, zero OOM
events, and the API on the same host keeps serving.

If you deploy this stack on a small instance, keep the shipped
`postgresql.conf` — and if a host was provisioned before the tuning landed,
re-copy the current conf and restart the postgres container to pick it up
(the file is bind-mounted from the host and does not update itself).

## Test setup

- t4g.nano-class host (~418MB usable RAM, zram swap) running this compose
  stack (postgres + postgrest + API), dedicated throwaway project.
- Old conf (no memory settings → stock defaults) vs current repo conf,
  swapped on the same box with a postgres restart in between; identical
  pgbench workloads; container memory tracked via cgroup v2
  (`memory.current` / `memory.peak` / `memory.events`).

## Results

### 1. Moderate load — pgbench scale 5, 20 clients, 60s

| | Stock defaults | Tuned conf |
|---|---|---|
| TPS / avg latency | 546 / 36ms | 523 / 38ms |
| Container swap during run | ~50MB | ~20MB |
| Host available floor | 78MB | 111MB |
| OOM kills | 0 | 0 |

At light load the configs are equivalent (shared_buffers is allocated
lazily); the defaults just swap more.

### 2. Heavy load — pgbench scale 20 (dataset ~320MB > RAM), 50 clients, 60s

| | Stock defaults | Tuned conf |
|---|---|---|
| TPS / avg latency | 452 / 106ms | 489 / 99ms |
| Postgres memory peak | **pinned at the memcg ceiling** | 155MB, below ceiling |
| Container swap during run | 110–127MB | 51–62MB |
| Host available floor | **47MB** | ~90MB |
| Swap left after the run | ~100MB stuck | drains back |
| OOM kills | 0 (zram absorbed it) | 0 |

Tuned = +8% throughput, half the swap traffic, ~2x host headroom, and the
host recovers after the burst instead of staying half-swapped.

### 3. Connection storm — pgbench scale 20, 90 clients, 60s

| | Stock defaults (accepts all 90) | Tuned (caps connections) |
|---|---|---|
| Outcome | **Postgres OOM-killed at t≈45s** (`oom_kill=1`, `OOMKilled=true`), Docker restarts the DB | Excess clients rejected instantly; DB healthy throughout |
| TPS / avg latency | **11 TPS / 6,063ms**, clients hung >12 min | fail-fast; memory stayed 26–50MB |
| OOM kills | 1 | 0 |

This is the difference between a project that *goes down* under a
connection burst (DB killed mid-flight, hung connections, 5xx at the
gateway until restart) and one that sheds load gracefully.

### 4. Combined stress (tuned) — pgbench 40 clients + VACUUM ANALYZE + API traffic

459 TPS / 85ms; API health checks during the storm: 3,597 OK / 3 failed /
3 over 1s; Postgres peak 134MB, 0 OOM events. A tuned nano survives DB
saturation + vacuum + HTTP traffic simultaneously with the API responsive.

## Follow-up candidates

- The API image CMD ends in `exec npm start`, leaving two resident npm
  wrapper processes (`npm start` → `npm run start` → node). Exec'ing node
  directly after the migrate step frees ~20–40MB RSS on a 512MB host and
  improves signal handling.
- `vm.swappiness` ~150 on zram-swap hosts (observed lzo-rle compression
  ~3.4x): prefer cheap compressed-RAM swap over reclaim stalls.
- `"userland-proxy": false` in daemon.json drops one docker-proxy process
  per published port.
