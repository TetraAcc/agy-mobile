"""Tests for cryptographic primitives, internal signatures, file tickets, and path sandbox."""

from __future__ import annotations

import hashlib
import os
import time
from pathlib import Path

import pytest

from agy_hub.common.sandbox import BinaryFileError, RootRegistry, SandboxError, is_binary_file
from agy_hub.common.security import (
    SecretValidationError,
    hash_password,
    issue_access_token,
    issue_file_ticket,
    sign_internal_request,
    validate_secret,
    verify_access_token,
    verify_file_ticket,
    verify_internal_request,
    verify_password,
)


def test_scrypt_password_hashing_and_rejection() -> None:
    h1 = hash_password("StrongPass!2026")
    h2 = hash_password("StrongPass!2026")
    assert h1.startswith("scrypt$")
    assert h1 != h2  # unique per-user random salt
    assert verify_password("StrongPass!2026", h1) is True
    assert verify_password("WrongPass!2026", h1) is False

    # Reject unsalted SHA256 and plaintext formats
    unsalted = hashlib.sha256(b"StrongPass!2026").hexdigest()
    assert verify_password("StrongPass!2026", unsalted) is False
    assert verify_password("StrongPass!2026", "StrongPass!2026") is False


def test_validate_secret_rejects_short_or_placeholder() -> None:
    with pytest.raises(SecretValidationError):
        validate_secret("short", "signing_secret")
    with pytest.raises(SecretValidationError):
        validate_secret("change_me_to_something_longer_than_24", "signing_secret")
    with pytest.raises(SecretValidationError):
        validate_secret("88db71c100c87ff17fb082f95572e1fc", "internal_secret")
    valid = validate_secret("a_real_high_entropy_secret_value_123456", "signing_secret")
    assert valid == "a_real_high_entropy_secret_value_123456"


def test_access_token_and_internal_request_hmac() -> None:
    secret = "unit_test_secret_key_that_is_over_32_chars"
    tok = issue_access_token(1, "alice", "Alice", "member", secret, ttl_seconds=60)
    claims = verify_access_token(tok, secret)
    assert claims is not None
    assert claims["sub"] == "alice"
    assert verify_access_token(tok + "x", secret) is None

    headers = sign_internal_request(
        secret=secret,
        method="GET",
        path="/agent/sessions",
        user="alice",
        permissions='{"can_write":true,"can_delete":false}',
    )
    ok, info = verify_internal_request(secret, "GET", "/agent/sessions", headers)
    assert ok is True
    assert isinstance(info, dict)
    assert info["user"] == "alice"
    assert info["permissions"]["can_write"] is True

    # Tampered path fails
    ok_bad, _ = verify_internal_request(secret, "GET", "/agent/quota", headers)
    assert ok_bad is False

    # Expired timestamp fails anti-replay
    old_headers = sign_internal_request(
        secret=secret,
        method="GET",
        path="/agent/sessions",
        user="alice",
        permissions="{}",
        timestamp=int(time.time()) - 120,
    )
    ok_exp, reason = verify_internal_request(secret, "GET", "/agent/sessions", old_headers, max_skew_seconds=60)
    assert ok_exp is False
    assert "expired" in str(reason).lower()


def test_file_ticket_issue_verify_and_expiry() -> None:
    secret = "unit_test_secret_key_that_is_over_32_chars"
    ticket = issue_file_ticket(secret, "windows", "scratch", "a/b.txt", "alice", ttl_seconds=30)
    data = verify_file_ticket(secret, ticket)
    assert data is not None
    assert data["node_id"] == "windows"
    assert data["rel_path"] == "a/b.txt"

    expired = issue_file_ticket(secret, "windows", "scratch", "a/b.txt", "alice", ttl_seconds=-5)
    assert verify_file_ticket(secret, expired) is None
    assert verify_file_ticket(secret, ticket + "tamper") is None


def test_sandbox_traversal_and_sensitive_blocklist(tmp_path: Path) -> None:
    root = tmp_path / "workspace"
    root.mkdir()
    outside = tmp_path / "outside.txt"
    outside.write_text("secret outside", encoding="utf-8")

    (root / "hello.py").write_text("print('ok')\n", encoding="utf-8")
    (root / ".env").write_text("API_KEY=secret\n", encoding="utf-8")
    (root / "sessions.json").write_text("{}", encoding="utf-8")
    (root / "gateway_config.json").write_text("{}", encoding="utf-8")
    (root / "hub.db").write_text("db", encoding="utf-8")
    ssh_dir = root / ".ssh"
    ssh_dir.mkdir()
    (ssh_dir / "id_rsa").write_text("PRIVATE KEY", encoding="utf-8")

    reg = RootRegistry({"ws": root})

    # Traversal attempts
    for bad in ("../outside.txt", "..\\outside.txt", "%2e%2e/outside.txt", str(outside), "/etc/passwd"):
        with pytest.raises(SandboxError):
            reg.resolve_in_root("ws", bad)

    # Sensitive files blocked even when inside root
    for sens in (".env", "sessions.json", "gateway_config.json", "hub.db", ".ssh/id_rsa"):
        with pytest.raises(SandboxError):
            reg.resolve_in_root("ws", sens)

    # Valid read
    content = reg.read_text_file("ws", "hello.py")
    assert "print('ok')" in content.content

    # Media path strips file:/// and line anchors and rejects outside paths
    file_uri = (root / "hello.py").as_uri()
    rid, resolved = reg.resolve_media_path(file_uri)
    assert rid == "ws"
    assert resolved == (root / "hello.py").resolve()
    rid_anchor, resolved_anchor = reg.resolve_media_path(f"{file_uri}#L1-L20")
    assert rid_anchor == "ws"
    assert resolved_anchor == (root / "hello.py").resolve()
    assert reg.resolve_in_root("ws", "hello.py#L1-L5") == (root / "hello.py").resolve()

    with pytest.raises(SandboxError):
        reg.resolve_media_path(outside.as_uri())

    # Binary null-byte sniffing even on .txt extension
    bin_txt = root / "nulldata.txt"
    bin_txt.write_bytes(b"abc\x00\x01\x02def")
    assert is_binary_file(bin_txt) is True
    with pytest.raises(BinaryFileError):
        reg.read_text_file("ws", "nulldata.txt")

    # Symlink escape test (if OS privileges allow creating symlinks)
    link_path = root / "escape_link.txt"
    try:
        os.symlink(outside, link_path)
    except OSError:
        pass
    else:
        with pytest.raises(SandboxError):
            reg.resolve_in_root("ws", "escape_link.txt")
