"""Tests for Web Push (VAPID) key generation, subscriptions, pruning, and worker hooks."""

from __future__ import annotations

import base64
import json
from pathlib import Path
from types import SimpleNamespace

import pywebpush

from app.config import Settings
from app.main import create_app
from app.services.audio import TranscriptSegment
from app.services.push import PushService
from app.services.summarizer import SummaryResult
from tests.conftest import make_sine_m4a


def _decode_b64url(value: str) -> bytes:
    padded = value + "=" * ((4 - len(value) % 4) % 4)
    return base64.urlsafe_b64decode(padded.encode("ascii"))


def _sample_subscription(endpoint: str = "https://web.push.apple.com/sub-1") -> dict:
    # Real uncompressed P-256 point for pywebpush AES-128-GCM encryption tests.
    p256dh = (
        "BC9bkYffZht-4YEOs7vz_EEpcUFRx41HZd4SlbeQ1hwS8B3BaqP_9dOJo-0ETHjavYBoTy7IEZAzJ5sJ8rAaHjs"
    )
    return {
        "endpoint": endpoint,
        "keys": {
            "p256dh": p256dh,
            "auth": "tBHItJI5svbpez7KI4CCXg",
        },
    }


async def test_push_vapid_auto_generated_and_persisted(test_settings: Settings):
    app1 = create_app(test_settings)
    async with app1.router.lifespan_context(app1):
        push1: PushService = app1.state.push
        assert push1.is_enabled
        pub1 = push1.public_key
        assert pub1 is not None
        raw1 = _decode_b64url(pub1)
        assert len(raw1) == 65
        assert raw1[0] == 0x04
        assert test_settings.vapid_key_path.is_file()

    # Restarting with the same data_dir reloads the exact persisted VAPID key.
    app2 = create_app(test_settings)
    async with app2.router.lifespan_context(app2):
        push2: PushService = app2.state.push
        assert push2.public_key == pub1


async def test_push_config_subscribe_unsubscribe_and_auth(client, auth_headers):
    assert (await client.get("/api/push/config")).status_code == 401
    unauth_sub = await client.post("/api/push/subscribe", json=_sample_subscription())
    assert unauth_sub.status_code == 401

    cfg_resp = await client.get("/api/push/config", headers=auth_headers)
    assert cfg_resp.status_code == 200
    cfg = cfg_resp.json()
    assert cfg["enabled"] is True
    assert cfg["public_key"]
    assert cfg["subscription_count"] == 0

    bad_sub = _sample_subscription("http://insecure.example.com/sub")
    assert (
        await client.post("/api/push/subscribe", headers=auth_headers, json=bad_sub)
    ).status_code == 422

    sub_payload = _sample_subscription("https://web.push.apple.com/device-a")
    s1 = await client.post("/api/push/subscribe", headers=auth_headers, json=sub_payload)
    assert s1.status_code == 200
    assert s1.json() == {"subscribed": True, "subscription_count": 1}

    # Duplicate endpoint upserts idempotently without increasing count.
    s2 = await client.post("/api/push/subscribe", headers=auth_headers, json=sub_payload)
    assert s2.status_code == 200
    assert s2.json() == {"subscribed": True, "subscription_count": 1}

    unsub = await client.post(
        "/api/push/unsubscribe",
        headers=auth_headers,
        json={"endpoint": "https://web.push.apple.com/device-a"},
    )
    assert unsub.status_code == 200
    assert unsub.json() == {"subscribed": False, "subscription_count": 0}


async def test_push_send_prunes_expired_410_subscription(
    app_instance, client, auth_headers, monkeypatch
):
    await client.post(
        "/api/push/subscribe",
        headers=auth_headers,
        json=_sample_subscription("https://web.push.apple.com/active"),
    )
    await client.post(
        "/api/push/subscribe",
        headers=auth_headers,
        json=_sample_subscription("https://web.push.apple.com/expired"),
    )

    calls: list[str] = []

    def fake_webpush(subscription_info, data, vapid_private_key, vapid_claims, **kwargs):
        endpoint = subscription_info["endpoint"]
        calls.append(endpoint)
        assert "sub" in vapid_claims
        if endpoint.endswith("/expired"):
            raise pywebpush.WebPushException(
                "Gone",
                response=SimpleNamespace(status_code=410, text="Gone"),
            )
        return SimpleNamespace(status_code=201)

    monkeypatch.setattr("pywebpush.webpush", fake_webpush)

    push_service: PushService = app_instance.state.push
    result = await push_service.send_notification(
        title="Summary Ready",
        body="Design Review",
        url="/?meeting=abc",
        tag="meeting-abc",
        meeting_id="abc",
    )
    assert result == {"sent": 1, "failed": 0, "removed": 1}
    assert len(calls) == 2

    remaining = await app_instance.state.db.list_push_subscriptions()
    assert [s["endpoint"] for s in remaining] == ["https://web.push.apple.com/active"]


async def test_worker_triggers_push_on_completion_and_failure(
    app_instance, client, auth_headers, tmp_path: Path, monkeypatch
):
    await client.post(
        "/api/push/subscribe",
        headers=auth_headers,
        json=_sample_subscription("https://web.push.apple.com/worker-test"),
    )

    sent_payloads: list[dict] = []

    def fake_webpush(subscription_info, data, vapid_private_key, vapid_claims, **kwargs):
        sent_payloads.append(json.loads(data))
        return SimpleNamespace(status_code=201)

    monkeypatch.setattr("pywebpush.webpush", fake_webpush)

    def fake_groq(chunk_path, settings):
        return (
            [TranscriptSegment(0.0, 2.0, "Agreed to ship v2.")],
            "Agreed to ship v2.",
            "en",
        )

    def fake_summary(transcript, manual_notes, custom_instructions, settings):
        return SummaryResult(
            title="Release Sync",
            summary_markdown="## Overview\n\nShip v2.",
        )

    monkeypatch.setattr("app.services.stt._transcribe_chunk_groq_sync", fake_groq)
    monkeypatch.setattr("app.services.summarizer._generate_summary_sync", fake_summary)

    audio_file = make_sine_m4a(tmp_path / "ok.m4a", duration_sec=2.0)
    with audio_file.open("rb") as f:
        up_ok = await client.post(
            "/api/meetings/quick-upload",
            headers=auth_headers,
            files={"file": ("ok.m4a", f, "audio/m4a")},
        )
    assert up_ok.status_code == 202
    ok_id = up_ok.json()["id"]
    await app_instance.state.worker.drain_for_tests()

    assert len(sent_payloads) == 1
    assert sent_payloads[0]["title"] == "Summary Ready"
    assert sent_payloads[0]["body"] == "Release Sync"
    assert sent_payloads[0]["url"] == f"/?meeting={ok_id}"
    assert sent_payloads[0]["meeting_id"] == ok_id

    # Now test failure notification without breaking meeting failure status.
    def broken_stt(audio_path, provider, work_dir, settings):
        raise RuntimeError("Upstream STT offline")

    monkeypatch.setattr("app.services.worker.transcribe_audio", broken_stt)

    with audio_file.open("rb") as f:
        up_fail = await client.post(
            "/api/meetings/quick-upload",
            headers=auth_headers,
            data={"title": "Broken Meeting"},
            files={"file": ("fail.m4a", f, "audio/m4a")},
        )
    assert up_fail.status_code == 202
    fail_id = up_fail.json()["id"]
    await app_instance.state.worker.drain_for_tests()

    detail = (await client.get(f"/api/meetings/{fail_id}", headers=auth_headers)).json()
    assert detail["status"] == "failed"

    assert len(sent_payloads) == 2
    assert sent_payloads[1]["title"] == "Processing Failed"
    assert "Broken Meeting" in sent_payloads[1]["body"]
    assert "Upstream STT offline" in sent_payloads[1]["body"]
    assert sent_payloads[1]["url"] == f"/?meeting={fail_id}"


async def test_push_test_endpoint(client, auth_headers, monkeypatch):
    await client.post(
        "/api/push/subscribe",
        headers=auth_headers,
        json=_sample_subscription("https://web.push.apple.com/test-endpoint"),
    )

    captured: list[dict] = []

    def fake_webpush(subscription_info, data, vapid_private_key, vapid_claims, **kwargs):
        captured.append(json.loads(data))
        return SimpleNamespace(status_code=201)

    monkeypatch.setattr("pywebpush.webpush", fake_webpush)

    resp = await client.post("/api/push/test", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json() == {"sent": 1, "failed": 0, "removed": 0}
    assert len(captured) == 1
    assert captured[0]["title"] == "NoteIt Notifications Active"


async def test_push_real_pywebpush_vapid_signing_and_encryption(
    app_instance, client, auth_headers, monkeypatch
):
    await client.post(
        "/api/push/subscribe",
        headers=auth_headers,
        json=_sample_subscription("https://web.push.apple.com/real-crypto"),
    )

    recorded_requests: list[dict] = []

    def fake_requests_post(url, data=None, headers=None, **kwargs):
        recorded_requests.append({"url": url, "data": data, "headers": headers})
        return SimpleNamespace(status_code=201, text="", reason="Created", headers={})

    monkeypatch.setattr(
        "requests.Session.post",
        lambda self, *a, **kw: fake_requests_post(*a, **kw),
    )
    monkeypatch.setattr("requests.post", fake_requests_post)

    push_service: PushService = app_instance.state.push
    result = await push_service.notify_meeting_completed("m-123", "Crypto Verification")
    assert result == {"sent": 1, "failed": 0, "removed": 0}
    assert len(recorded_requests) == 1
    req = recorded_requests[0]
    assert req["url"] == "https://web.push.apple.com/real-crypto"
    assert req["data"]  # AES-128-GCM encrypted payload bytes
    assert "Authorization" in req["headers"]
    assert "vapid t=" in req["headers"]["Authorization"].lower()
