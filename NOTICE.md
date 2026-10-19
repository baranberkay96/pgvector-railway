# NOTICE

This Railway template is a community package. It is not affiliated with or endorsed by the PostgreSQL Global Development Group, the pgvector project, the PgBouncer project or Railway.

## What this template runs

| Component | Source | License |
|---|---|---|
| PostgreSQL 18 | inside `ghcr.io/railwayapp-templates/postgres-ssl:18` (built `FROM postgres:{18.x}-trixie`, PGDG packages) | PostgreSQL License |
| pgvector 0.8 | `postgresql-18-pgvector=0.8.*` from PGDG, installed by Railway's image | PostgreSQL License (Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group; Portions Copyright (c) 1994, The Regents of the University of California) |
| Railway Postgres image (TLS, `wrapper.sh`, tini, pgBackRest hooks) | `ghcr.io/railwayapp-templates/postgres-ssl:18`, from https://github.com/railwayapp-templates/postgres-ssl, used unmodified | MIT, Copyright (c) 2023 Railway |
| PgBouncer 1.26.1 | inside `edoburu/pgbouncer:v1.26.1-p0` (compiled from the official release tarball) | ISC License (PgBouncer) |
| PgBouncer container image and entrypoint | `edoburu/pgbouncer:v1.26.1-p0`, from https://github.com/edoburu/docker-pgbouncer (commit `f0b69975`, "Bump pgbouncer to v1.26.1"), used unmodified | MIT, Copyright (c) 2019 Diederik van der Boor |
| Backup image base | `alpine:3.24.2` with Alpine packages `postgresql18-client` (PostgreSQL License), `rclone` (MIT), `bash` and `coreutils` (GPL-3.0-or-later), `ca-certificates`, installed at build time from the Alpine repositories | per package |

## Files written for this template

- `services/postgres/pgvector-tune.sh` and `services/postgres/to-start-command.py`: the Postgres start command (readable source and the generator that joins it into `template.json`). It re-invokes the Railway image's own entrypoint chain (`/usr/bin/tini -g -- /usr/local/bin/wrapper.sh postgres -p 5432 -c listen_addresses=*`, as declared in the image config); no file from the image or its repository is copied.
- `services/backup/Dockerfile` and `services/backup/pgvector-backup.sh`: the backup job.
- `TEMPLATE.md`, `README.md`, `template.json`, this file.

## Reused or not reused

- `railwayapp-templates/postgres-s3-backups` has **no license** (GitHub reports none; no LICENSE file), so it was neither referenced as a service source nor copied. It also targets a single database with a PostgreSQL 16 client by default and has no retention. The backup job here is written from scratch from the PostgreSQL and rclone documentation.
- `railwayapp-templates/pgbouncer` (MIT, a fork of edoburu/docker-pgbouncer) was read for Railway's defaults (`listen_addr = *` for IPv6, `auth_type = scram-sha-256`). The template applies them as variables on the upstream edoburu image instead, because Railway's image is still on PgBouncer 1.25.2 (CVE-2026-19888, CVE-2026-6668, CVE-2026-107350 fixed in 1.26.0/1.26.1).
- The three marketplace templates in `_market/` (`3jJFCA`, `postgres-with-pgvector-engine`, `qcuy_M`) carry no license; they were read for their settings only. No README or description text from them is reused.

## Upstream material checked (2026-10-20)

- `railwayapp-templates/postgres-ssl` at commit `0297f79e` (2026-10-09): `Dockerfile.18` (pgvector `0.8.*`, tini ENTRYPOINT, CMD), `wrapper.sh` (volume path check, `pg_stat_statements` preload, `max_connections = 500` in `postgresql.auto.conf`, `conf.d` handling for PITR), `init-ssl.sh` (certificate SAN `localhost` + private domain), README (PITR env contract, ports, base distro). Published image `postgres-ssl:18`: created 2026-10-09T15:36Z, `PG_VERSION=18.6-1.pgdg13+2`, linux/amd64 + linux/arm64.
- `pgvector/pgvector` v0.8.7 (`vector.control` default_version 0.8.7, CHANGELOG 2026-10-01): README sections Index Build Time, Tuning, Querying, Docker (`--shm-size` ≥ `maintenance_work_mem` for parallel HNSW builds); `src/hnswbuild.c` (parallel builds size the shared graph area from `maintenance_work_mem`). PGDG `trixie-pgdg` has `postgresql-18-pgvector 0.8.7-1.pgdg13+1` (pool upload 2026-10-02).
- PgBouncer releases 1.26.0 (2026-09-23) and 1.26.1 (2026-10-14) release notes; `edoburu/docker-pgbouncer` `Dockerfile` and `entrypoint.sh` at `f0b69975`; image `edoburu/pgbouncer:v1.26.1-p0` (created 2026-10-19, user `postgres`, linux/amd64 + linux/arm64).
- Alpine 3.24 `APKINDEX` (main: `postgresql18-client 18.6-r0` linked against libzstd and liblz4; community: `rclone 1.74.1-r3`) and aports `postgresql18/APKBUILD` (client binaries under `/usr/libexec/postgresql18`).
- Railway documentation: PostgreSQL Connection Pooling, `railway postgres` CLI (PITR/HA need the official image on a major tag and no custom start command), Storage Buckets (virtual-hosted URLs, no lifecycle rules, upload traffic counts as service egress), Cron Jobs and `railway cron`, Volumes (size limits, 3,000 IOPS), Start Command (overrides the image ENTRYPOINT). Central Station threads on `RAILWAY_SHM_SIZE_BYTES` (Railway staff, 2024-10 and 2024-11).
