FROM ghcr.io/astral-sh/uv:0.8.17@sha256:e4644cb5bd56fdc2c5ea3ee0525d9d21eed1603bccd6a21f887a938be7e85be1 AS uv

FROM python:3.13.7-slim-bookworm@sha256:adafcc17694d715c905b4c7bebd96907a1fd5cf183395f0ebc4d3428bd22d92d AS build
WORKDIR /app
COPY --from=uv /uv /usr/local/bin/uv
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
COPY src ./src
COPY schemas ./schemas
COPY migrations ./migrations
RUN uv sync --frozen --no-dev --no-editable

FROM python:3.13.7-slim-bookworm@sha256:adafcc17694d715c905b4c7bebd96907a1fd5cf183395f0ebc4d3428bd22d92d
WORKDIR /app
COPY --from=build /app/.venv /app/.venv
COPY --from=build /app/schemas /app/schemas
COPY --from=build /app/migrations /app/migrations
ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    COCKPIT_SCHEMA_DIR=/app/schemas \
    COCKPIT_MIGRATION_DIR=/app/migrations
EXPOSE 8080
ENTRYPOINT ["/app/.venv/bin/ctfd-cockpit-ingest"]
