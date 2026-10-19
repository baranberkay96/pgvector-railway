# Postgres 18 + pgvector Vector Database: Railway template spec

## Listing

| Field | Value |
|---|---|
| Name | **Postgres 18 + pgvector Vector Database** (`18` = PostgreSQL major of the pinned `postgres-ssl:18` image, currently 18.6; pgvector 0.8 inside) |
| Description | Drop-in Postgres with pgvector, pooling and backups for RAG and embeddings. (75 chars) |
| Category | Storage |
| Tags | postgres, postgresql, pgvector, vector-database, embeddings, rag, pgbouncer, backups |
| Icon | `https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/postgresql.svg` (200, image/svg+xml) |

The listing is delivered as written: "drop-in" = the same service name and variables as Railway's own Postgres (`DATABASE_URL`, `DATABASE_PUBLIC_URL`, `PG*`), "pooling" = the PgBouncer service (`DATABASE_POOL_URL`), "backups" = the daily `pg_dump` cron job to a Railway Bucket with retention.

## Base market templates

| Market template | Topology | Kept | Problems fixed |
|---|---|---|---|
| `3jJFCA` "pgvector" (941 active, leader) | one service `pgvector/pgvector:pg18`, TCP proxy, volume at `/var/lib/postgresql` | **Base for the offer**: PG 18, pgvector, public TCP proxy, generated password | Service named `pgvector`, so `${{Postgres.DATABASE_URL}}` references from other templates and guides break; `DATABASE_URL` points at the **public** proxy (egress-billed) and the private URL hides in `DATABASE_URL_PRIVATE`; no TLS (stock image); `vector` must be created by hand; default 128 MB `shared_buffers` and 64 MB `maintenance_work_mem`; 64 MB `/dev/shm`, so parallel HNSW builds fail; no pooler, no backups; floating `pg18` tag outside Railway's Postgres tooling |
| `postgres-with-pgvector-engine` (80 active) | same as the leader plus an HTTP domain on 5432 | Nothing beyond the leader | Same issues; the HTTP domain on a Postgres port does nothing useful; `ON_FAILURE` restarts |
| `qcuy_M` "pgvector-pg17" (165 active) | `pgvector/pgvector:pg17`, Railway-style `DATABASE_URL` (private) + `DATABASE_PUBLIC_URL` | Variable layout (private `DATABASE_URL`, public `DATABASE_PUBLIC_URL`) | PG 17; no TLS, tuning, pooler or backups; volume at `/var/lib/postgresql/data/` with `PGDATA` inside it |

Upstream used for everything else: `_upstream/railwayapp-templates__postgres-ssl` (MIT; `Dockerfile.18`, `wrapper.sh`, `init-ssl.sh`, README) and `_upstream/pgvector__pgvector` (PostgreSQL License; v0.8.7 README, CHANGELOG, `src/hnswbuild.c`). No market README text was reused.

## Pinned versions

| Service | Image / build | Version | Released | Checked |
|---|---|---|---|---|
| Postgres | `ghcr.io/railwayapp-templates/postgres-ssl:18` | PostgreSQL 18.6 (`PG_VERSION=18.6-1.pgdg13+2`), pgvector `0.8.*` from PGDG (0.8.7 in PGDG since 2026-10-02) | image built 2026-10-09 | 2026-10-20 |
| PgBouncer | `edoburu/pgbouncer:v1.26.1-p0` (amd64 + arm64) | PgBouncer 1.26.1 | 2026-10-19 (release 2026-10-14) | 2026-10-20 |
| Postgres Backup | repo `baranberkay96/pgvector-railway`, `/services/backup` (Dockerfile `FROM alpine:3.24.2`) | `postgresql18-client` 18.6-r0, `rclone` 1.74.1-r3 (Alpine 3.24) | alpine 3.24.2: 2026-09-18 | 2026-10-20 |

- **Why `:18` and not `18.6`:** Railway's PITR and HA tooling require an official Railway Postgres image on a *major* tag (Railway CLI docs: minor tags are not supported). The tag is rebuilt by Railway with security and minor updates; extension packages are pinned at the minor (`0.8.*`) by Railway.
- **Why edoburu and not `ghcr.io/railwayapp-templates/pgbouncer`:** Railway's own PgBouncer image (MIT, a fork of edoburu) is still on 1.25.2, which is affected by CVE-2026-19888, CVE-2026-6668 and CVE-2026-107350 (fixed in 1.26.0/1.26.1). The template uses the upstream image at 1.26.1 and sets Railway's two defaults (`LISTEN_ADDR=*`, `AUTH_TYPE=scram-sha-256`) as variables.
- **Upgrade:** Postgres minor/security updates arrive with a redeploy; after a pgvector minor bump run `ALTER EXTENSION vector UPDATE;` in each database. PgBouncer: change the tag. Backup: bump `alpine` and `postgresql18-client` in the Dockerfile. A Postgres **major** upgrade (19) needs the backup client bumped in the same change (the job refuses to dump a newer server).

## Architecture

```
 Apps on Railway ── DATABASE_POOL_URL ──► PgBouncer :6432 (private, transaction pooling, SCRAM)
                                               │
 Migrations / index builds ── DATABASE_URL ──► │
                                               ▼
                                  Postgres :5432 ── volume /var/lib/postgresql/data
 External clients ── DATABASE_PUBLIC_URL ──►  postgres-ssl:18 (TLS, pgvector, pg_stat_statements)
   (TCP proxy, sslmode=require)               start command: size memory/parallelism from cgroup limits
                                               ▲
 Postgres Backup (cron 03:15 UTC) ─────────────┘ pg_dumpall -g + pg_dump -Fc per database
        │ rclone rcat (stream, no temp files)
        ▼
 Bucket (Railway Bucket, private S3): postgres/{UTC timestamp}/globals.sql, {db}.dump, MANIFEST.txt
```

## Services

### Postgres

| Setting | Value |
|---|---|
| Source | image `ghcr.io/railwayapp-templates/postgres-ssl:18` (Railway base definition from `_railway-base/postgres.json`) |
| Start command | `/usr/bin/tini -g -- /bin/bash -c '{tuning script}' pgvector-start postgres -p 5432 -c listen_addresses=*` (2,604 chars; readable source: `services/postgres/pgvector-tune.sh`, regenerate with `services/postgres/to-start-command.py`) |
| Volume | `/var/lib/postgresql/data` (required by the image's `wrapper.sh`), `PGDATA=/var/lib/postgresql/data/pgdata` |
| Networking | private `postgres.railway.internal:5432`; **TCP proxy on 5432** for `DATABASE_PUBLIC_URL` |
| Healthcheck | none (not HTTP; Railway marks the deploy live when the container runs) |
| Restart | ON_FAILURE, 10 retries (the wrapper exits non-zero when Postgres stops unasked) |

The start command is the image's own `ENTRYPOINT` + `CMD` (`tini -g -- wrapper.sh postgres -p 5432 -c listen_addresses=*`) with a bash step in between. At every boot it:

1. Writes `/docker-entrypoint-initdb.d/zz-pgvector-extensions.sql` (`CREATE EXTENSION IF NOT EXISTS vector; ... pg_stat_statements;`). The official entrypoint runs it only when it initializes a new data directory, in `POSTGRES_DB`, so the extensions exist on first boot and are never touched again.
2. Reads the **container** limits, not the host: `/sys/fs/cgroup/memory.max` (bounded by `MemTotal`), `/sys/fs/cgroup/cpu.max` (bounded by `nproc`) and the size of `/dev/shm`.
3. Writes `$PGDATA/pgvector-tuning.conf` and appends `include_if_exists = pgvector-tuning.conf` to `postgresql.conf` once (on the first boot through an initdb hook, because `PGDATA` does not exist yet). `postgresql.auto.conf` is read after it, so **`ALTER SYSTEM` always wins**, and a missing file never blocks startup. Railway's own settings (`ssl`, `shared_preload_libraries = pg_stat_statements`, `max_connections = 500` in `postgresql.auto.conf`) are untouched.
4. Logs one line, e.g. `pgvector-tune: ... budget 8192MB (container 49152MB), 8 cpus, /dev/shm 1024MB ... shared_buffers = 2048MB ...`, then `exec`s `wrapper.sh` (SSL certificates, volume lock, PITR hooks and upgrades stay Railway's).

**Tuning rules** (B = memory budget in MB, C = CPUs, S = `/dev/shm` MB):

| Setting | Rule | 1 GB, 2 vCPU, shm 64 MB | 4 GB, 2 vCPU, shm 1 GiB | plan limit 48 GB, 48 vCPU, shm 1 GiB |
|---|---|---|---|---|
| budget B | `PG_MEMORY_LIMIT_MB`, else container limit capped at 8192 | 1024 | 4096 | 8192 |
| CPUs C | `PG_CPU_LIMIT`, else cgroup quota capped at 8 | 2 | 2 | 8 |
| `shared_buffers` | B/4 (min 128 MB) | 256MB | 1024MB | 2048MB |
| `effective_cache_size` | 3B/4 | 768MB | 3072MB | 6144MB |
| `maintenance_work_mem` | B/4, 64–2048 MB; with parallel builds at most 3S/4 | 256MB | 768MB | 768MB |
| `max_parallel_maintenance_workers` | min(C-1, 4); 0 if 3S/4 < 128 MB | 0 | 1 | 4 |
| `max_parallel_workers` / `_per_gather` | max(C,2) / min(C/2, 2), per-gather 0 if S < 256 MB | 2 / 0 | 2 / 1 | 8 / 2 |
| `max_worker_processes` | max(8, workers + 4) | 8 | 8 | 12 |
| `autovacuum_work_mem` | B/16, 64 MB to `maintenance_work_mem` | 64MB | 256MB | 512MB |
| `work_mem` | B/512, 4–64 MB | 4MB | 8MB | 16MB |
| fixed | `random_page_cost = 1.1`, `effective_io_concurrency = 200`, `track_io_timing = on` | | | |

Why: pgvector builds HNSW indexes much faster when the graph fits in `maintenance_work_mem`, and a **parallel** build allocates that whole amount as dynamic shared memory in `/dev/shm` (`hnswbuild.c`; pgvector's README asks for `--shm-size` ≥ `maintenance_work_mem`). Railway's default `/dev/shm` is 64 MB, which is why parallel builds and parallel queries fail there with `could not resize shared memory segment`. The template sets `RAILWAY_SHM_SIZE_BYTES=1073741824` (1 GiB) and caps `maintenance_work_mem` at 3/4 of `/dev/shm` while parallel builds are on; if `/dev/shm` is small it switches parallel builds off instead, so a serial build can still use the full `maintenance_work_mem`. The 8 GB auto cap stops a large limit (the cgroup limit can be the plan's per-service maximum rather than what the database needs) from sizing caches for RAM the database never uses; raise it with `PG_MEMORY_LIMIT_MB`.

Extra variables on top of Railway's base Postgres (all optional):

| Variable | Default | Purpose |
|---|---|---|
| `DATABASE_PUBLIC_URL` | `postgresql://...@${{RAILWAY_TCP_PROXY_DOMAIN}}:${{RAILWAY_TCP_PROXY_PORT}}/...` | External connections via the TCP proxy |
| `DATABASE_POOL_URL` | `${{PgBouncer.DATABASE_POOL_URL}}` | Pooled URL next to the other connection strings |
| `RAILWAY_SHM_SIZE_BYTES` | `1073741824` | `/dev/shm` size (Railway service variable; confirmed by Railway staff on Central Station, not in the docs) |
| `PGVECTOR_TUNING` | `auto` | `off` deletes `pgvector-tuning.conf` at the next boot |
| `PG_MEMORY_LIMIT_MB` | `auto` | Budget override in MB |
| `PG_CPU_LIMIT` | `auto` | CPU override |

### PgBouncer

| Setting | Value |
|---|---|
| Source | image `edoburu/pgbouncer:v1.26.1-p0` (config generated from variables by the image's entrypoint) |
| Networking | private only, `pgbouncer.railway.internal:6432`, `listen_addr = *` (IPv4 + IPv6) |
| Healthcheck | none (TCP service) |
| Restart | ALWAYS (starts before Postgres is ready; connects lazily) |

- `[databases] * = host=${{Postgres.RAILWAY_PRIVATE_DOMAIN}} port=5432 auth_user=postgres`: a wildcard entry, so every database on the server is reachable through the pool. The superuser is written to the userlist (plain text, needed for SCRAM); other roles log in through PgBouncer's default `auth_query` run as that user.
- `pool_mode = transaction`, `max_client_conn = 1000`, `default_pool_size = 20`, `max_prepared_statements = 200` (protocol-level prepared statements work in transaction mode), `auth_type = scram-sha-256`, admin console for `postgres` (`psql {DATABASE_POOL_URL with /pgbouncer} -c "SHOW POOLS"`).
- No client TLS (traffic stays on Railway's private network): do not add `sslmode=require` to `DATABASE_POOL_URL`.
- Do not also enable Railway's built-in Connection Pooling (Database → Config): it adds a second PgBouncer and rewires `DATABASE_URL` to it. Pick one.

### Postgres Backup

| Setting | Value |
|---|---|
| Source | repo `baranberkay96/pgvector-railway`, root directory `/services/backup` (Dockerfile, non-root user) |
| Cron | `15 3 * * *` (daily 03:15 UTC; Railway skips a run while the previous one is still active) |
| Restart | NEVER (each run exits; failures show as `CRASHED` in Cron Runs) |
| Volume / networking | none |

Each run (`services/backup/pgvector-backup.sh`):

1. Validates its settings, waits up to `BACKUP_WAIT_SECONDS` for Postgres, refuses to run if the server major is newer than its `pg_dump` (18).
2. Streams `pg_dumpall --globals-only` (roles, tablespaces) and one `pg_dump --format=custom --compress=zstd:3 --lock-wait-timeout=10min` per database (all databases that accept connections, or `BACKUP_DATABASES`) to `{BACKUP_PREFIX}/{UTC timestamp}/` in the Bucket with `rclone rcat`. Nothing is written to local disk.
3. Re-reads each dump from the Bucket through `pg_restore --list` (header and table of contents), logs its size, then writes `MANIFEST.txt` last. A run without `MANIFEST.txt` is incomplete.
4. Retention: deletes complete runs older than `BACKUP_RETENTION_DAYS` (14) but always keeps the newest `BACKUP_KEEP_MIN` (3) complete runs; deletes incomplete runs older than 2 days; ignores folders that are not run timestamps. A failed run deletes nothing.

Run it on demand: `railway cron run --service "Postgres Backup"` (or the service's Cron Runs tab). List runs: the Bucket's Files tab.

### Bucket

Railway Bucket named `Bucket` (private, S3-compatible, virtual-hosted URLs). The backup job references `BUCKET`, `ENDPOINT`, `REGION`, `ACCESS_KEY_ID` and `SECRET_ACCESS_KEY`. Buckets have no lifecycle rules or versioning, which is why retention lives in the job.

## Connecting

| From | Variable | TLS |
|---|---|---|
| Railway services, app queries | `${{Postgres.DATABASE_POOL_URL}}` | none needed (private network); not supported by PgBouncer here |
| Railway services, migrations / `CREATE INDEX` / `LISTEN` / advisory locks / session `SET` | `${{Postgres.DATABASE_URL}}` | available (`sslmode=prefer` default); cert SAN includes `postgres.railway.internal` |
| Outside Railway | `DATABASE_PUBLIC_URL` (TCP proxy) | use `sslmode=require`. The certificate is signed by the image's own CA (`/var/lib/postgresql/data/certs/root.crt`), so `verify-full` fails on the proxy hostname; `verify-ca` works with that file. node-postgres treats `sslmode=require` as `verify-full`: use `ssl: { rejectUnauthorized: false }` or `uselibpqcompat=true&sslmode=require`. |

The TCP proxy is on by default because `DATABASE_PUBLIC_URL` is part of the drop-in contract and the leading market template exposes one. It only accepts SCRAM password logins with the generated 32-character password. For a private-only database, delete the proxy under Postgres → Settings → Networking (then `DATABASE_PUBLIC_URL` no longer resolves). TCP proxy traffic is billed as egress.

With transaction pooling, session settings do not stick between transactions: use `SET LOCAL hnsw.ef_search = 100` inside a transaction, or a default with `ALTER DATABASE railway SET hnsw.ef_search = 100`. Prisma needs `?pgbouncer=true` on the pooled URL.

## Restore

1. Bucket → Files → `postgres/{timestamp}/`, download `{database}.dump` (and `globals.sql` if you need roles). `MANIFEST.txt` lists the files.
2. With a PostgreSQL 18 client: `pg_restore --clean --if-exists --no-owner --dbname "{DATABASE_PUBLIC_URL}?sslmode=require" railway.dump`. For a fresh server, `pg_restore --create --dbname "{url to the postgres database}" app.dump` recreates a database.
3. `globals.sql` contains every role with its password hash, including `postgres`: remove the `postgres` lines before replaying it, or the superuser password no longer matches `POSTGRES_PASSWORD`.

Railway's own volume backups (Postgres → Backups) and managed PITR are complementary; see Open questions for PITR.

## Required input

None. Every credential is generated (`secret()`) or referenced; the Bucket is created by the template.

## First connection

1. Open Postgres → Variables, copy `DATABASE_PUBLIC_URL`, connect: `psql "{DATABASE_PUBLIC_URL}?sslmode=require"`.
2. `SELECT extname, extversion FROM pg_extension;` shows `vector` and `pg_stat_statements`.
3. `SHOW shared_buffers; SHOW maintenance_work_mem;` match the `pgvector-tune:` line in the deploy log.
4. From another Railway service, reference `${{Postgres.DATABASE_POOL_URL}}` (queries) and `${{Postgres.DATABASE_URL}}` (migrations).

## Improvements over market templates

1. **Drop-in Railway Postgres**: service `Postgres`, Railway's `postgres-ssl:18` image and base variables (`DATABASE_URL` private, `DATABASE_PUBLIC_URL`, `PG*`), so the Data panel, volume backups and guides that reference `${{Postgres.*}}` work. The market leader names the service `pgvector` and points `DATABASE_URL` at the public proxy.
2. **TLS** on every connection that leaves Railway (market templates run the stock image without SSL).
3. **`vector` and `pg_stat_statements` created on first boot** in `POSTGRES_DB` (market: manual `CREATE EXTENSION`).
4. **Vector-workload tuning from the container limits**, not the host's RAM and cores: `shared_buffers`, `effective_cache_size`, `maintenance_work_mem` and parallel HNSW build workers sized per boot, `/dev/shm` raised to 1 GiB so parallel index builds and parallel queries do not fail, `track_io_timing`, SSD planner costs. `ALTER SYSTEM` still overrides everything.
5. **PgBouncer 1.26.1** (transaction pooling, SCRAM, prepared statements, IPv6) as a private service with `DATABASE_POOL_URL` (no market template has a pooler).
6. **Daily verified backups** to a Railway Bucket: all databases plus roles, zstd custom-format dumps, `pg_restore --list` check, manifest, age + minimum-count retention (no market template backs up).
7. Pinned versions (Postgres major tag required by Railway PITR/HA, PgBouncer 1.26.1, Alpine 3.24.2), descriptions on every variable, no required input.

## Resource estimate

Railway prices: RAM $10/GB-month, vCPU $20/vCPU-month, volume $0.15/GB-month, Bucket $0.015/GB-month, egress $0.05/GB (uploads to a Bucket count as service egress). Not measured (no local container run this round); based on Postgres/PgBouncer footprints and the tuning above.

| Service | Idle RAM / CPU | Typical RAM / CPU | Notes |
|---|---|---|---|
| Postgres | 0.1 GB / 0.01 | 1.0 GB / 0.2 | `shared_buffers` (up to 2 GB at the default budget) fills only as data is read; HNSW builds add up to `maintenance_work_mem` while they run |
| PgBouncer | 0.01 GB / ~0 | 0.02 GB / 0.01 | |
| Postgres Backup | 0 between runs | ~0.1 GB / 0.5 vCPU for a few minutes a day | < $0.10/month |
| Volume | 0.2 GB | 3 GB | Hobby volumes start at 5 GB, Pro at 50 GB (resizable) |
| Bucket | ~0 | ~10 GB (14 daily dumps; indexes are not dumped) | + ~20 GB/month upload egress for a 0.7 GB dump |

Estimated monthly cost: **idle ≈ $1.5** (0.11 GB × $10 + 0.01 vCPU × $20 + 0.2 GB × $0.15), **typical ≈ $16** (1.02 GB × $10 + 0.21 vCPU × $20 + 3 GB × $0.15 + 10 GB × $0.015 + 21 GB × $0.05).

Minimum plan: **Trial** boots it (1 GB RAM per service, 0.5 GB volumes); **Hobby** recommended for real data (5 GB volume, enough RAM for index builds).

## Verification checklist

Static checks done this round: see `_reports/round4/56-pgvector.md`. On the first Railway deploy:

- [ ] All three services deploy; the Backup image builds (Dockerfile `RUN` check prints no error).
- [ ] Postgres log shows `pgvector-tune: ...` with plausible `container`/`cpus`/`/dev/shm` numbers (expect `/dev/shm 1024MB`; 64 MB means `RAILWAY_SHM_SIZE_BYTES` is ignored) and Railway's SSL/init lines, then `database system is ready`.
- [ ] `psql "{DATABASE_PUBLIC_URL}?sslmode=require"`: `SELECT extversion FROM pg_extension WHERE extname='vector'` → 0.8.x (expect 0.8.7); `SHOW ssl` → on; `SHOW shared_buffers` matches the log; `SHOW config_file` and `SELECT sourcefile FROM pg_settings WHERE name='shared_buffers'` → `.../pgvector-tuning.conf`.
- [ ] `ALTER SYSTEM SET work_mem = '32MB'; SELECT pg_reload_conf(); SHOW work_mem;` → 32MB (auto.conf overrides the tuning file).
- [ ] HNSW smoke test: `CREATE TABLE items (id bigserial primary key, embedding vector(3)); INSERT INTO items (embedding) SELECT ARRAY[random(),random(),random()]::vector FROM generate_series(1,100000); CREATE INDEX ON items USING hnsw (embedding vector_l2_ops);` completes without `could not resize shared memory segment`.
- [ ] From a Railway shell or service: `psql "$DATABASE_POOL_URL" -c "select 1"` works; `psql ".../pgbouncer" -c "SHOW POOLS"` lists the pool.
- [ ] `railway cron run --service "Postgres Backup"` → run `EXITED`; Bucket shows `postgres/{timestamp}/globals.sql`, `railway.dump`, `postgres.dump`, `MANIFEST.txt`; download `railway.dump`, `pg_restore --list railway.dump` works.
- [ ] Redeploy Postgres: data and extensions still there; `pgvector-tuning.conf` rewritten; `postgresql.conf` still has exactly one `include_if_exists` line.

## Open questions

- **Start command length (2,604 chars)**: longer than any start command deploy-tested in this repo so far (1,231). If Railway rejects or mangles it, clear the start command: Postgres then runs as plain Railway Postgres (no tuning, `CREATE EXTENSION vector` by hand) and everything else keeps working.
- **PITR / HA**: Railway's CLI docs say to clear any custom start command before enabling PITR or converting to HA. After clearing it, `pgvector-tuning.conf` stays on the volume with the last computed values (static from then on). `_tools/to_serialized.py` does not copy the base definition's `haTemplateCode`/`haConversionConfig`, so whether the dashboard's HA button appears is unverified.
- **`RAILWAY_SHM_SIZE_BYTES`** is not in Railway's docs (staff answers on Central Station, 2024). The tuning reads the real `/dev/shm` size and degrades safely (serial builds, no parallel queries) if the variable is ignored.
- **cgroup values on Railway**: `memory.max` may be the plan's per-service maximum. The 8 GB auto cap and `PG_MEMORY_LIMIT_MB` cover it; the deploy log shows what was detected.
- **pgvector version** inside `postgres-ssl:18` is inferred (Railway pins `0.8.*`, PGDG had 0.8.7 a week before the image build); confirm with `SELECT extversion`.
- **Backups and big databases**: dumps are streamed in 16 MiB parts (up to ~150 GiB per database). Upload traffic is billed as egress. Restores need a PostgreSQL 18 `pg_restore`.
- **PgBouncer search_path tracking**: 1.26 tracks `search_path` by default and upstream lists open bugs around it; add `search_path` to `IGNORE_STARTUP_PARAMETERS` if an app misbehaves through the pool.
