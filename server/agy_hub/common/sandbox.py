"""Sandboxed root registry, path traversal prevention, sensitive-file blocklist, and binary sniffing."""

from __future__ import annotations

import hashlib
import io
import os
import re
import tempfile
import urllib.parse
from pathlib import Path

from agy_hub.common.schemas import (
    FileContentResponse,
    FileEntry,
    FileRootItem,
    FileTreeResponse,
    WriteFileContentResponse,
)

SENSITIVE_PATTERNS: list[str] = [
    r"(?:^|[\\/])\.ssh(?:[\\/]|$)",
    r"(?:^|[\\/])\.gnupg(?:[\\/]|$)",
    r"(?:^|[\\/])\.aws(?:[\\/]|$)",
    r"(?:^|[\\/])\.git(?:[\\/]|$)",
    r"(?:^|[\\/])id_rsa(?:\.|$)",
    r"(?:^|[\\/])id_ed25519(?:\.|$)",
    r"(?:^|[\\/])known_hosts$",
    r"(?:^|[\\/])authorized_keys$",
    r"(?:^|[\\/])\.env(?:\.|$)",
    r"(?:^|[\\/])server_config\.json$",
    r"(?:^|[\\/])gateway_config\.json$",
    r"(?:^|[\\/])agent_config\.json$",
    r"(?:^|[\\/])sessions\.json$",
    r"(?:^|[\\/])hub\.db(?:-wal|-shm)?$",
    r"(?:^|[\\/])etc[\\/](?:shadow|passwd)$",
    r"(?:^|[\\/])Windows[\\/]System32[\\/]config(?:[\\/]|$)",
]

BINARY_EXTENSIONS: set[str] = {
    ".zip", ".tar", ".gz", ".tgz", ".bz2", ".xz", ".7z", ".rar",
    ".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".ico",
    ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx",
    ".exe", ".dll", ".so", ".dylib", ".bin", ".iso", ".apk", ".msi",
    ".pyc", ".wasm", ".class", ".o", ".a", ".lib", ".db", ".sqlite",
    ".mp3", ".wav", ".ogg", ".flac", ".mp4", ".mkv", ".avi", ".mov", ".webm",
}

_HIDDEN_LIST_IGNORE = {".env.example", ".gitignore"}
_SKIP_DIR_NAMES = {"node_modules", "build", ".dart_tool", "__pycache__", "venv", ".venv"}


class SandboxError(PermissionError):
    """Raised when a path escapes registered roots or hits sensitive files."""

    def __init__(self, message: str, status_code: int = 403) -> None:
        super().__init__(message)
        self.status_code = status_code


class BinaryFileError(ValueError):
    """Raised when trying to view a binary file as plain text."""

    def __init__(self, message: str = "Binary file cannot be rendered as text") -> None:
        super().__init__(message)
        self.status_code = 415


def is_sensitive_path(path_obj: Path) -> bool:
    """Return True if path matches any sensitive credential/config pattern."""
    raw = str(path_obj)
    norm = os.path.normcase(raw)
    for pattern in SENSITIVE_PATTERNS:
        if re.search(pattern, raw, re.IGNORECASE) or re.search(pattern, norm, re.IGNORECASE):
            return True
    return False


def is_binary_file(path_obj: Path) -> bool:
    """Detect binary file by extension and null-byte sniffing."""
    if path_obj.suffix.lower() in BINARY_EXTENSIONS:
        return True
    name_lower = path_obj.name.lower()
    if name_lower.endswith(".tar.gz"):
        return True
    try:
        with open(path_obj, "rb") as f:
            chunk = f.read(2048)
        if b"\x00" in chunk:
            return True
    except OSError:
        pass
    return False


_LINE_ANCHOR_RE = re.compile(r"#L\d+(?:-L?\d+)?$", re.IGNORECASE)


def strip_file_uri(raw_path: str) -> str:
    """Normalize and strip file:/// / file:// URI schemes and optional line anchors."""
    if "\x00" in raw_path:
        raise SandboxError("Null byte is not allowed in path")
    stripped = raw_path.strip()
    is_file_uri = stripped.lower().startswith("file://")
    if is_file_uri:
        stripped = stripped.split("#", 1)[0].split("?", 1)[0]
    cleaned = urllib.parse.unquote(stripped)
    if not is_file_uri:
        cleaned = _LINE_ANCHOR_RE.sub("", cleaned)
    if cleaned.lower().startswith("file:///"):
        rest = cleaned[8:]
        # Windows drive like file:///C:/foo -> C:/foo ; POSIX file:///home/deck -> /home/deck
        if len(rest) >= 2 and rest[1] == ":":
            return rest
        return "/" + rest
    if cleaned.lower().startswith("file://"):
        rest = cleaned[7:]
        if len(rest) >= 2 and rest[1] == ":":
            return rest
        return rest
    if len(cleaned) >= 3 and cleaned[0] == "/" and cleaned[2] == ":":
        return cleaned[1:]
    return cleaned


def _is_within_root(target: Path, root: Path) -> bool:
    norm_target = Path(os.path.normcase(str(target)))
    norm_root = Path(os.path.normcase(str(root)))
    try:
        return norm_target.is_relative_to(norm_root)
    except ValueError:
        return False


class RootRegistry:
    """Strict allowlist registry mapping root_id -> resolved directory Path."""

    def __init__(self, initial_roots: dict[str, str | Path] | None = None) -> None:
        self._roots: dict[str, tuple[str, Path, bool]] = {}
        if initial_roots:
            for root_id, path in initial_roots.items():
                self.register_root(root_id, path, name=root_id, readonly=False)

    def register_root(
        self,
        root_id: str,
        path: str | Path,
        name: str | None = None,
        readonly: bool = False,
    ) -> Path:
        expanded = os.path.expanduser(str(path))
        resolved = Path(expanded).resolve()
        if is_sensitive_path(resolved):
            raise SandboxError(f"Refusing to register sensitive root: {root_id}")
        self._roots[root_id] = (name or root_id, resolved, readonly)
        return resolved

    def register_workspace(self, workspace_path: str | Path) -> str | None:
        """Register an existing workspace path discovered from trusted local DB."""
        if not workspace_path:
            return None
        try:
            resolved = Path(os.path.expanduser(str(workspace_path))).resolve()
            if not resolved.exists() or not resolved.is_dir():
                return None
            if is_sensitive_path(resolved):
                return None
            norm = os.path.normcase(str(resolved))
            for rid, (_, existing_path, _) in self._roots.items():
                if os.path.normcase(str(existing_path)) == norm:
                    return rid
            root_id = "ws_" + hashlib.sha1(norm.encode("utf-8")).hexdigest()[:12]
            display = resolved.name or str(resolved).rstrip("\\/")
            self._roots[root_id] = (display, resolved, True)
            return root_id
        except Exception:
            return None

    def list_roots(self) -> list[FileRootItem]:
        return [
            FileRootItem(id=rid, name=name, path=str(path), readonly=readonly)
            for rid, (name, path, readonly) in self._roots.items()
        ]

    def get_root(self, root_id: str) -> tuple[str, Path, bool]:
        if root_id not in self._roots:
            raise SandboxError(f"Unknown root_id: {root_id}", status_code=404)
        return self._roots[root_id]

    def resolve_in_root(self, root_id: str, rel_path: str = "") -> Path:
        """Resolve rel_path strictly inside the specified root_id."""
        if root_id not in self._roots:
            raise SandboxError(f"Unknown root_id: {root_id}", status_code=403)
        _, root_path, _ = self._roots[root_id]

        cleaned = strip_file_uri(rel_path) if rel_path else ""
        if cleaned:
            # Disallow absolute paths or Windows drive prefixes inside rel_path
            if cleaned.startswith(("/", "\\")) or (len(cleaned) >= 2 and cleaned[1] == ":"):
                raise SandboxError("Absolute path is not allowed when root_id is specified")
            cleaned_rel = cleaned.replace("\\", "/")
            candidate = (root_path / Path(*[p for p in cleaned_rel.split("/") if p and p != "."])).resolve()
            # Also handle explicit '..' components if someone passed just '..'
            if ".." in cleaned_rel.split("/"):
                candidate = (root_path / cleaned_rel).resolve()
        else:
            candidate = root_path.resolve()

        if not _is_within_root(candidate, root_path):
            raise SandboxError("Path escapes allowed root directory")
        if is_sensitive_path(candidate):
            raise SandboxError("Access to sensitive credentials or configuration is forbidden")
        return candidate

    def resolve_media_path(self, raw_path: str, root_id: str | None = None) -> tuple[str, Path]:
        """Resolve a media path via (root_id, rel_path) or by matching an absolute/file:// path against registered roots."""
        if root_id:
            return root_id, self.resolve_in_root(root_id, raw_path)

        cleaned = strip_file_uri(raw_path)
        if not cleaned:
            raise SandboxError("Empty media path")

        candidate_input = Path(os.path.expanduser(cleaned))
        if not candidate_input.is_absolute():
            raise SandboxError("Relative media path requires root_id")

        candidate = candidate_input.resolve()
        # Match deepest registered root first
        sorted_roots = sorted(self._roots.items(), key=lambda kv: len(str(kv[1][1])), reverse=True)
        for rid, (_, root_path, _) in sorted_roots:
            if _is_within_root(candidate, root_path):
                if is_sensitive_path(candidate):
                    raise SandboxError("Access to sensitive credentials or configuration is forbidden")
                return rid, candidate

        raise SandboxError("Path is outside allowed roots")

    def list_directory(self, root_id: str, sub_path: str = "", limit: int = 200) -> FileTreeResponse:
        root_name, root_path, _ = self.get_root(root_id)
        target_dir = self.resolve_in_root(root_id, sub_path)
        if not target_dir.exists() or not target_dir.is_dir():
            return FileTreeResponse(
                root_id=root_id,
                root_name=root_name,
                current_path=sub_path.replace("\\", "/").strip("/"),
                items=[],
            )

        rel_base = os.path.relpath(target_dir, root_path)
        norm_rel_base = "" if rel_base == "." else rel_base.replace("\\", "/")

        items: list[FileEntry] = []
        with os.scandir(target_dir) as it:
            for entry in it:
                if entry.name.startswith(".") and entry.name not in _HIDDEN_LIST_IGNORE:
                    continue
                if entry.name in _SKIP_DIR_NAMES:
                    continue
                entry_path = Path(entry.path).resolve()
                if not _is_within_root(entry_path, root_path) or is_sensitive_path(entry_path):
                    continue
                try:
                    is_dir = entry.is_dir(follow_symlinks=False)
                    rel_item = f"{norm_rel_base}/{entry.name}" if norm_rel_base else entry.name
                    size = 0 if is_dir else entry.stat(follow_symlinks=False).st_size
                    items.append(FileEntry(name=entry.name, is_dir=is_dir, path=rel_item, size=size))
                except OSError:
                    continue

        items.sort(key=lambda x: (not x.is_dir, x.name.lower()))
        return FileTreeResponse(
            root_id=root_id,
            root_name=root_name,
            current_path=norm_rel_base,
            items=items[:limit],
        )

    def read_text_file(
        self,
        root_id: str,
        rel_path: str,
        max_lines: int = 2000,
        max_bytes: int = 262144,
    ) -> FileContentResponse:
        target = self.resolve_in_root(root_id, rel_path)
        if not target.exists() or not target.is_file():
            raise SandboxError("File does not exist", status_code=404)
        if is_binary_file(target):
            raise BinaryFileError("Binary file cannot be displayed as text; please download it instead")

        size = target.stat().st_size
        lines: list[str] = []
        truncated = False
        read_bytes = 0
        with open(target, "r", encoding="utf-8", errors="replace") as f:
            for idx, line in enumerate(f):
                if idx >= max_lines or read_bytes >= max_bytes:
                    truncated = True
                    break
                lines.append(line)
                read_bytes += len(line.encode("utf-8", errors="replace"))

        total_lines = len(lines)
        if truncated:
            # Count remaining lines cheaply up to a sane cap or exact count
            with open(target, "r", encoding="utf-8", errors="replace") as f:
                total_lines = sum(1 for _ in f)

        _, root_path, _ = self.get_root(root_id)
        norm_rel = os.path.relpath(target, root_path).replace("\\", "/")
        return FileContentResponse(
            root_id=root_id,
            path=norm_rel,
            name=target.name,
            content="".join(lines),
            total_lines=total_lines,
            truncated=truncated,
            size=size,
            mtime=target.stat().st_mtime,
        )

    def write_text_file(
        self,
        root_id: str,
        rel_path: str,
        content: str,
        expected_mtime: float | None = None,
        max_bytes: int = 1048576,
    ) -> WriteFileContentResponse:
        """Atomically overwrite an existing UTF-8 text file inside root_id after sandbox and mtime checks."""
        target = self.resolve_in_root(root_id, rel_path)
        _, root_path, _ = self.get_root(root_id)
        norm_rel = os.path.relpath(target, root_path).replace("\\", "/")

        if root_id == "brain":
            rel_parts = set(Path(norm_rel).parts)
            if ".system_generated" in rel_parts or ".user_uploaded" in rel_parts:
                raise SandboxError("System transcript files are read-only", status_code=403)

        name_lower = target.name.lower()
        if "\x00" in content or target.suffix.lower() in BINARY_EXTENSIONS or name_lower.endswith(".tar.gz"):
            raise BinaryFileError("Binary file cannot be edited as text")

        encoded = content.encode("utf-8")
        if len(encoded) > max_bytes:
            raise SandboxError(f"File content exceeds max allowed size ({max_bytes} bytes)", status_code=413)

        if not target.exists() or not target.is_file():
            raise SandboxError("File does not exist", status_code=404)

        stat_before = target.stat()
        if expected_mtime is not None and abs(stat_before.st_mtime - expected_mtime) > 0.05:
            raise SandboxError("File has been modified on disk; reload before saving", status_code=409)

        tmp_path: str | None = None
        try:
            fd, tmp_path = tempfile.mkstemp(prefix=".agy_edit_", dir=str(target.parent))
            with os.fdopen(fd, "wb") as handle:
                handle.write(encoded)
                handle.flush()
            os.replace(tmp_path, target)
            tmp_path = None
        finally:
            if tmp_path and os.path.exists(tmp_path):
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass

        stat_after = target.stat()
        total_lines = sum(1 for _ in io.StringIO(content))
        return WriteFileContentResponse(
            ok=True,
            root_id=root_id,
            path=norm_rel,
            name=target.name,
            size=len(encoded),
            total_lines=total_lines,
            mtime=stat_after.st_mtime,
        )
