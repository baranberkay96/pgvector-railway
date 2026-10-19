#!/bin/bash
# Readable source of the Postgres service's start command. Nothing is built from
# this folder: the Postgres service runs Railway's own image
# (ghcr.io/railwayapp-templates/postgres-ssl:18) and template.json carries this
# script joined into one line:
#
#   /usr/bin/tini -g -- /bin/bash -c '<this script>' pgvector-start postgres -p 5432 -c listen_addresses=*
#
# That is the image's own ENTRYPOINT + CMD with this script in between. Regenerate
# the line with `python3 to-start-command.py` after editing (`--check` compares it
# with template.json). Rules that keep the one-line form valid: no single quotes,
# no backslashes, comments only on their own lines, and every line is a complete
# command or ends in then/do/else.
#
# At every boot, before handing over to the image's wrapper.sh, it:
#   1. writes an initdb hook so the FIRST boot runs CREATE EXTENSION vector and
#      pg_stat_statements in POSTGRES_DB (later boots never touch extensions);
#   2. sizes memory and parallelism from the container limits (cgroup v2
#      memory.max and cpu.max, /dev/shm) instead of the host's RAM and cores, and
#      writes $PGDATA/pgvector-tuning.conf, pulled in by an
#      `include_if_exists = pgvector-tuning.conf` line at the end of
#      postgresql.conf. postgresql.auto.conf is read after it, so ALTER SYSTEM
#      always overrides it, and a missing file never stops Postgres from booting;
#   3. execs wrapper.sh with the image's default arguments.
set -e
D="${PGDATA%/}"
F="$D/pgvector-tuning.conf"
C="$D/postgresql.conf"
I=/docker-entrypoint-initdb.d
X=/tmp/pgvector-tuning.conf
echo "CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" > $I/zz-pgvector-extensions.sql
# k VALUE MIN MAX: clamp. n VALUE FALLBACK: VALUE if it is a whole number.
k() { v=$1; if [ $v -lt $2 ]; then v=$2; fi; if [ $v -gt $3 ]; then v=$3; fi; echo $v; }
n() { case "$1" in ""|*[!0-9]*) echo $2 ;; *) echo $1 ;; esac; }
w() { echo "$1 = $2" >> $X; }
if [ "${PGVECTOR_TUNING:-auto}" = off ]; then
rm -f $F $I/zz-pgvector-conf.sh
echo "pgvector-tune: PGVECTOR_TUNING=off, Postgres defaults apply"
else
# Host RAM (the container sees all of it), then the cgroup v2 memory limit, in MB.
H=$(( $(n "$(grep -m 1 MemTotal /proc/meminfo | tr -s " " | cut -d " " -f 2)" 1048576) / 1024 ))
M=$(( $(n "$(cat /sys/fs/cgroup/memory.max 2>/dev/null)" $((H * 1048576))) / 1048576 ))
if [ $M -gt $H ]; then M=$H; fi
# Budget: PG_MEMORY_LIMIT_MB, or auto = container limit capped at 8192 MB.
B=$(k $(n "$PG_MEMORY_LIMIT_MB" $(k $M 256 8192)) 256 4194304)
# CPUs: PG_CPU_LIMIT, or auto = min(cgroup cpu.max quota, nproc) capped at 8.
N=$(nproc)
read -r Q P 2>/dev/null < /sys/fs/cgroup/cpu.max || Q=max
case "$Q" in ""|*[!0-9]*) ;; *) N=$(k $(( (Q + P - 1) / P )) 1 $N) ;; esac
N=$(k $(n "$PG_CPU_LIMIT" $(k $N 1 8)) 1 256)
# /dev/shm in MB: 64 by default on Railway, RAILWAY_SHM_SIZE_BYTES raises it.
S=$(( $(n "$(df -Pk /dev/shm 2>/dev/null | tail -n 1 | tr -s " " | cut -d " " -f 2)" 65536) / 1024 ))
SB=$(k $((B / 4)) 128 1048576)
MW=$(k $((B / 4)) 64 2048)
PM=$(k $((N - 1)) 0 4)
PW=$(k $N 2 256)
PG=$(k $((N / 2)) 0 2)
# A parallel HNSW build keeps the whole graph (maintenance_work_mem) in /dev/shm.
FIT=$((S * 3 / 4))
if [ $FIT -lt 128 ]; then PM=0; fi
if [ $PM -gt 0 ]; then MW=$(k $MW 64 $FIT); fi
if [ $S -lt 256 ]; then PG=0; fi
echo "# pgvector template: rewritten at every boot from budget ${B}MB (container ${M}MB), ${N} cpus, /dev/shm ${S}MB; ALTER SYSTEM overrides it" > $X
w shared_buffers ${SB}MB
w effective_cache_size $((B * 3 / 4))MB
w maintenance_work_mem ${MW}MB
w autovacuum_work_mem $(k $((B / 16)) 64 $MW)MB
w work_mem $(k $((B / 512)) 4 64)MB
w max_worker_processes $(k $((PW + 4)) 8 512)
w max_parallel_workers $PW
w max_parallel_workers_per_gather $PG
w max_parallel_maintenance_workers $PM
w random_page_cost 1.1
w effective_io_concurrency 200
w track_io_timing on
chmod 644 $X
if [ -f $D/PG_VERSION ] && [ -f $C ]; then
install -o postgres -g postgres -m 600 $X $F
grep -qsF "include_if_exists = pgvector-tuning.conf" $C || echo "include_if_exists = pgvector-tuning.conf" >> $C
sync $F $C 2>/dev/null || true
else
# First boot: initdb creates PGDATA, so an initdb hook installs the file.
echo "cp $X $F && chmod 600 $F && { grep -qsF pgvector-tuning.conf $C || echo include_if_exists = pgvector-tuning.conf >> $C; }" > $I/zz-pgvector-conf.sh
fi
echo "pgvector-tune: $(paste -sd " " $X)"
fi
exec /usr/local/bin/wrapper.sh "$@"
