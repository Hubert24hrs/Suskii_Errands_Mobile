# Backup worker image: PostgreSQL 17 client tools (pg_dump, pg_restore) and a PostgreSQL 17 +
# PostGIS server for the throwaway restore in `verify` — both from the same image, so the tool
# and server versions always match what the restore needs.
#
# Built on the official postgres image for Debian 13 (trixie), with PostGIS from the PostgreSQL
# apt repository that image already configures. The postgis/postgis:17 images are Debian 11
# based, whose security archive already returned 404s in CI.
FROM postgres:17-trixie

RUN apt-get update  && apt-get install -y --no-install-recommends postgresql-17-postgis-3  && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:0.12.15 /uv /bin/uv

ENV UV_PYTHON_INSTALL_DIR=/opt/python \
    UV_PROJECT_ENVIRONMENT=/opt/venv \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PATH="/opt/venv/bin:/usr/lib/postgresql/17/bin:${PATH}"

WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
COPY src ./src
RUN uv sync --frozen --no-dev \
 && chown -R postgres:postgres /app /opt/venv

COPY entrypoint.sh /usr/local/bin/suskii-backup-entrypoint
RUN chmod 0755 /usr/local/bin/suskii-backup-entrypoint

# The base image's entrypoint would start a database server; this image runs one command and exits.
USER postgres
ENTRYPOINT ["/usr/local/bin/suskii-backup-entrypoint"]
CMD ["dump"]
