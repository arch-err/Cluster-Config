from __future__ import annotations

import hmac
import json
import logging
import time
import zlib
from contextlib import asynccontextmanager
from typing import AsyncIterator

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse, PlainTextResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from psycopg import Error as DatabaseError

from .config import Config
from .database import Store
from .metrics import DB_ERRORS, DURATION, REJECTIONS, REQUESTS
from .protocol import ProtocolError, Validators, validate_payload


LOGGER = logging.getLogger("ctfd_cockpit_ingest")


class RequestError(ValueError):
    def __init__(self, code: str, status: int):
        super().__init__(code)
        self.code = code
        self.status = status


def create_app(config: Config, store: Store | None = None) -> FastAPI:
    validators = Validators.load(config.schema_dir)
    database = store or Store(config.database_url, config.snapshot_staging_ttl_seconds)

    @asynccontextmanager
    async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
        database.open()
        try:
            yield
        finally:
            database.close()

    app = FastAPI(
        title="CTFd Cockpit Ingest",
        version="1.0.0",
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        lifespan=lifespan,
    )

    @app.middleware("http")
    async def metadata_log(request: Request, call_next):  # type: ignore[no-untyped-def]
        started = time.monotonic()
        status = 500
        try:
            response = await call_next(request)
            status = response.status_code
            return response
        finally:
            # Deliberately omit query strings, headers, and bodies.
            LOGGER.info(
                "request method=%s path=%s status=%d duration_ms=%d",
                request.method,
                request.url.path,
                status,
                int((time.monotonic() - started) * 1000),
            )

    @app.get("/healthz")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/readyz")
    async def readiness() -> Response:
        if not database.ready():
            return JSONResponse({"status": "not ready"}, status_code=503)
        return JSONResponse({"status": "ready"})

    @app.get("/metrics")
    async def metrics() -> Response:
        return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

    async def ingest(request: Request, endpoint: str) -> Response:
        started = time.monotonic()
        try:
            _require_bearer(request, config.ingest_token)
            raw = await _read_limited(request, config.max_compressed_bytes)
            expanded = _decompress(request, raw, config.max_expanded_bytes)
            try:
                decoded = json.loads(expanded)
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise RequestError("invalid_json", 400) from error
            payload = validate_payload(
                decoded,
                endpoint=endpoint,
                validators=validators,
                allowed_source=config.allowed_source,
                max_records=config.max_batch_records,
            )
            if endpoint == "events":
                result = database.ingest_events(payload, expanded)
                response: dict[str, int] = {"checkpoint": int(result.checkpoint)}
            else:
                database.ingest_snapshot(payload, expanded)
                response = {}
            REQUESTS.labels(endpoint=endpoint, result="success").inc()
            return JSONResponse(response)
        except (RequestError, ProtocolError) as error:
            REQUESTS.labels(endpoint=endpoint, result="rejected").inc()
            REJECTIONS.labels(endpoint=endpoint, reason=error.code).inc()
            return JSONResponse({"error": error.code}, status_code=error.status)
        except DatabaseError:
            DB_ERRORS.labels(operation=endpoint).inc()
            REQUESTS.labels(endpoint=endpoint, result="error").inc()
            LOGGER.error("database operation failed endpoint=%s", endpoint)
            return JSONResponse({"error": "database_error"}, status_code=503)
        finally:
            DURATION.labels(endpoint=endpoint).observe(time.monotonic() - started)

    @app.post("/api/v1/events")
    async def events(request: Request) -> Response:
        return await ingest(request, "events")

    @app.post("/api/v1/snapshot")
    async def snapshot(request: Request) -> Response:
        return await ingest(request, "snapshot")

    @app.post("/mimir/api/v1/push")
    async def mimir_write(request: Request) -> Response:
        return await _proxy_telemetry(
            request,
            expected_token=config.mimir_token,
            tenant=config.mimir_tenant_id,
            upstream=config.mimir_write_url,
            max_bytes=config.max_compressed_bytes,
        )

    @app.post("/loki/loki/api/v1/push")
    async def loki_write(request: Request) -> Response:
        return await _proxy_telemetry(
            request,
            expected_token=config.loki_token,
            tenant=config.loki_tenant_id,
            upstream=config.loki_write_url,
            max_bytes=config.max_compressed_bytes,
        )

    return app


def _require_bearer(request: Request, expected: str) -> None:
    supplied = request.headers.get("authorization", "")
    wanted = f"Bearer {expected}"
    if not hmac.compare_digest(supplied.encode(), wanted.encode()):
        raise RequestError("unauthorized", 401)


async def _read_limited(request: Request, limit: int) -> bytes:
    content_length = request.headers.get("content-length")
    if content_length:
        try:
            if int(content_length) > limit:
                raise RequestError("compressed_body_too_large", 413)
        except ValueError as error:
            raise RequestError("invalid_content_length", 400) from error
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > limit:
            raise RequestError("compressed_body_too_large", 413)
    return bytes(body)


def _decompress(request: Request, raw: bytes, limit: int) -> bytes:
    if request.headers.get("content-type", "").split(";", 1)[0] != "application/json":
        raise RequestError("unsupported_content_type", 415)
    if request.headers.get("content-encoding", "").lower() != "gzip":
        raise RequestError("gzip_required", 415)
    try:
        decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
        expanded = decompressor.decompress(raw, limit + 1)
        if decompressor.unconsumed_tail or len(expanded) > limit:
            raise RequestError("expanded_body_too_large", 413)
        expanded += decompressor.flush(limit + 1 - len(expanded))
    except zlib.error as error:
        raise RequestError("invalid_gzip", 400) from error
    if len(expanded) > limit or not decompressor.eof:
        raise RequestError("expanded_body_too_large", 413)
    return expanded


async def _proxy_telemetry(
    request: Request,
    *,
    expected_token: str,
    tenant: str,
    upstream: str,
    max_bytes: int,
) -> Response:
    try:
        _require_bearer(request, expected_token)
        body = await _read_limited(request, max_bytes)
    except RequestError as error:
        return JSONResponse({"error": error.code}, status_code=error.status)
    headers = {"X-Scope-OrgID": tenant}
    for name in ("content-type", "content-encoding", "x-prometheus-remote-write-version"):
        if value := request.headers.get(name):
            headers[name] = value
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            response = await client.post(upstream, content=body, headers=headers)
    except httpx.HTTPError:
        LOGGER.error("telemetry upstream unavailable path=%s", request.url.path)
        return JSONResponse({"error": "upstream_unavailable"}, status_code=502)
    if response.status_code >= 300:
        LOGGER.warning(
            "telemetry upstream rejected path=%s status=%d",
            request.url.path,
            response.status_code,
        )
        return JSONResponse({"error": "upstream_rejected"}, status_code=response.status_code)
    return PlainTextResponse("", status_code=response.status_code)
