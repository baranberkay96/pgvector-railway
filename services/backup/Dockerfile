# Postgres Backup (Railway cron job): pg_dump 18 + rclone on Alpine.
#
# The PostgreSQL client major must be >= the server's major (Postgres runs
# ghcr.io/railwayapp-templates/postgres-ssl:18). When Postgres moves to a new
# major, bump postgresql18-client below (and the PATH entry) in the same change.
FROM alpine:3.24.2

RUN apk add --no-cache bash coreutils ca-certificates postgresql18-client rclone \
 && addgroup -S backup \
 && adduser -S -D -H -h /tmp -G backup backup

# Alpine links the default client version into /usr/bin; the versioned directory
# comes first so pg_dump is always the 18 client.
ENV PATH="/usr/libexec/postgresql18:${PATH}" \
    HOME=/tmp

COPY --chmod=755 pgvector-backup.sh /usr/local/bin/pgvector-backup

# Fail the build early if a tool is missing or the client is not 18.
RUN pg_dump --version | grep -q ' 18\.' \
 && pg_restore --version >/dev/null \
 && pg_dumpall --version >/dev/null \
 && pg_isready --version >/dev/null \
 && rclone version >/dev/null \
 && date -u -d @0 +%Y >/dev/null

USER backup

ENTRYPOINT ["/usr/local/bin/pgvector-backup"]
CMD ["backup"]
