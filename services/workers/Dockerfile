# Backup worker image: PostgreSQL 17 client tools (pg_dump, pg_restore) and a PostgreSQL 17 +
# PostGIS server for the throwaway restore in `verify` — both from the same image, so the tool
# and server versions always match what the restore needs.
FROM postgis/postgis:17-3.5

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
