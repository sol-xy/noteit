"""Authentication routes for iOS token verification and Web UI cookie sessions."""

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status

from app.auth import (
    clear_session_cookie,
    require_auth,
    set_session_cookie,
    verify_token_constant_time,
)
from app.config import Settings, get_settings
from app.deps import limiter
from app.schemas import AuthStatusResponse, LoginRequest

router = APIRouter(prefix="/api/auth", tags=["auth"])


@router.post("/login", response_model=AuthStatusResponse)
@limiter.limit("5/minute")
async def login(
    request: Request,
    payload: LoginRequest,
    response: Response,
    settings: Settings = Depends(get_settings),
) -> AuthStatusResponse:
    if not verify_token_constant_time(payload.token.strip(), settings.auth_token):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid access token",
        )
    set_session_cookie(response, settings)
    return AuthStatusResponse(
        authenticated=True,
        auth_method="cookie",
        default_stt_provider=settings.default_stt_provider,
    )


@router.post("/logout")
async def logout(
    response: Response,
    settings: Settings = Depends(get_settings),
) -> dict[str, bool]:
    clear_session_cookie(response, settings)
    return {"ok": True}


@router.get("/me", response_model=AuthStatusResponse)
async def auth_me(
    auth_method: str = Depends(require_auth),
    settings: Settings = Depends(get_settings),
) -> AuthStatusResponse:
    return AuthStatusResponse(
        authenticated=True,
        auth_method=auth_method,
        default_stt_provider=settings.default_stt_provider,
    )
