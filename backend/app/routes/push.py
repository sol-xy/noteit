"""Web Push subscription and test notification endpoints."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request, status

from app.auth import require_auth
from app.db import Database
from app.deps import get_db, get_push_service
from app.schemas import (
    PushConfigResponse,
    PushStatusResponse,
    PushSubscriptionRequest,
    PushTestResponse,
    PushUnsubscribeRequest,
)
from app.services.push import PushService

router = APIRouter(
    prefix="/api/push",
    tags=["push"],
    dependencies=[Depends(require_auth)],
)


@router.get("/config", response_model=PushConfigResponse)
async def get_push_config(
    db: Database = Depends(get_db),
    push_service: PushService = Depends(get_push_service),
) -> PushConfigResponse:
    count = await db.count_push_subscriptions()
    return PushConfigResponse(
        enabled=push_service.is_enabled,
        public_key=push_service.public_key,
        subscription_count=count,
    )


@router.post("/subscribe", response_model=PushStatusResponse)
async def subscribe_push(
    payload: PushSubscriptionRequest,
    request: Request,
    db: Database = Depends(get_db),
    push_service: PushService = Depends(get_push_service),
) -> PushStatusResponse:
    if not push_service.is_enabled:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Push notifications are disabled on the server",
        )
    user_agent = (request.headers.get("user-agent") or "")[:300]
    await db.upsert_push_subscription(
        endpoint=payload.endpoint,
        p256dh=payload.keys.p256dh,
        auth=payload.keys.auth,
        user_agent=user_agent,
    )
    count = await db.count_push_subscriptions()
    return PushStatusResponse(subscribed=True, subscription_count=count)


@router.post("/unsubscribe", response_model=PushStatusResponse)
async def unsubscribe_push(
    payload: PushUnsubscribeRequest,
    db: Database = Depends(get_db),
) -> PushStatusResponse:
    await db.delete_push_subscription(payload.endpoint.strip())
    count = await db.count_push_subscriptions()
    return PushStatusResponse(subscribed=False, subscription_count=count)


@router.post("/test", response_model=PushTestResponse)
async def test_push(
    push_service: PushService = Depends(get_push_service),
) -> PushTestResponse:
    if not push_service.is_enabled:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Push notifications are disabled on the server",
        )
    result = await push_service.send_notification(
        title="NoteIt Notifications Active",
        body="You will be notified when meeting summaries finish.",
        url="/",
        tag="noteit-test",
    )
    return PushTestResponse(**result)
