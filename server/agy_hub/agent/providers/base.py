"""Base engine provider with strict read-only Antigravity SQLite access and non-blocking async I/O."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import shutil
import sqlite3
from abc import ABC, abstractmethod
from pathlib import Path
from typing import Any

from agy_hub.agent.config import AgentConfig
from agy_hub.common.sandbox import RootRegistry, SandboxError
from agy_hub.common.schemas import (
    ActionAckResponse,
    CreateSessionResponse,
    DeleteSessionResponse,
    QuotaResponse,
    SessionMessagesResponse,
    SessionSummary,
    SessionTreeResponse,
    TranscriptStep,
)
from agy_hub.common.transcript import (
    clean_display_content,
    parse_project_name_and_path,
    parse_transcript_line,
)

logger = logging.getLogger(__name__)

_SESSION_ID_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$")
_NON_PROJECT_DIRS = {
    "desktop",
    "home",
    "users",
    "root",
    "workspace",
    "antigravity",
    "outside-of-project",
    "scratch",
}


class InvalidSessionIdError(ValueError):
    """Raised when a session ID contains illegal or traversal characters."""


class BaseEngineProvider(ABC):
    """Abstract base for Windows and Steam Deck Antigravity engines."""

    platform_name: str = "base"

    def __init__(self, config: AgentConfig, registry: RootRegistry) -> None:
        self.config = config
        self.registry = registry
        self._register_initial_roots()

    @property
    @abstractmethod
    def brain_dir(self) -> Path:
        """Directory storing per-session brain folders."""

    @property
    @abstractmethod
    def db_path(self) -> Path:
        """Path to Antigravity conversation_summaries.db."""

    @property
    @abstractmethod
    def default_workspace(self) -> Path:
        """Default workspace root directory."""

    @property
    def archive_file_path(self) -> Path:
        if self.config.archive_file:
            return Path(os.path.expanduser(self.config.archive_file)).resolve()
        return self.brain_dir / ".agy_hub_archived.json"

    def _register_initial_roots(self) -> None:
        for root_id, raw_path in self.config.roots.items():
            try:
                self.registry.register_root(root_id, raw_path, name=root_id)
            except SandboxError as exc:
                logger.warning("Skipping configured root %s: %s", root_id, exc)
        if "brain" not in {r.id for r in self.registry.list_roots()}:
            try:
                self.registry.register_root("brain", self.brain_dir, name="brain")
            except SandboxError:
                pass
        if "scratch" not in {r.id for r in self.registry.list_roots()}:
            try:
                self.registry.register_root("scratch", self.default_workspace, name="scratch")
            except SandboxError:
                pass

    @staticmethod
    def validate_session_id(session_id: str) -> str:
        clean = (session_id or "").strip()
        if not clean or ".." in clean or not _SESSION_ID_RE.match(clean):
            raise InvalidSessionIdError("Invalid session_id format")
        return clean

    def get_transcript_path(self, session_id: str) -> Path:
        sid = self.validate_session_id(session_id)
        return self.brain_dir / sid / ".system_generated" / "logs" / "transcript.jsonl"

    def _connect_ro(self) -> sqlite3.Connection | None:
        if not self.db_path.exists():
            return None
        uri = f"{self.db_path.resolve().as_uri()}?mode=ro"
        conn = sqlite3.connect(uri, uri=True, timeout=2.0)
        conn.execute("PRAGMA busy_timeout=2000;")
        return conn

    def _load_archived_ids(self) -> set[str]:
        path = self.archive_file_path
        if not path.exists():
            return set()
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, list):
                return {str(x) for x in data if x}
        except Exception:
            pass
        return set()

    def _save_archived_ids(self, archived: set[str]) -> None:
        path = self.archive_file_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(sorted(archived), ensure_ascii=False, indent=2), encoding="utf-8")

    def get_pinned_session_ids(self) -> set[str]:
        """Override in platform subclasses that support desktop pinned session metadata."""
        return set()

    def is_managed_process_running(self, session_id: str) -> bool:
        """Override when provider tracks local child processes."""
        return False

    def _extract_fallback_title_sync(self, cid: str) -> str | None:
        tpath = self.brain_dir / cid / ".system_generated" / "logs" / "transcript.jsonl"
        if not tpath.exists():
            return None
        thinking_question: str | None = None
        try:
            with open(tpath, "r", encoding="utf-8", errors="ignore") as f:
                for idx, line in enumerate(f):
                    if idx >= 80:
                        break
                    if not line.strip():
                        continue
                    try:
                        obj = json.loads(line)
                    except Exception:
                        continue
                    if obj.get("source") == "USER_EXPLICIT" or obj.get("type") == "USER_INPUT":
                        clean = clean_display_content(str(obj.get("content", "")))
                        if clean:
                            return clean[:32] + ("..." if len(clean) > 32 else "")
                    if not thinking_question and obj.get("type") == "PLANNER_RESPONSE":
                        thinking = str(obj.get("thinking", ""))
                        m = re.search(r'The user\'s question,\s*["“]([^"”]+)["”]', thinking)
                        if m:
                            thinking_question = m.group(1).strip()
            if thinking_question:
                return thinking_question[:32] + ("..." if len(thinking_question) > 32 else "")
        except OSError:
            pass
        return None

    def _read_transcript_tail_status_sync(self, session_id: str) -> bool:
        tpath = self.get_transcript_path(session_id)
        if not tpath.exists():
            return False
        try:
            size = tpath.stat().st_size
            read_from = max(0, size - 16384)
            with open(tpath, "rb") as f:
                f.seek(read_from)
                raw = f.read()
            text = raw.decode("utf-8", errors="replace")
            lines = text.splitlines()
            if read_from > 0 and lines:
                lines = lines[1:]
            for line_str in reversed(lines[-15:]):
                stripped = line_str.strip()
                if not stripped:
                    continue
                try:
                    obj = json.loads(stripped)
                except Exception:
                    continue
                msg_type = obj.get("type")
                if msg_type in ("USER_INPUT", "USER_EXPLICIT"):
                    return True
                status_val = obj.get("status")
                if status_val == "IN_PROGRESS":
                    return True
                if status_val in ("DONE", "ERROR"):
                    return False
        except OSError:
            pass
        return False

    def _is_session_running_sync(self, session_id: str) -> bool:
        sid = self.validate_session_id(session_id)
        if self.is_managed_process_running(sid):
            return True

        conn = self._connect_ro()
        if conn is not None:
            try:
                cur = conn.cursor()
                cols = [c[1] for c in cur.execute("PRAGMA table_info(conversation_summaries)").fetchall()]
                if cols:
                    id_col = "conversation_id" if "conversation_id" in cols else "id"
                    fields: list[str] = []
                    if "status" in cols:
                        fields.append("status")
                    if "not_fully_idle" in cols:
                        fields.append("not_fully_idle")
                    if fields:
                        row = cur.execute(
                            f"SELECT {', '.join(fields)} FROM conversation_summaries WHERE {id_col} = ?",
                            (sid,),
                        ).fetchone()
                        if row:
                            status_val = row[fields.index("status")] if "status" in fields else ""
                            idle_val = row[fields.index("not_fully_idle")] if "not_fully_idle" in fields else 0
                            if status_val == "CASCADE_RUN_STATUS_RUNNING" or idle_val == 1:
                                return True
                            if status_val == "CASCADE_RUN_STATUS_IDLE" and idle_val == 0:
                                return False
            except Exception as exc:
                logger.debug("Read-only running state lookup failed for %s: %s", sid, exc)
            finally:
                conn.close()

        return self._read_transcript_tail_status_sync(sid)

    def _get_session_tree_sync(self, engine_alive: bool) -> SessionTreeResponse:
        archived_ids = self._load_archived_ids()
        conn = self._connect_ro()
        if conn is None:
            return SessionTreeResponse(engine_alive=engine_alive)

        try:
            cur = conn.cursor()
            tables = {
                t[0] for t in cur.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
            }
            if "conversation_summaries" not in tables:
                return SessionTreeResponse(engine_alive=engine_alive)

            convo_to_project: dict[str, str] = {}
            if "conversations_fts" in tables:
                try:
                    fts_rows = cur.execute(
                        "SELECT DISTINCT conversation_id, project FROM conversations_fts "
                        "WHERE project IS NOT NULL AND project != ''"
                    ).fetchall()
                    for f_cid, f_proj in fts_rows:
                        if f_cid and f_proj:
                            convo_to_project[str(f_cid)] = str(f_proj).strip()
                except Exception as exc:
                    logger.debug("Reading conversations_fts failed: %s", exc)

            cols = [c[1] for c in cur.execute("PRAGMA table_info(conversation_summaries)").fetchall()]
            id_col = "conversation_id" if "conversation_id" in cols else "id"
            time_col = "last_modified_time" if "last_modified_time" in cols else ("updated_at" if "updated_at" in cols else "rowid")

            pid_to_project: dict[str, str] = {}
            if "project_id" in cols:
                try:
                    p_rows = cur.execute(
                        f"SELECT {id_col}, project_id FROM conversation_summaries "
                        "WHERE project_id IS NOT NULL AND project_id != '' AND project_id != 'outside-of-project'"
                    ).fetchall()
                    for p_cid, p_pid in p_rows:
                        if p_cid in convo_to_project and p_pid not in pid_to_project:
                            pid_to_project[str(p_pid)] = convo_to_project[str(p_cid)]
                except Exception:
                    pass

            where_clauses: list[str] = []
            if "parent_conversation_id" in cols:
                where_clauses.append("(parent_conversation_id IS NULL OR parent_conversation_id = '')")
            if "nesting_depth" in cols:
                where_clauses.append("(nesting_depth IS NULL OR nesting_depth = 0)")
            if "agent_name" in cols:
                where_clauses.append("(agent_name IS NULL OR agent_name = '')")
            where_sql = f"WHERE {' AND '.join(where_clauses)}" if where_clauses else ""

            select_cols = [
                id_col,
                "title" if "title" in cols else "''",
                "preview" if "preview" in cols else "''",
                "workspace_uris" if "workspace_uris" in cols else "''",
                time_col,
                "project_id" if "project_id" in cols else "''",
                "status" if "status" in cols else "''",
                "not_fully_idle" if "not_fully_idle" in cols else "0",
            ]
            query = (
                f"SELECT {', '.join(select_cols)} FROM conversation_summaries "
                f"{where_sql} ORDER BY {time_col} DESC"
            )
            rows = cur.execute(query).fetchall()
        finally:
            conn.close()

        pinned_cids = self.get_pinned_session_ids()
        projects_dict: dict[str, list[SessionSummary]] = {}
        project_latest_time: dict[str, str] = {}
        general_sessions: list[SessionSummary] = []
        running_session_ids: list[str] = []

        for r in rows:
            cid, title, preview, ws_uris, mod_time, pid, status_val, idle_val = r
            if not cid:
                continue
            cid_str = str(cid)
            if cid_str in archived_ids:
                continue

            brain_subdir = self.brain_dir / cid_str
            if not brain_subdir.exists():
                # Read-only policy: filter orphaned records in memory without writing DELETE to official DB
                continue

            display_title = str(title).strip() if title else ""
            if not display_title:
                fallback = self._extract_fallback_title_sync(cid_str)
                if fallback:
                    display_title = fallback
                elif preview and str(preview).strip():
                    clean_prev = clean_display_content(str(preview).strip())
                    display_title = clean_prev[:32] + ("..." if len(clean_prev) > 32 else "")
                else:
                    display_title = "新任务"

            if "汇报给主代理" in display_title:
                continue

            fallback_name, proj_path = parse_project_name_and_path(ws_uris)
            final_project: str | None = None
            if cid_str in convo_to_project:
                final_project = convo_to_project[cid_str]
            elif pid and str(pid) != "outside-of-project" and str(pid) in pid_to_project:
                final_project = pid_to_project[str(pid)]
            elif fallback_name:
                final_project = fallback_name

            if final_project and final_project.lower() in _NON_PROJECT_DIRS:
                final_project = None

            ws_root_id = ""
            if proj_path:
                ws_root_id = self.registry.register_workspace(proj_path) or ""

            is_running = bool(
                self.is_managed_process_running(cid_str)
                or status_val == "CASCADE_RUN_STATUS_RUNNING"
                or idle_val == 1
            )
            if is_running:
                running_session_ids.append(cid_str)

            time_str = str(mod_time).split("T")[0].split(" ")[0] if mod_time else ""
            is_pinned = cid_str in pinned_cids
            summary = SessionSummary(
                id=cid_str,
                title=display_title,
                preview=str(preview or ""),
                updated_at=time_str,
                is_pinned=is_pinned,
                is_running=is_running,
                workspace_path=proj_path or str(self.default_workspace),
                root_id=ws_root_id or "scratch",
            )

            if final_project:
                projects_dict.setdefault(final_project, []).append(summary)
                if not is_pinned and final_project not in project_latest_time:
                    project_latest_time[final_project] = str(mod_time or "")
            else:
                general_sessions.append(summary)

        for proj_name, items in projects_dict.items():
            if proj_name not in project_latest_time and items:
                project_latest_time[proj_name] = items[0].updated_at

        sorted_names = sorted(
            projects_dict.keys(),
            key=lambda p: project_latest_time.get(p, ""),
            reverse=True,
        )
        ordered_projects = {p: projects_dict[p] for p in sorted_names}

        return SessionTreeResponse(
            projects=ordered_projects,
            general_sessions=general_sessions,
            engine_alive=engine_alive,
            running_session_ids=running_session_ids,
        )

    def _get_session_messages_sync(
        self,
        session_id: str,
        before_step: int | None = None,
        limit: int = 60,
    ) -> SessionMessagesResponse:
        sid = self.validate_session_id(session_id)
        tpath = self.get_transcript_path(sid)
        is_running = self._is_session_running_sync(sid)
        if not tpath.exists():
            return SessionMessagesResponse(
                session_id=sid,
                messages=[],
                has_more=False,
                next_before_step=None,
                is_running=is_running,
            )

        steps: list[TranscriptStep] = []
        with open(tpath, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                evt = parse_transcript_line(line)
                if evt is not None:
                    if before_step is not None and evt.step_index >= before_step:
                        continue
                    steps.append(evt)

        has_more = len(steps) > limit
        sliced = steps[-limit:] if limit > 0 else steps
        next_before = sliced[0].step_index if (has_more and sliced) else None

        return SessionMessagesResponse(
            session_id=sid,
            messages=sliced,
            has_more=has_more,
            next_before_step=next_before,
            is_running=is_running,
        )

    def _archive_session_sync(self, session_id: str, purge_disk: bool = False) -> DeleteSessionResponse:
        sid = self.validate_session_id(session_id)
        archived = self._load_archived_ids()
        archived.add(sid)
        self._save_archived_ids(archived)

        if purge_disk:
            target_dir = (self.brain_dir / sid).resolve()
            if target_dir.exists() and target_dir.is_relative_to(self.brain_dir.resolve()):
                shutil.rmtree(target_dir, ignore_errors=True)

        return DeleteSessionResponse(
            ok=True,
            session_id=sid,
            archived=True,
            message="Session archived without modifying official SQLite database",
        )

    async def get_session_tree(self) -> SessionTreeResponse:
        engine_alive = await self.is_engine_alive()
        return await asyncio.to_thread(self._get_session_tree_sync, engine_alive)

    async def is_session_running(self, session_id: str) -> bool:
        return await asyncio.to_thread(self._is_session_running_sync, session_id)

    async def get_session_messages(
        self,
        session_id: str,
        before_step: int | None = None,
        limit: int = 60,
    ) -> SessionMessagesResponse:
        return await asyncio.to_thread(self._get_session_messages_sync, session_id, before_step, limit)

    async def archive_session(self, session_id: str, purge_disk: bool = False) -> DeleteSessionResponse:
        return await asyncio.to_thread(self._archive_session_sync, session_id, purge_disk)

    async def aclose(self) -> None:
        """Optional async cleanup hook for subclasses."""
        return None

    @abstractmethod
    async def is_engine_alive(self) -> bool:
        """Check whether the underlying Antigravity engine is available."""

    @abstractmethod
    async def send_message(
        self,
        session_id: str,
        content: str,
        model: str | None = None,
        workspace_path: str | None = None,
    ) -> ActionAckResponse:
        """Dispatch a user message to an existing session."""

    @abstractmethod
    async def create_session(
        self,
        content: str,
        model: str | None = None,
        mode: str = "auto",
        workspace_path: str | None = None,
    ) -> CreateSessionResponse:
        """Create and start a new session."""

    @abstractmethod
    async def stop_session(self, session_id: str) -> ActionAckResponse:
        """Interrupt a running session."""

    @abstractmethod
    async def fetch_quota(self) -> QuotaResponse:
        """Retrieve current model quota summary."""
