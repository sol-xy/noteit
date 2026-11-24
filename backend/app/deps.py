"""Shared FastAPI dependencies and rate limiter instance."""

from __future__ import annotations

from fastapi import Request
from slowapi import Limiter
from slowapi.util import get_remote_address

from app.db import Database
from app.services.push import PushService
from app.services.worker import MeetingWorker

limiter = Limiter(key_func=get_remote_address)


def get_db(request: Request) -> Database:
    return request.app.state.db


def get_worker(request: Request) -> MeetingWorker:
    return request.app.state.worker


def get_push_service(request: Request) -> PushService:
    return request.app.state.push
