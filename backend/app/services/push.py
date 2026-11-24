"""Web Push (VAPID) key management and notification delivery for iOS PWA."""

from __future__ import annotations

import asyncio
import base64
import contextlib
import json
import logging
import os
from pathlib import Path
from typing import Any

import pywebpush
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from py_vapid import Vapid

from app.config import Settings
from app.db import Database

logger = logging.getLogger(__name__)


def _load_private_key(raw: str) -> ec.EllipticCurvePrivateKey:
    """Load an ECDSA P-256 private key from file path, PEM text, or base64url raw/DER."""
    stripped = raw.strip()
    if "\n" not in stripped and Path(stripped).is_file():
        key = serialization.load_pem_private_key(Path(stripped).read_bytes(), password=None)
    elif "BEGIN " in stripped:
        pem_text = stripped.replace("\\n", "\n")
        key = serialization.load_pem_private_key(pem_text.encode("utf-8"), password=None)
    else:
        padded = stripped + "=" * ((4 - len(stripped) % 4) % 4)
        decoded = base64.urlsafe_b64decode(padded.encode("ascii"))
        if len(decoded) == 32:
            key = ec.derive_private_key(int.from_bytes(decoded, "big"), ec.SECP256R1())
        else:
            key = serialization.load_der_private_key(decoded, password=None)

    if not isinstance(key, ec.EllipticCurvePrivateKey) or not isinstance(
        key.curve, ec.SECP256R1
    ):
        raise ValueError("VAPID private key must be an ECDSA P-256 (prime256v1) key")
    return key


class PushService:
    """Manages VAPID keys and delivers encrypted Web Push notifications."""

    def __init__(self, db: Database, settings: Settings) -> None:
        self.db = db
        self.settings = settings
        self._vapid: Vapid | None = None
        self._public_key_b64: str | None = None

    @property
    def is_enabled(self) -> bool:
        return bool(self._vapid and self._public_key_b64)

    @property
    def public_key(self) -> str | None:
        return self._public_key_b64

    def ensure_keys(self) -> None:
        """Load or auto-generate the VAPID P-256 key pair."""
        if not self.settings.push_enabled:
            self._vapid = None
            self._public_key_b64 = None
            return

        env_key = self.settings.vapid_private_key.strip()
        key_path = self.settings.vapid_key_path

        if env_key:
            private_key = _load_private_key(env_key)
        elif key_path.is_file():
            private_key = serialization.load_pem_private_key(
                key_path.read_bytes(), password=None
            )
            if not isinstance(private_key, ec.EllipticCurvePrivateKey) or not isinstance(
                private_key.curve, ec.SECP256R1
            ):
                raise ValueError("Persisted VAPID private key must use P-256")
        else:
            private_key = ec.generate_private_key(ec.SECP256R1())
            pem_bytes = private_key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.TraditionalOpenSSL,
                encryption_algorithm=serialization.NoEncryption(),
            )
            key_path.parent.mkdir(parents=True, exist_ok=True)
            key_path.write_bytes(pem_bytes)
            with contextlib.suppress(OSError):
                os.chmod(key_path, 0o600)

        pem_bytes = private_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        )
        self._vapid = Vapid.from_pem(pem_bytes)

        pub_bytes = private_key.public_key().public_bytes(
            encoding=serialization.Encoding.X962,
            format=serialization.PublicFormat.UncompressedPoint,
        )
        self._public_key_b64 = base64.urlsafe_b64encode(pub_bytes).rstrip(b"=").decode("ascii")

    def _send_single_sync(self, subscription_info: dict[str, Any], payload_json: str) -> None:
        assert self._vapid is not None
        # pywebpush mutates vapid_claims in-place, so always construct a fresh dict.
        pywebpush.webpush(
            subscription_info=subscription_info,
            data=payload_json,
            vapid_private_key=self._vapid,
            vapid_claims={"sub": self.settings.vapid_subject},
            ttl=3600,
            timeout=10,
        )

    async def send_notification(
        self,
        *,
        title: str,
        body: str,
        url: str = "/",
        tag: str = "noteit",
        meeting_id: str | None = None,
    ) -> dict[str, int]:
        """Broadcast a Web Push notification to all registered subscriptions."""
        if not self.is_enabled:
            return {"sent": 0, "failed": 0, "removed": 0}

        subscriptions = await self.db.list_push_subscriptions()
        if not subscriptions:
            return {"sent": 0, "failed": 0, "removed": 0}

        payload_json = json.dumps(
            {
                "title": title,
                "body": body,
                "url": url,
                "tag": tag,
                "meeting_id": meeting_id,
            }
        )

        sent = 0
        failed = 0
        removed = 0

        for sub in subscriptions:
            sub_info = {
                "endpoint": sub["endpoint"],
                "keys": {
                    "p256dh": sub["p256dh"],
                    "auth": sub["auth"],
                },
            }
            try:
                await asyncio.to_thread(self._send_single_sync, sub_info, payload_json)
                sent += 1
            except pywebpush.WebPushException as exc:
                status_code = exc.response.status_code if exc.response is not None else None
                if status_code in {404, 410}:
                    await self.db.delete_push_subscription(sub["endpoint"])
                    removed += 1
                    logger.info("Removed expired push subscription (%s)", status_code)
                else:
                    failed += 1
                    logger.warning("Web push delivery failed (%s): %s", status_code, exc)
            except Exception as exc:  # pragma: no cover - defensive guard
                failed += 1
                logger.warning("Unexpected error delivering web push: %s", exc)

        return {"sent": sent, "failed": failed, "removed": removed}

    async def notify_meeting_completed(self, meeting_id: str, title: str) -> dict[str, int]:
        """Notify subscribed PWAs that transcription and summarization finished."""
        display_title = (title or "Untitled Meeting").strip() or "Untitled Meeting"
        return await self.send_notification(
            title="Summary Ready",
            body=display_title[:160],
            url=f"/?meeting={meeting_id}",
            tag=f"meeting-{meeting_id}",
            meeting_id=meeting_id,
        )

    async def notify_meeting_failed(
        self, meeting_id: str, title: str, error_message: str
    ) -> dict[str, int]:
        """Notify subscribed PWAs that meeting processing failed."""
        display_title = (title or "Untitled Meeting").strip() or "Untitled Meeting"
        return await self.send_notification(
            title="Processing Failed",
            body=f"{display_title[:80]}: {error_message[:100]}",
            url=f"/?meeting={meeting_id}",
            tag=f"meeting-{meeting_id}",
            meeting_id=meeting_id,
        )
