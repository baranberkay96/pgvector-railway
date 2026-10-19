# Deploy and Host pgvector with Railway

pgvector adds vector similarity search to PostgreSQL, so embeddings live next to the rest of your data and are queried with SQL. This community template runs PostgreSQL 18 with pgvector 0.8 on Railway's own Postgres image, with PgBouncer connection pooling and daily backups to a Railway Bucket.

## About Hosting pgvector

A production pgvector database needs more than the extension. Index builds are fast only when the HNSW graph fits in `maintenance_work_mem`, parallel builds need enough shared memory, many app instances need a connection pooler, and the data needs off-volume backups. This template keeps Railway's Postgres service layout and variables, so it is a drop-in replacement, and adds those pieces: the `vector` extension is created on first boot, memory and parallel workers are sized from the container's limits at every start, `/dev/shm` is raised for parallel index builds, PgBouncer pools connections in transaction mode, and a cron job writes verified `pg_dump` backups with retention.

## Common Use Cases

- Retrieval-augmented generation (RAG): store document chunks, metadata and embeddings in one database and retrieve with SQL filters
- Semantic search over products, tickets, docs or chat history with HNSW or IVFFlat indexes
- Recommendations and deduplication with cosine, inner product or L2 distance
- A vector store for frameworks such as LangChain, LlamaIndex, Mem0 or your own app, without a separate vector database
- A general-purpose Postgres 18 for an app that will add embeddings later

## Dependencies for pgvector Hosting

- PostgreSQL 18 with pgvector (included: `ghcr.io/railwayapp-templates/postgres-ssl:18`)
- PgBouncer for connection pooling (included: `edoburu/pgbouncer` 1.26.1)
- A Railway Bucket for backups (included, created by the template)

### Deployment Dependencies

- pgvector: https://github.com/pgvector/pgvector
- PostgreSQL 18 documentation: https://www.postgresql.org/docs/18/
- Railway Postgres image: https://github.com/railwayapp-templates/postgres-ssl
- PgBouncer documentation: https://www.pgbouncer.org/config.html
- Railway Storage Buckets: https://docs.railway.com/storage-buckets
- Railway cron jobs: https://docs.railway.com/cron-jobs

### Implementation Details

| Service | Image | Purpose |
|---|---|---|
| Postgres | `ghcr.io/railwayapp-templates/postgres-ssl:18` | PostgreSQL 18 + pgvector + pg_stat_statements, TLS, volume at `/var/lib/postgresql/data`, TCP proxy for external clients |
| PgBouncer | `edoburu/pgbouncer:v1.26.1-p0` | Transaction pooling on the private network (port 6432), SCRAM auth, prepared statements |
| Postgres Backup | built from this repo (`services/backup`) | Daily cron (03:15 UTC): roles + every database with `pg_dump`, verified, 14-day retention (minimum 3 runs kept) |
| Bucket | Railway Bucket | Private S3 storage for the backups |

**Connection strings** (on the Postgres service, reference them as `${{Postgres.NAME}}`):

- `DATABASE_POOL_URL`: pooled, for application queries from other Railway services
- `DATABASE_URL`: direct over the private network, for migrations, `CREATE INDEX`, `LISTEN/NOTIFY`, advisory locks and session settings
- `DATABASE_PUBLIC_URL`: from outside Railway through the TCP proxy; add `?sslmode=require` (the certificate is self-signed). Remove the TCP proxy in Settings → Networking if you want a private-only database.

**First steps**

1. Copy `DATABASE_PUBLIC_URL` from the Postgres service and connect: `psql "{DATABASE_PUBLIC_URL}?sslmode=require"`.
2. `SELECT extversion FROM pg_extension WHERE extname = 'vector';` confirms pgvector is ready.
3. Create a table and an index: `CREATE TABLE items (id bigserial PRIMARY KEY, embedding vector(1536));` then `CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops);`
4. Query with pgvector's cosine-distance operator (see "Querying" in the pgvector README): order by the distance between `embedding` and your query vector, with `LIMIT 10`.
5. Create a dedicated role for your app instead of using the `postgres` superuser.

**Tuning**: the start command writes `pgvector-tuning.conf` at every boot from the container's memory and CPU limits (auto budget capped at 8 GB) and logs the values. Override any setting with `ALTER SYSTEM`, or set `PG_MEMORY_LIMIT_MB` / `PG_CPU_LIMIT` after resizing the service. For a large index build, run `SET maintenance_work_mem = '2GB';` on `DATABASE_URL`; keep it below 3/4 of `/dev/shm` (`RAILWAY_SHM_SIZE_BYTES`, 1 GiB) or also `SET max_parallel_maintenance_workers = 0;`. Through the pool, use `SET LOCAL hnsw.ef_search = 100` inside a transaction; Prisma needs `?pgbouncer=true`.

**Backups and restore**: dumps land in the Bucket under `postgres/{timestamp}/` with a `MANIFEST.txt`. Trigger one now with `railway cron run --service "Postgres Backup"`. To restore, download `{database}.dump` from the Bucket's Files tab and run `pg_restore --clean --if-exists --no-owner --dbname "{DATABASE_PUBLIC_URL}?sslmode=require" railway.dump` with a PostgreSQL 18 client.

**Scaling**: give Postgres more RAM and CPU in its settings, then set `PG_MEMORY_LIMIT_MB` to match so the caches grow with it. Raise `DEFAULT_POOL_SIZE` on PgBouncer for more concurrent queries (Postgres allows 500 connections). Hobby volumes start at 5 GB; Pro volumes at 50 GB and can be resized. Use Railway's built-in pooling or this PgBouncer, not both.

**Versions and upgrades**: Postgres follows Railway's `postgres-ssl:18` tag (minor and security updates on redeploy; after a pgvector update run `ALTER EXTENSION vector UPDATE;`). PgBouncer is pinned to 1.26.1; change the tag to upgrade. For Railway's point-in-time recovery or HA, clear the Postgres start command first; the last tuning file stays in place.

**Cost**: roughly $1.50 per month idle and about $16 per month for a few GB of data with daily backups at Railway's usage prices.

### Why Deploy pgvector on Railway?

Railway runs the database, the pooler and the backup job together on a private network with persistent volumes and managed buckets, so you get a vector-ready Postgres in a few minutes without operating servers. It uses Railway's own Postgres image, works with the Data panel and existing `${{Postgres.*}}` references, and grows by raising the service limits and the volume size.
