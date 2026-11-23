"""Cryptographic helpers: scrypt password hashing, HMAC tokens, internal request signing, and file tickets."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
import time
from collections.abc import Mapping
from typing import Any

_SCRYPT_N = 16384
_SCRYPT_R = 8
_SCRYPT_P = 1
_SCRYPT_DKLEN = 32
_SCRYPT_SALT_BYTES = 16

_WEAK_SECRET_MARKERS = (
    "change_me",
    "your_secure",
    "replace_with",
    "placeholder",
    "example_secret",
    "secret_here",
    "88db71c100c87ff17fb082f95572e1fc",
)


class SecretValidationError(ValueError):
    """Raised when a required cryptographic secret is missing, short, or a placeholder."""


def validate_secret(secret: str, name: str = "secret") -> str:
    """Validate that a configured secret meets minimum length and is not a placeholder."""
    if not isinstance(secret, str):
        raise SecretValidationError(f"{name} must be a string")
    cleaned = secret.strip()
    if len(cleaned) < 24:
        raise SecretValidationError(f"{name} must be at least 24 characters long")
    lower = cleaned.lower()
    for marker in _WEAK_SECRET_MARKERS:
        if marker in lower:
            raise SecretValidationError(f"{name} appears to contain a placeholder or leaked default value")
    return cleaned


def _b64url_encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _b64url_decode(data: str) -> bytes:
    padding = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode(data + padding)


def hash_password(password: str) -> str:
    """Hash a user password using per-user salted scrypt."""
    if not password:
        raise ValueError("Password must not be empty")
    salt = secrets.token_bytes(_SCRYPT_SALT_BYTES)
    dk = hashlib.scrypt(
        password.encode("utf-8"),
        salt=salt,
        n=_SCRYPT_N,
        r=_SCRYPT_R,
        p=_SCRYPT_P,
        dklen=_SCRYPT_DKLEN,
    )
    salt_b64 = base64.b64encode(salt).decode("ascii")
    dk_b64 = base64.b64encode(dk).decode("ascii")
    return f"scrypt${_SCRYPT_N}${_SCRYPT_R}${_SCRYPT_P}${salt_b64}${dk_b64}"


def verify_password(password: str, stored: str) -> bool:
    """Verify a password against a stored scrypt hash in constant time.

    Rejects plain-text or unsalted SHA256 formats outright.
    """
    if not password or not stored or not stored.startswith("scrypt$"):
        return False
    parts = stored.split("$")
    if len(parts) != 6:
        return False
    _, n_str, r_str, p_str, salt_b64, dk_b64 = parts
    try:
        n = int(n_str)
        r = int(r_str)
        p = int(p_str)
        salt = base64.b64decode(salt_b64, validate=True)
        expected_dk = base64.b64decode(dk_b64, validate=True)
        if n <= 1 or r <= 0 or p <= 0 or not salt or not expected_dk:
            return False
        derived = hashlib.scrypt(
            password.encode("utf-8"),
            salt=salt,
            n=n,
            r=r,
            p=p,
            dklen=len(expected_dk),
        )
        return hmac.compare_digest(derived, expected_dk)
    except Exception:
        return False


def dummy_verify_password(password: str) -> None:
    """Perform constant-cost scrypt work when a username does not exist."""
    hashlib.scrypt(
        password.encode("utf-8"),
        salt=b"agy_hub_dummy_salt",
        n=_SCRYPT_N,
        r=_SCRYPT_R,
        p=_SCRYPT_P,
        dklen=_SCRYPT_DKLEN,
    )


def generate_refresh_token() -> str:
    """Generate a high-entropy opaque refresh token."""
    return secrets.token_urlsafe(48)


def hash_token(raw_token: str) -> str:
    """Hash a high-entropy random token (refresh token) for DB storage."""
    return hashlib.sha256(raw_token.encode("utf-8")).hexdigest()


def _sign_payload(payload: dict[str, Any], secret: str) -> str:
    payload_bytes = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    payload_b64 = _b64url_encode(payload_bytes)
    sig = hmac.new(secret.encode("utf-8"), payload_b64.encode("ascii"), hashlib.sha256).digest()
    return f"{payload_b64}.{_b64url_encode(sig)}"


def _verify_payload(token: str, secret: str) -> dict[str, Any] | None:
    if not token or token.count(".") != 1:
        return None
    payload_b64, sig_b64 = token.split(".", 1)
    try:
        expected_sig = hmac.new(secret.encode("utf-8"), payload_b64.encode("ascii"), hashlib.sha256).digest()
        provided_sig = _b64url_decode(sig_b64)
        if not hmac.compare_digest(expected_sig, provided_sig):
            return None
        payload = json.loads(_b64url_decode(payload_b64).decode("utf-8"))
        if not isinstance(payload, dict):
            return None
        exp = payload.get("exp")
        if not isinstance(exp, (int, float)) or exp <= time.time():
            return None
        return payload
    except Exception:
        return None


def issue_access_token(
    user_id: int,
    username: str,
    display_name: str,
    role: str,
    signing_secret: str,
    ttl_seconds: int = 1800,
) -> str:
    """Issue a signed short-lived stateless access token."""
    now = int(time.time())
    payload = {
        "typ": "access",
        "uid": user_id,
        "sub": username,
        "name": display_name,
        "role": role,
        "iat": now,
        "exp": now + ttl_seconds,
        "jti": secrets.token_hex(8),
    }
    return _sign_payload(payload, signing_secret)


def verify_access_token(token: str, signing_secret: str) -> dict[str, Any] | None:
    """Verify access token signature, type, and expiration."""
    payload = _verify_payload(token, signing_secret)
    if not payload or payload.get("typ") != "access":
        return None
    return payload


def _canonical_internal_string(method: str, path: str, ts: str, nonce: str, user: str, permissions: str) -> bytes:
    return f"{method.upper()}\n{path}\n{ts}\n{nonce}\n{user}\n{permissions}".encode("utf-8")


def sign_internal_request(
    secret: str,
    method: str,
    path: str,
    user: str,
    permissions: str,
    timestamp: int | None = None,
    nonce: str | None = None,
) -> dict[str, str]:
    """Build HMAC-signed headers for Gateway -> Node Agent internal calls."""
    ts_str = str(int(time.time()) if timestamp is None else int(timestamp))
    nonce_str = nonce or secrets.token_hex(12)
    msg = _canonical_internal_string(method, path, ts_str, nonce_str, user, permissions)
    sig = hmac.new(secret.encode("utf-8"), msg, hashlib.sha256).hexdigest()
    return {
        "X-Hub-Timestamp": ts_str,
        "X-Hub-Nonce": nonce_str,
        "X-Hub-User": user,
        "X-Hub-Permissions": permissions,
        "X-Hub-Signature": sig,
    }


def verify_internal_request(
    secret: str,
    method: str,
    path: str,
    headers: Mapping[str, str],
    max_skew_seconds: int = 60,
) -> tuple[bool, dict[str, Any] | str]:
    """Verify Gateway -> Node Agent HMAC headers and anti-replay timestamp window."""
    lowered = {k.lower(): v for k, v in headers.items()}
    ts_str = lowered.get("x-hub-timestamp", "")
    nonce = lowered.get("x-hub-nonce", "")
    user = lowered.get("x-hub-user", "")
    permissions = lowered.get("x-hub-permissions", "")
    provided_sig = lowered.get("x-hub-signature", "")

    if not ts_str or not nonce or not user or not provided_sig:
        return False, "Missing internal signature headers"

    try:
        ts_val = int(ts_str)
    except ValueError:
        return False, "Invalid timestamp header"

    if abs(time.time() - ts_val) > max_skew_seconds:
        return False, "Internal request timestamp expired"

    msg = _canonical_internal_string(method, path, ts_str, nonce, user, permissions)
    expected_sig = hmac.new(secret.encode("utf-8"), msg, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected_sig, provided_sig.lower()):
        return False, "Invalid internal request signature"

    try:
        perm_obj = json.loads(permissions) if permissions else {}
        if not isinstance(perm_obj, dict):
            perm_obj = {}
    except Exception:
        perm_obj = {}

    return True, {
        "user": user,
        "permissions": perm_obj,
        "timestamp": ts_val,
        "nonce": nonce,
    }


def issue_file_ticket(
    secret: str,
    node_id: str,
    root_id: str,
    rel_path: str,
    username: str,
    ttl_seconds: int = 60,
) -> str:
    """Issue a short-lived single-file download/media ticket."""
    now = int(time.time())
    payload = {
        "typ": "file_ticket",
        "node_id": node_id,
        "root_id": root_id,
        "rel_path": rel_path,
        "username": username,
        "iat": now,
        "exp": now + ttl_seconds,
        "nonce": secrets.token_hex(8),
    }
    return _sign_payload(payload, secret)


def verify_file_ticket(secret: str, ticket: str) -> dict[str, Any] | None:
    """Verify a short-lived single-file ticket."""
    payload = _verify_payload(ticket, secret)
    if not payload or payload.get("typ") != "file_ticket":
        return None
    return payload
