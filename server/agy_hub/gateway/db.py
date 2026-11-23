"""SQLite database layer (hub.db) for Gateway users, node permissions, refresh sessions, and login throttling."""

from __future__ import annotations

import sqlite3
import time
from pathlib import Path
from typing import Any

from agy_hub.common.schemas import SessionRecordResponse, UserPermissionGrant, UserProfile
from agy_hub.common.security import hash_password


class HubDatabase:
    """Thread-safe SQLite store for Gateway auth and RBAC state."""

    def __init__(self, db_path: str | Path) -> None:
        self.db_path = str(db_path)
        self._is_memory = self.db_path == ":memory:"
        self._mem_conn: sqlite3.Connection | None = None
        if not self._is_memory:
            Path(self.db_path).parent.mkdir(parents=True, exist_ok=True)
        self.init_schema()

    def _open(self) -> sqlite3.Connection:
        if self._is_memory:
            if self._mem_conn is None:
                self._mem_conn = sqlite3.connect(":memory:", check_same_thread=False)
                self._mem_conn.row_factory = sqlite3.Row
                self._mem_conn.execute("PRAGMA foreign_keys=ON;")
            return self._mem_conn
        conn = sqlite3.connect(self.db_path, timeout=5.0, check_same_thread=False)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL;")
        conn.execute("PRAGMA foreign_keys=ON;")
        conn.execute("PRAGMA busy_timeout=5000;")
        return conn

    def _close(self, conn: sqlite3.Connection) -> None:
        if not self._is_memory:
            conn.close()

    def close(self) -> None:
        if self._mem_conn is not None:
            self._mem_conn.close()
            self._mem_conn = None

    def init_schema(self) -> None:
        conn = self._open()
        try:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS users (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    username TEXT NOT NULL UNIQUE,
                    display_name TEXT NOT NULL DEFAULT '',
                    password_hash TEXT NOT NULL,
                    role TEXT NOT NULL CHECK(role IN ('admin', 'member')),
                    is_active INTEGER NOT NULL DEFAULT 1,
                    default_node TEXT NOT NULL DEFAULT '',
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE IF NOT EXISTS user_node_permissions (
                    user_id INTEGER NOT NULL,
                    node_id TEXT NOT NULL,
                    can_write INTEGER NOT NULL DEFAULT 1,
                    can_delete INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (user_id, node_id),
                    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS refresh_sessions (
                    id TEXT PRIMARY KEY,
                    user_id INTEGER NOT NULL,
                    token_hash TEXT NOT NULL UNIQUE,
                    device_info TEXT NOT NULL DEFAULT '',
                    created_at REAL NOT NULL,
                    last_used_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    revoked_at REAL,
                    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS idx_refresh_sessions_user ON refresh_sessions(user_id);

                CREATE TABLE IF NOT EXISTS login_attempts (
                    key TEXT PRIMARY KEY,
                    fail_count INTEGER NOT NULL DEFAULT 0,
                    locked_until REAL NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL
                );
                """
            )
            conn.commit()
        finally:
            self._close(conn)

    def _row_to_profile(self, conn: sqlite3.Connection, row: sqlite3.Row) -> UserProfile:
        perm_rows = conn.execute(
            "SELECT node_id, can_write, can_delete FROM user_node_permissions WHERE user_id = ? ORDER BY node_id",
            (row["id"],),
        ).fetchall()
        perms = {
            p["node_id"]: UserPermissionGrant(
                node_id=p["node_id"],
                can_write=bool(p["can_write"]),
                can_delete=bool(p["can_delete"]),
            )
            for p in perm_rows
        }
        allowed = list(perms.keys())
        default_node = row["default_node"] or (allowed[0] if allowed else "")
        if allowed and default_node not in perms:
            default_node = allowed[0]
        return UserProfile(
            id=row["id"],
            username=row["username"],
            display_name=row["display_name"] or row["username"],
            role=row["role"],
            is_active=bool(row["is_active"]),
            default_node=default_node,
            allowed_nodes=allowed,
            node_permissions=perms,
        )

    def create_user(
        self,
        username: str,
        password: str,
        display_name: str = "",
        role: str = "member",
        default_node: str = "",
        grants: list[UserPermissionGrant] | None = None,
    ) -> UserProfile:
        clean_username = username.strip().lower()
        if not clean_username:
            raise ValueError("Username must not be empty")
        if role not in ("admin", "member"):
            raise ValueError("Role must be 'admin' or 'member'")
        now = time.time()
        pwd_hash = hash_password(password)
        conn = self._open()
        try:
            cur = conn.execute(
                """
                INSERT INTO users (username, display_name, password_hash, role, is_active, default_node, created_at, updated_at)
                VALUES (?, ?, ?, ?, 1, ?, ?, ?)
                """,
                (clean_username, display_name.strip() or clean_username, pwd_hash, role, default_node.strip(), now, now),
            )
            user_id = cur.lastrowid
            if grants:
                for g in grants:
                    conn.execute(
                        """
                        INSERT INTO user_node_permissions (user_id, node_id, can_write, can_delete)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(user_id, node_id) DO UPDATE SET
                            can_write = excluded.can_write,
                            can_delete = excluded.can_delete
                        """,
                        (user_id, g.node_id.strip(), int(g.can_write), int(g.can_delete)),
                    )
            conn.commit()
            row = conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
            return self._row_to_profile(conn, row)
        finally:
            self._close(conn)

    def get_user_record_by_username(self, username: str) -> dict[str, Any] | None:
        clean = username.strip().lower()
        conn = self._open()
        try:
            row = conn.execute("SELECT * FROM users WHERE username = ?", (clean,)).fetchone()
            if not row:
                return None
            profile = self._row_to_profile(conn, row)
            return {
                "profile": profile,
                "password_hash": row["password_hash"],
            }
        finally:
            self._close(conn)

    def get_user_profile(self, user_id: int) -> UserProfile | None:
        conn = self._open()
        try:
            row = conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
            if not row:
                return None
            return self._row_to_profile(conn, row)
        finally:
            self._close(conn)

    def get_user_profile_by_username(self, username: str) -> UserProfile | None:
        clean = username.strip().lower()
        conn = self._open()
        try:
            row = conn.execute("SELECT * FROM users WHERE username = ?", (clean,)).fetchone()
            if not row:
                return None
            return self._row_to_profile(conn, row)
        finally:
            self._close(conn)

    def list_users(self) -> list[UserProfile]:
        conn = self._open()
        try:
            rows = conn.execute("SELECT * FROM users ORDER BY id ASC").fetchall()
            return [self._row_to_profile(conn, r) for r in rows]
        finally:
            self._close(conn)

    def update_password(self, username: str, new_password: str) -> bool:
        clean = username.strip().lower()
        pwd_hash = hash_password(new_password)
        now = time.time()
        conn = self._open()
        try:
            cur = conn.execute(
                "UPDATE users SET password_hash = ?, updated_at = ? WHERE username = ?",
                (pwd_hash, now, clean),
            )
            conn.commit()
            return cur.rowcount > 0
        finally:
            self._close(conn)

    def set_user_active(self, username: str, is_active: bool) -> bool:
        clean = username.strip().lower()
        now = time.time()
        conn = self._open()
        try:
            cur = conn.execute(
                "UPDATE users SET is_active = ?, updated_at = ? WHERE username = ?",
                (int(is_active), now, clean),
            )
            if not is_active and cur.rowcount > 0:
                conn.execute(
                    """
                    UPDATE refresh_sessions SET revoked_at = ?
                    WHERE user_id = (SELECT id FROM users WHERE username = ?) AND revoked_at IS NULL
                    """,
                    (now, clean),
                )
            conn.commit()
            return cur.rowcount > 0
        finally:
            self._close(conn)

    def set_user_permissions(
        self,
        username: str,
        grants: list[UserPermissionGrant],
        default_node: str | None = None,
    ) -> UserProfile | None:
        clean = username.strip().lower()
        now = time.time()
        conn = self._open()
        try:
            row = conn.execute("SELECT * FROM users WHERE username = ?", (clean,)).fetchone()
            if not row:
                return None
            user_id = row["id"]
            conn.execute("DELETE FROM user_node_permissions WHERE user_id = ?", (user_id,))
            for g in grants:
                conn.execute(
                    """
                    INSERT INTO user_node_permissions (user_id, node_id, can_write, can_delete)
                    VALUES (?, ?, ?, ?)
                    """,
                    (user_id, g.node_id.strip(), int(g.can_write), int(g.can_delete)),
                )
            if default_node is not None:
                conn.execute(
                    "UPDATE users SET default_node = ?, updated_at = ? WHERE id = ?",
                    (default_node.strip(), now, user_id),
                )
            else:
                conn.execute("UPDATE users SET updated_at = ? WHERE id = ?", (now, user_id))
            conn.commit()
            updated = conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
            return self._row_to_profile(conn, updated)
        finally:
            self._close(conn)

    def grant_node(self, username: str, node_id: str, can_write: bool = True, can_delete: bool = False) -> bool:
        clean = username.strip().lower()
        conn = self._open()
        try:
            row = conn.execute("SELECT id FROM users WHERE username = ?", (clean,)).fetchone()
            if not row:
                return False
            conn.execute(
                """
                INSERT INTO user_node_permissions (user_id, node_id, can_write, can_delete)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(user_id, node_id) DO UPDATE SET
                    can_write = excluded.can_write,
                    can_delete = excluded.can_delete
                """,
                (row["id"], node_id.strip(), int(can_write), int(can_delete)),
            )
            conn.commit()
            return True
        finally:
            self._close(conn)

    def revoke_node(self, username: str, node_id: str) -> bool:
        clean = username.strip().lower()
        conn = self._open()
        try:
            row = conn.execute("SELECT id FROM users WHERE username = ?", (clean,)).fetchone()
            if not row:
                return False
            cur = conn.execute(
                "DELETE FROM user_node_permissions WHERE user_id = ? AND node_id = ?",
                (row["id"], node_id.strip()),
            )
            conn.commit()
            return cur.rowcount > 0
        finally:
            self._close(conn)

    def create_refresh_session(
        self,
        session_id: str,
        user_id: int,
        token_hash: str,
        device_info: str,
        expires_at: float,
    ) -> None:
        now = time.time()
        conn = self._open()
        try:
            conn.execute(
                """
                INSERT INTO refresh_sessions (id, user_id, token_hash, device_info, created_at, last_used_at, expires_at, revoked_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                """,
                (session_id, user_id, token_hash, device_info[:256], now, now, expires_at),
            )
            conn.commit()
        finally:
            self._close(conn)

    def get_refresh_session_by_hash(self, token_hash: str) -> dict[str, Any] | None:
        conn = self._open()
        try:
            row = conn.execute("SELECT * FROM refresh_sessions WHERE token_hash = ?", (token_hash,)).fetchone()
            return dict(row) if row else None
        finally:
            self._close(conn)

    def rotate_refresh_session(
        self,
        old_session_id: str,
        new_session_id: str,
        new_token_hash: str,
        new_expires_at: float,
        device_info: str = "",
    ) -> bool:
        now = time.time()
        conn = self._open()
        try:
            old_row = conn.execute("SELECT * FROM refresh_sessions WHERE id = ?", (old_session_id,)).fetchone()
            if not old_row or old_row["revoked_at"] is not None or old_row["expires_at"] <= now:
                return False
            cur = conn.execute(
                "UPDATE refresh_sessions SET revoked_at = ?, last_used_at = ? WHERE id = ? AND revoked_at IS NULL",
                (now, now, old_session_id),
            )
            if cur.rowcount == 0:
                conn.rollback()
                return False
            conn.execute(
                """
                INSERT INTO refresh_sessions (id, user_id, token_hash, device_info, created_at, last_used_at, expires_at, revoked_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                """,
                (
                    new_session_id,
                    old_row["user_id"],
                    new_token_hash,
                    (device_info or old_row["device_info"])[:256],
                    now,
                    now,
                    new_expires_at,
                ),
            )
            conn.commit()
            return True
        finally:
            self._close(conn)

    def revoke_refresh_session_by_hash(self, token_hash: str) -> bool:
        now = time.time()
        conn = self._open()
        try:
            cur = conn.execute(
                "UPDATE refresh_sessions SET revoked_at = ? WHERE token_hash = ? AND revoked_at IS NULL",
                (now, token_hash),
            )
            conn.commit()
            return cur.rowcount > 0
        finally:
            self._close(conn)

    def revoke_all_user_sessions(self, username: str) -> int:
        clean = username.strip().lower()
        now = time.time()
        conn = self._open()
        try:
            row = conn.execute("SELECT id FROM users WHERE username = ?", (clean,)).fetchone()
            if not row:
                return 0
            cur = conn.execute(
                "UPDATE refresh_sessions SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL",
                (now, row["id"]),
            )
            conn.commit()
            return cur.rowcount
        finally:
            self._close(conn)

    def list_user_sessions(self, username: str) -> list[SessionRecordResponse]:
        clean = username.strip().lower()
        conn = self._open()
        try:
            rows = conn.execute(
                """
                SELECT rs.* FROM refresh_sessions rs
                JOIN users u ON rs.user_id = u.id
                WHERE u.username = ?
                ORDER BY rs.created_at DESC
                """,
                (clean,),
            ).fetchall()
            return [
                SessionRecordResponse(
                    id=r["id"],
                    user_id=r["user_id"],
                    device_info=r["device_info"],
                    created_at=r["created_at"],
                    last_used_at=r["last_used_at"],
                    expires_at=r["expires_at"],
                    revoked_at=r["revoked_at"],
                )
                for r in rows
            ]
        finally:
            self._close(conn)

    def check_login_lock(self, key: str, now: float | None = None) -> float:
        ts = time.time() if now is None else now
        conn = self._open()
        try:
            row = conn.execute("SELECT locked_until FROM login_attempts WHERE key = ?", (key,)).fetchone()
            if not row:
                return 0.0
            remaining = row["locked_until"] - ts
            return max(0.0, remaining)
        finally:
            self._close(conn)

    def record_login_failure(
        self,
        key: str,
        max_failures: int = 5,
        lockout_seconds: int = 900,
        now: float | None = None,
    ) -> tuple[int, float]:
        ts = time.time() if now is None else now
        conn = self._open()
        try:
            row = conn.execute("SELECT fail_count, locked_until, updated_at FROM login_attempts WHERE key = ?", (key,)).fetchone()
            if row and row["locked_until"] > ts:
                return row["fail_count"], row["locked_until"]
            prev_count = 0
            if row and (row["locked_until"] == 0 or row["locked_until"] <= ts):
                # Reset counter if previous lockout expired
                if row["locked_until"] > 0 and row["locked_until"] <= ts:
                    prev_count = 0
                else:
                    prev_count = row["fail_count"]
            new_count = prev_count + 1
            locked_until = ts + lockout_seconds if new_count >= max_failures else 0.0
            conn.execute(
                """
                INSERT INTO login_attempts (key, fail_count, locked_until, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    fail_count = excluded.fail_count,
                    locked_until = excluded.locked_until,
                    updated_at = excluded.updated_at
                """,
                (key, new_count, locked_until, ts),
            )
            conn.commit()
            return new_count, locked_until
        finally:
            self._close(conn)

    def reset_login_failures(self, key: str) -> None:
        conn = self._open()
        try:
            conn.execute("DELETE FROM login_attempts WHERE key = ?", (key,))
            conn.commit()
        finally:
            self._close(conn)
