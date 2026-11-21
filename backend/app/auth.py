"""Authentication helpers for Bearer tokens and signed HttpOnly session cookies."""

from __future__ import annotations

import hashlib
import hmac
import time

from fastapi import Depends, HTTPException, Request, Response, status

from app.config import Settings, get_settings

SESSION_COOKIE_NAME = "noteit_session"
SESSION_TTL_SECONDS = 30 * 24 * 60 * 60


def verify_token_constant_time(candidate: str | None, expected: str) -> bool:
    """Compare a candidate auth token against the configured token in constant time."""
    if not candidate:
        return False
    return hmac.compare_digest(candidate.encode("utf-8"), expected.encode("utf-8"))


def create_session_cookie_value(settings: Settings, now: int | None = None) -> str:
    """Create a signed `<expiry>.<hmac_hex>` session cookie value."""
    current = int(time.time()) if now is None else now
    expiry = current + SESSION_TTL_SECONDS
    payload = str(expiry).encode("utf-8")
    sig = hmac.new(settings.derived_session_secret, payload, hashlib.sha256).hexdigest()
    return f"{expiry}.{sig}"


def verify_session_cookie_value(
    cookie_value: str | None, settings: Settings, now: int | None = None
) -> bool:
    """Verify signature and expiration of the session cookie value."""
    if not cookie_value or "." not in cookie_value:
        return False
    expiry_str, sig_hex = cookie_value.split(".", 1)
    if not expiry_str.isdigit() or not sig_hex:
        return False
    expiry = int(expiry_str)
    current = int(time.time()) if now is None else now
    if expiry <= current:
        return False
    expected_sig = hmac.new(
        settings.derived_session_secret,
        expiry_str.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    return hmac.compare_digest(sig_hex, expected_sig)


def set_session_cookie(response: Response, settings: Settings) -> None:
    """Attach a signed HttpOnly session cookie to the response."""
    response.set_cookie(
        key=SESSION_COOKIE_NAME,
        value=create_session_cookie_value(settings),
        max_age=SESSION_TTL_SECONDS,
        httponly=True,
        secure=settings.cookie_secure,
        samesite="strict",
        path="/",
    )


def clear_session_cookie(response: Response, settings: Settings) -> None:
    """Clear the session cookie from the client."""
    response.delete_cookie(
        key=SESSION_COOKIE_NAME,
        httponly=True,
        secure=settings.cookie_secure,
        samesite="strict",
        path="/",
    )


def _extract_bearer_token(request: Request) -> str | None:
    auth_header = request.headers.get("Authorization")
    if not auth_header:
        return None
    parts = auth_header.split(" ", 1)
    if len(parts) != 2 or parts[0].lower() != "bearer":
        return None
    return parts[1].strip()


def require_auth(
    request: Request,
    settings: Settings = Depends(get_settings),
) -> str:
    """Authorize either a valid Bearer token or a valid signed session cookie."""
    bearer = _extract_bearer_token(request)
    if bearer is not None and verify_token_constant_time(bearer, settings.auth_token):
        return "bearer"

    cookie_val = request.cookies.get(SESSION_COOKIE_NAME)
    if verify_session_cookie_value(cookie_val, settings):
        return "cookie"

    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Authentication required",
        headers={"WWW-Authenticate": "Bearer"},
    )
