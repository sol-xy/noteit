"""FastAPI application entrypoint, security middleware, and Web UI serving."""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request, Response
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from app.config import Settings, get_settings
from app.db import Database
from app.deps import limiter
from app.routes import auth, chat, health, meetings, push
from app.services.push import PushService
from app.services.worker import MeetingWorker

WEB_DIR = Path(__file__).resolve().parent / "web"

CSP_POLICY = (
    "default-src 'self'; "
    "script-src 'self'; "
    "style-src 'self'; "
    "img-src 'self' data: blob:; "
    "media-src 'self' blob:; "
    "connect-src 'self'; "
    "worker-src 'self'; "
    "manifest-src 'self'; "
    "frame-ancestors 'none'; "
    "base-uri 'self'; "
    "form-action 'self'"
)


def create_app(settings: Settings | None = None) -> FastAPI:
    """Create and configure the NoteIt FastAPI application."""
    cfg = settings or get_settings()
    logging.basicConfig(
        level=getattr(logging, cfg.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    )

    limiter.enabled = cfg.enable_rate_limit

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        cfg.data_dir.mkdir(parents=True, exist_ok=True)
        cfg.audio_dir.mkdir(parents=True, exist_ok=True)
        cfg.tmp_dir.mkdir(parents=True, exist_ok=True)

        db = Database(cfg.db_path)
        await db.init()

        push_service = PushService(db=db, settings=cfg)
        push_service.ensure_keys()

        worker = MeetingWorker(db=db, settings=cfg, push_service=push_service)
        app.state.db = db
        app.state.push = push_service
        app.state.worker = worker
        await worker.start()
        try:
            yield
        finally:
            await worker.stop()

    app = FastAPI(
        title="NoteIt API",
        version="1.0.0",
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        lifespan=lifespan,
    )
    app.dependency_overrides[get_settings] = lambda: cfg
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

    @app.middleware("http")
    async def security_headers_middleware(request: Request, call_next) -> Response:
        response = await call_next(request)
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("X-Frame-Options", "DENY")
        response.headers.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
        if not request.url.path.startswith("/api/"):
            response.headers.setdefault("Content-Security-Policy", CSP_POLICY)
        return response

    app.include_router(health.router)
    app.include_router(auth.router)
    app.include_router(meetings.router)
    app.include_router(chat.router)
    app.include_router(push.router)

    if WEB_DIR.exists():
        app.mount("/static", StaticFiles(directory=str(WEB_DIR)), name="static")

        @app.get("/", include_in_schema=False)
        async def serve_web_index() -> FileResponse:
            return FileResponse(WEB_DIR / "index.html")

        @app.get("/manifest.webmanifest", include_in_schema=False)
        async def serve_web_manifest() -> FileResponse:
            return FileResponse(
                WEB_DIR / "manifest.webmanifest",
                media_type="application/manifest+json",
            )

        @app.get("/sw.js", include_in_schema=False)
        async def serve_service_worker() -> FileResponse:
            return FileResponse(
                WEB_DIR / "sw.js",
                media_type="application/javascript",
                headers={"Cache-Control": "no-cache"},
            )

        @app.get("/apple-touch-icon.png", include_in_schema=False)
        async def serve_apple_touch_icon() -> FileResponse:
            return FileResponse(
                WEB_DIR / "icons" / "apple-touch-icon.png",
                media_type="image/png",
            )

    return app


def get_default_app() -> FastAPI:
    return create_app()
