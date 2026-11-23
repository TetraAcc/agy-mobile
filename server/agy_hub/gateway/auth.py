"""Gateway authentication service supporting HttpOnly Web cookies and Bearer native tokens."""

from __future__ import annotations

import secrets
import time

from fastapi import HTTPException, Request, Response, WebSocket, status

from agy_hub.common.schemas import TokenPair, UserPermissionGrant, UserProfile
from agy_hub.common.security import (
    dummy_verify_password,
    generate_refresh_token,
    hash_token,
    issue_access_token,
    verify_access_token,
    verify_password,
)
from agy_hub.gateway.config import GatewayConfig
from agy_hub.gateway.db import HubDatabase

ACCESS_COOKIE_NAME = "agy_access"
REFRESH_COOKIE_NAME = "agy_refresh"


class AuthService:
    def __init__(self, db: HubDatabase, config: GatewayConfig) -> None:
        self.db = db
        self.config = config

    def login(self, username: str, password: str, client_ip: str, device_info: str = "") -> tuple[UserProfile, TokenPair]:
        clean_user = username.strip().lower()
        throttle_key = f"{client_ip}:{clean_user}"
        remaining_lock = self.db.check_login_lock(throttle_key)
        if remaining_lock > 0:
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail=f"Too many failed login attempts. Try again in {int(remaining_lock) + 1}s.",
            )

        record = self.db.get_user_record_by_username(clean_user)
        if not record:
            dummy_verify_password(password)
            _, locked_until = self.db.record_login_failure(
                throttle_key,
                max_failures=self.config.max_login_failures,
                lockout_seconds=self.config.lockout_seconds,
            )
            if locked_until > 0:
                raise HTTPException(
                    status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                    detail="Too many failed login attempts. Account temporarily locked.",
                )
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid username or password")

        profile: UserProfile = record["profile"]
        if not profile.is_active:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Account is disabled")

        if not verify_password(password, record["password_hash"]):
            _, locked_until = self.db.record_login_failure(
                throttle_key,
                max_failures=self.config.max_login_failures,
                lockout_seconds=self.config.lockout_seconds,
            )
            if locked_until > 0:
                raise HTTPException(
                    status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                    detail="Too many failed login attempts. Account temporarily locked.",
                )
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid username or password")

        self.db.reset_login_failures(throttle_key)
        tokens = self._issue_token_pair(profile, device_info=device_info)
        return profile, tokens

    def _issue_token_pair(self, profile: UserProfile, device_info: str = "") -> TokenPair:
        access_token = issue_access_token(
            user_id=profile.id,
            username=profile.username,
            display_name=profile.display_name,
            role=profile.role,
            signing_secret=self.config.signing_secret,
            ttl_seconds=self.config.access_token_ttl_seconds,
        )
        raw_refresh = generate_refresh_token()
        session_id = secrets.token_hex(16)
        expires_at = time.time() + self.config.refresh_token_ttl_seconds
        self.db.create_refresh_session(
            session_id=session_id,
            user_id=profile.id,
            token_hash=hash_token(raw_refresh),
            device_info=device_info,
            expires_at=expires_at,
        )
        return TokenPair(
            access_token=access_token,
            refresh_token=raw_refresh,
            expires_in=self.config.access_token_ttl_seconds,
        )

    def refresh(self, raw_refresh_token: str | None, device_info: str = "") -> tuple[UserProfile, TokenPair]:
        if not raw_refresh_token:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing refresh token")
        token_hash = hash_token(raw_refresh_token)
        session = self.db.get_refresh_session_by_hash(token_hash)
        if not session:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid refresh token")

        profile = self.db.get_user_profile(session["user_id"])
        if not profile or not profile.is_active:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Account inactive or missing")

        # Refresh token reuse detection: if already revoked, revoke all sessions for that user
        if session["revoked_at"] is not None:
            self.db.revoke_all_user_sessions(profile.username)
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Refresh token reuse detected")

        if session["expires_at"] <= time.time():
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Refresh token expired")

        new_raw_refresh = generate_refresh_token()
        new_session_id = secrets.token_hex(16)
        new_expires_at = time.time() + self.config.refresh_token_ttl_seconds
        rotated = self.db.rotate_refresh_session(
            old_session_id=session["id"],
            new_session_id=new_session_id,
            new_token_hash=hash_token(new_raw_refresh),
            new_expires_at=new_expires_at,
            device_info=device_info,
        )
        if not rotated:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Refresh session rotation failed")

        new_access = issue_access_token(
            user_id=profile.id,
            username=profile.username,
            display_name=profile.display_name,
            role=profile.role,
            signing_secret=self.config.signing_secret,
            ttl_seconds=self.config.access_token_ttl_seconds,
        )
        return profile, TokenPair(
            access_token=new_access,
            refresh_token=new_raw_refresh,
            expires_in=self.config.access_token_ttl_seconds,
        )

    def logout(self, raw_refresh_token: str | None) -> None:
        if raw_refresh_token:
            self.db.revoke_refresh_session_by_hash(hash_token(raw_refresh_token))

    def authenticate_token(self, raw_token: str | None) -> UserProfile | None:
        if not raw_token:
            return None
        payload = verify_access_token(raw_token, self.config.signing_secret)
        if not payload:
            return None
        uid = payload.get("uid")
        if not isinstance(uid, int):
            return None
        profile = self.db.get_user_profile(uid)
        if not profile or not profile.is_active:
            return None
        return profile

    @staticmethod
    def _extract_bearer(auth_header: str | None) -> str | None:
        if not auth_header:
            return None
        parts = auth_header.strip().split(" ", 1)
        if len(parts) == 2 and parts[0].lower() == "bearer":
            return parts[1].strip()
        return None

    def authenticate_http(self, request: Request) -> UserProfile:
        token = self._extract_bearer(request.headers.get("Authorization")) or request.cookies.get(ACCESS_COOKIE_NAME)
        profile = self.authenticate_token(token)
        if not profile:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Unauthorized")
        return profile

    def authenticate_ws(self, websocket: WebSocket) -> UserProfile | None:
        token = self._extract_bearer(websocket.headers.get("authorization")) or websocket.cookies.get(ACCESS_COOKIE_NAME)
        return self.authenticate_token(token)

    def check_node_access(
        self,
        user: UserProfile,
        node_id: str,
        require_write: bool = False,
        require_delete: bool = False,
    ) -> UserPermissionGrant:
        if node_id not in self.config.nodes:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Unknown node: {node_id}")
        grant = user.node_permissions.get(node_id)
        if not grant:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=f"Access denied to node '{node_id}'")
        if require_write and not grant.can_write:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=f"Write permission required on '{node_id}'")
        if require_delete and not grant.can_delete:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=f"Delete permission required on '{node_id}'")
        return grant

    def set_auth_cookies(self, response: Response, tokens: TokenPair) -> None:
        response.set_cookie(
            key=ACCESS_COOKIE_NAME,
            value=tokens.access_token,
            max_age=self.config.access_token_ttl_seconds,
            path="/",
            httponly=True,
            secure=self.config.cookie_secure,
            samesite="lax",
        )
        response.set_cookie(
            key=REFRESH_COOKIE_NAME,
            value=tokens.refresh_token,
            max_age=self.config.refresh_token_ttl_seconds,
            path="/api/v2/auth",
            httponly=True,
            secure=self.config.cookie_secure,
            samesite="lax",
        )

    def clear_auth_cookies(self, response: Response) -> None:
        response.delete_cookie(key=ACCESS_COOKIE_NAME, path="/")
        response.delete_cookie(key=REFRESH_COOKIE_NAME, path="/api/v2/auth")
