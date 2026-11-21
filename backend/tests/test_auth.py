"""Authentication, session cookie, and security header tests."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from app.config import Settings


def test_weak_token_rejected():
    with pytest.raises(ValidationError):
        Settings(auth_token="short")


async def test_health_and_web_ui_headers(client):
    health = await client.get("/health")
    assert health.status_code == 200
    assert health.json() == {"status": "ok"}
    assert health.headers["x-content-type-options"] == "nosniff"
    assert health.headers["x-frame-options"] == "DENY"

    index = await client.get("/")
    assert index.status_code == 200
    assert "NoteIt" in index.text
    assert "content-security-policy" in index.headers


async def test_bearer_and_cookie_auth_flow(client, test_token, auth_headers):
    unauth = await client.get("/api/meetings")
    assert unauth.status_code == 401

    me_bearer = await client.get("/api/auth/me", headers=auth_headers)
    assert me_bearer.status_code == 200
    assert me_bearer.json()["auth_method"] == "bearer"

    bad_login = await client.post("/api/auth/login", json={"token": "wrong-token"})
    assert bad_login.status_code == 401

    good_login = await client.post("/api/auth/login", json={"token": test_token})
    assert good_login.status_code == 200
    assert good_login.json()["auth_method"] == "cookie"
    set_cookie = good_login.headers.get("set-cookie", "")
    assert "httponly" in set_cookie.lower()
    assert "samesite=strict" in set_cookie.lower()

    me_cookie = await client.get("/api/auth/me")
    assert me_cookie.status_code == 200
    assert me_cookie.json()["auth_method"] == "cookie"

    logout = await client.post("/api/auth/logout")
    assert logout.status_code == 200

    after_logout = await client.get("/api/auth/me")
    assert after_logout.status_code == 401
