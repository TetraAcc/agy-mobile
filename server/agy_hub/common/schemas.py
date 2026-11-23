"""Pydantic v2 schema definitions shared across Gateway, Node Agent, and tests."""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field


class UserPermissionGrant(BaseModel):
    node_id: str = Field(..., min_length=1, max_length=64)
    can_write: bool = True
    can_delete: bool = False


class UserProfile(BaseModel):
    id: int
    username: str
    display_name: str
    role: Literal["admin", "member"]
    is_active: bool = True
    default_node: str = ""
    allowed_nodes: list[str] = Field(default_factory=list)
    node_permissions: dict[str, UserPermissionGrant] = Field(default_factory=dict)


class LoginRequest(BaseModel):
    username: str = Field(..., min_length=1, max_length=64)
    password: str = Field(..., min_length=1, max_length=256)
    device_info: str = Field(default="", max_length=256)


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    expires_in: int
    token_type: str = "Bearer"


class LoginResponse(BaseModel):
    ok: bool = True
    user: UserProfile
    tokens: TokenPair


class RefreshRequest(BaseModel):
    refresh_token: str | None = None


class UserCreateRequest(BaseModel):
    username: str = Field(..., min_length=1, max_length=64, pattern=r"^[a-zA-Z0-9._-]+$")
    password: str = Field(..., min_length=8, max_length=256)
    display_name: str = Field(default="", max_length=128)
    role: Literal["admin", "member"] = "member"
    default_node: str = Field(default="", max_length=64)
    nodes: list[UserPermissionGrant] = Field(default_factory=list)


class UserPermissionsUpdateRequest(BaseModel):
    default_node: str | None = None
    nodes: list[UserPermissionGrant] = Field(default_factory=list)


class SessionRecordResponse(BaseModel):
    id: str
    user_id: int
    device_info: str
    created_at: float
    last_used_at: float
    expires_at: float
    revoked_at: float | None = None


class NodeStatus(BaseModel):
    id: str
    name: str
    online: bool
    engine_alive: bool
    is_local: bool = False
    last_seen: float = 0.0
    can_write: bool = False
    can_delete: bool = False


class NodesResponse(BaseModel):
    nodes: list[NodeStatus] = Field(default_factory=list)
    default_node: str = ""


class SessionSummary(BaseModel):
    id: str
    title: str
    preview: str = ""
    updated_at: str = ""
    is_pinned: bool = False
    is_running: bool = False
    workspace_path: str = ""
    root_id: str = ""


class SessionTreeResponse(BaseModel):
    projects: dict[str, list[SessionSummary]] = Field(default_factory=dict)
    general_sessions: list[SessionSummary] = Field(default_factory=list)
    engine_alive: bool = False
    running_session_ids: list[str] = Field(default_factory=list)


class ToolCallItem(BaseModel):
    name: str
    args: dict[str, Any] = Field(default_factory=dict)


class TranscriptStep(BaseModel):
    step_index: int
    source: str
    msg_type: str
    status: str
    content: str
    thinking: str = ""
    tool_calls: list[ToolCallItem] = Field(default_factory=list)
    timestamp: str = ""


class SessionMessagesResponse(BaseModel):
    session_id: str
    messages: list[TranscriptStep] = Field(default_factory=list)
    has_more: bool = False
    next_before_step: int | None = None
    is_running: bool = False


class CreateSessionRequest(BaseModel):
    content: str = Field(..., min_length=1)
    model: str | None = None
    mode: Literal["auto", "accept-edits", "plan", "turbo"] = "auto"
    workspace_path: str | None = None
    root_id: str | None = None


class CreateSessionResponse(BaseModel):
    ok: bool
    session_id: str = ""
    message: str = ""


class SendMessageRequest(BaseModel):
    content: str = Field(..., min_length=1)
    model: str | None = None
    delivery_mode: Literal["queue", "immediate"] = "immediate"


class ActionAckResponse(BaseModel):
    ok: bool
    message: str = ""
    session_id: str | None = None
    queued: bool = False
    queue_position: int = 0


class QueuedMessageItem(BaseModel):
    id: str
    content: str
    model: str | None = None
    created_at: float


class SessionQueueResponse(BaseModel):
    session_id: str
    paused: bool = False
    last_error: str = ""
    items: list[QueuedMessageItem] = Field(default_factory=list)


class UpdateQueuedMessageRequest(BaseModel):
    content: str = Field(..., min_length=1)


class QueuePauseRequest(BaseModel):
    paused: bool


class DeleteSessionResponse(BaseModel):
    ok: bool
    session_id: str
    archived: bool = True
    message: str = ""


class FileRootItem(BaseModel):
    id: str
    name: str
    path: str
    readonly: bool = False


class FileEntry(BaseModel):
    name: str
    is_dir: bool
    path: str
    size: int = 0


class FileTreeResponse(BaseModel):
    root_id: str
    root_name: str
    current_path: str
    items: list[FileEntry] = Field(default_factory=list)


class FileContentResponse(BaseModel):
    root_id: str
    path: str
    name: str
    content: str
    total_lines: int
    truncated: bool
    size: int
    mtime: float = 0.0


class WriteFileContentRequest(BaseModel):
    root_id: str = Field(..., min_length=1)
    path: str = Field(..., min_length=1)
    content: str
    expected_mtime: float | None = None


class WriteFileContentResponse(BaseModel):
    ok: bool = True
    root_id: str
    path: str
    name: str
    size: int
    total_lines: int
    mtime: float


class ToolCallOutputResponse(BaseModel):
    session_id: str
    step_index: int
    tool_calls: list[ToolCallItem] = Field(default_factory=list)
    result_step_index: int | None = None
    status: str = ""
    output: str = ""
    truncated: bool = False


class SessionArtifactItem(BaseModel):
    name: str
    rel_path: str
    root_id: str = "brain"
    size: int = 0
    updated_at: float = 0.0
    is_image: bool = False
    is_markdown: bool = False


class SessionArtifactsResponse(BaseModel):
    session_id: str
    items: list[SessionArtifactItem] = Field(default_factory=list)


class DownloadTicketRequest(BaseModel):
    root_id: str = Field(..., min_length=1)
    path: str = Field(..., min_length=1)


class DownloadTicketResponse(BaseModel):
    ticket: str
    expires_in: int
    filename: str


class UploadResponse(BaseModel):
    filename: str
    root_id: str
    path: str
    abs_path: str
    is_image: bool
    size: int


class GitDiffResponse(BaseModel):
    root_id: str
    workspace: str
    status: str
    diff: str


class InlineDiffSegment(BaseModel):
    kind: Literal["equal", "delete", "insert"]
    text: str


class SessionEditHunk(BaseModel):
    hunk_id: str
    step_index: int
    tool_name: str
    timestamp: str = ""
    start_line: int | None = None
    end_line: int | None = None
    added_lines: int = 0
    removed_lines: int = 0
    before_text: str = ""
    after_text: str = ""
    unified_diff: str = ""
    inline_segments: list[InlineDiffSegment] = Field(default_factory=list)


class SessionFileChangeSummary(BaseModel):
    file_path: str
    file_name: str
    directory: str = ""
    added_lines: int = 0
    removed_lines: int = 0
    edit_count: int = 0
    last_step_index: int = 0
    is_new_file: bool = False
    hunks: list[SessionEditHunk] = Field(default_factory=list)


class SessionChangesResponse(BaseModel):
    session_id: str
    total_files: int = 0
    total_added: int = 0
    total_removed: int = 0
    files: list[SessionFileChangeSummary] = Field(default_factory=list)


class GitRepoItem(BaseModel):
    id: str
    root_id: str
    sub_path: str = ""
    name: str
    branch: str = ""
    change_count: int = 0


class GitReposResponse(BaseModel):
    repos: list[GitRepoItem] = Field(default_factory=list)


class QuotaBucket(BaseModel):
    bucket_id: str
    display_name: str
    window: str
    remaining_fraction: float
    disabled: bool = False
    reset_time: str = ""


class QuotaGroup(BaseModel):
    display_name: str
    description: str = ""
    buckets: list[QuotaBucket] = Field(default_factory=list)


class QuotaResponse(BaseModel):
    groups: list[QuotaGroup] = Field(default_factory=list)
    description: str = ""


class WsSubscribeCmd(BaseModel):
    type: Literal["subscribe"] = "subscribe"
    session_id: str
    since_step: int | None = None


class WsUnsubscribeCmd(BaseModel):
    type: Literal["unsubscribe"] = "unsubscribe"
    session_id: str


class WsPingCmd(BaseModel):
    type: Literal["ping"] = "ping"


class WsEventStepUpsert(BaseModel):
    type: Literal["step_upsert"] = "step_upsert"
    session_id: str
    step: TranscriptStep
    is_running: bool


class WsEventSessionStatus(BaseModel):
    type: Literal["session_status"] = "session_status"
    session_id: str
    is_running: bool


class WsEventSessionTreeChanged(BaseModel):
    type: Literal["session_tree_changed"] = "session_tree_changed"


class WsEventNodeStatus(BaseModel):
    type: Literal["node_status"] = "node_status"
    nodes: list[NodeStatus]


class WsEventPong(BaseModel):
    type: Literal["pong"] = "pong"


class WsEventError(BaseModel):
    type: Literal["error"] = "error"
    code: str
    message: str
