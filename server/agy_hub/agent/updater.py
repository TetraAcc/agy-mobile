"""Controlled self-update service for AGY Node Agent."""

from __future__ import annotations

import asyncio
import hashlib
import os
import re
import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path

from agy_hub import __version__
from agy_hub.common.schemas import NodeUpdateApplyResponse, NodeUpdateStatusResponse

_VERSION_RE = re.compile(r'__version__\s*=\s*["\']([^"\']+)["\']')
_TRANSIENT_GIT_NET_KEYWORDS = (
    "connection was reset",
    "connection reset",
    "recv failure",
    "unexpected eof",
    "early eof",
    "ssl",
    "tls",
    "http/2",
    "http2",
    "curl 56",
    "curl 35",
    "curl 28",
    "curl 52",
    "timed out",
    "timeout",
    "unable to access",
    "could not resolve",
    "empty reply",
)


def _default_repo_dir() -> Path:
    # server/agy_hub/agent/updater.py -> repo root is 4 levels up
    return Path(__file__).resolve().parents[3]


def _sha256_file(path: Path) -> str:
    if not path.is_file():
        return ""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _read_disk_version(repo_dir: Path) -> str:
    init_py = repo_dir / "server" / "agy_hub" / "__init__.py"
    if not init_py.is_file():
        return __version__
    try:
        text = init_py.read_text(encoding="utf-8", errors="replace")
        m = _VERSION_RE.search(text)
        if m:
            return m.group(1).strip()
    except Exception:
        pass
    return __version__


class NodeSelfUpdater:
    """Safely checks and fast-forwards the local git checkout for Node Agent."""

    _fetch_retry_delays: tuple[float, ...] = (0.6, 1.2)

    def __init__(
        self,
        repo_dir: Path | None = None,
        python_executable: str | None = None,
        exit_callback: Callable[[], None] | None = None,
    ) -> None:
        self.repo_dir = (repo_dir or _default_repo_dir()).resolve()
        self.python_executable = python_executable or sys.executable
        self._exit_callback = exit_callback or (lambda: os._exit(0))
        self._lock = asyncio.Lock()

    def _run_git(self, args: list[str], timeout: float = 25.0) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *args],
            cwd=str(self.repo_dir),
            env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            check=False,
        )

    def _is_git_repo(self) -> bool:
        if not (self.repo_dir / ".git").exists():
            return False
        res = self._run_git(["rev-parse", "--is-inside-work-tree"], timeout=8.0)
        return res.returncode == 0 and res.stdout.strip().lower() == "true"

    @staticmethod
    def _is_transient_network_error(err: str) -> bool:
        low = err.lower()
        return any(kw in low for kw in _TRANSIENT_GIT_NET_KEYWORDS)

    def _fetch_origin(self) -> str:
        attempts: list[tuple[list[str], float]] = [
            (["fetch", "--quiet", "origin"], 20.0),
            (["-c", "http.version=HTTP/1.1", "fetch", "--quiet", "origin"], 20.0),
            (
                [
                    "-c",
                    "http.version=HTTP/1.1",
                    "-c",
                    "http.lowSpeedLimit=0",
                    "-c",
                    "http.lowSpeedTime=999999",
                    "fetch",
                    "--quiet",
                    "origin",
                ],
                25.0,
            ),
        ]
        last_err = ""
        for idx, (args, timeout) in enumerate(attempts):
            timed_out = False
            try:
                res = self._run_git(args, timeout=timeout)
                if res.returncode == 0:
                    return ""
                last_err = (res.stderr or res.stdout).strip()
            except subprocess.TimeoutExpired:
                timed_out = True
                last_err = "git fetch 超时"

            has_more = idx + 1 < len(attempts)
            if has_more and (timed_out or self._is_transient_network_error(last_err)):
                delay = self._fetch_retry_delays[min(idx, len(self._fetch_retry_delays) - 1)]
                if delay > 0:
                    time.sleep(delay)
                continue
            break
        return last_err

    def _get_branch_and_commits(self, fetch: bool) -> dict[str, object]:
        branch_res = self._run_git(["rev-parse", "--abbrev-ref", "HEAD"], timeout=8.0)
        branch = branch_res.stdout.strip() if branch_res.returncode == 0 else ""

        local_res = self._run_git(["rev-parse", "--short", "HEAD"], timeout=8.0)
        local_commit = local_res.stdout.strip() if local_res.returncode == 0 else ""

        status_res = self._run_git(["status", "--porcelain", "--untracked-files=no"], timeout=8.0)
        dirty = bool(status_res.stdout.strip()) if status_res.returncode == 0 else True

        fetch_error = self._fetch_origin() if fetch else ""

        upstream_ref = "@{u}"
        up_res = self._run_git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], timeout=8.0)
        if up_res.returncode == 0 and up_res.stdout.strip():
            upstream_ref = up_res.stdout.strip()
        elif branch and branch != "HEAD":
            upstream_ref = f"origin/{branch}"
        else:
            upstream_ref = "origin/main"

        remote_res = self._run_git(["rev-parse", "--short", upstream_ref], timeout=8.0)
        remote_commit = remote_res.stdout.strip() if remote_res.returncode == 0 else ""

        behind_count = 0
        if remote_commit:
            cnt_res = self._run_git(["rev-list", "--count", f"HEAD..{upstream_ref}"], timeout=8.0)
            if cnt_res.returncode == 0:
                try:
                    behind_count = int(cnt_res.stdout.strip())
                except ValueError:
                    behind_count = 0

        return {
            "branch": branch,
            "local_commit": local_commit,
            "remote_commit": remote_commit,
            "upstream_ref": upstream_ref,
            "behind_count": behind_count,
            "dirty": dirty,
            "fetch_error": fetch_error,
        }

    def _check_sync(self, *, fetch: bool, running_sessions: int) -> NodeUpdateStatusResponse:
        if not self._is_git_repo():
            return NodeUpdateStatusResponse(
                current_version=__version__,
                git_available=False,
                running_sessions=running_sessions,
                can_update=False,
                update_available=False,
                message="当前节点不是 git 仓库部署，暂不支持远程自更新",
            )

        info = self._get_branch_and_commits(fetch=fetch)
        branch = str(info["branch"])
        local_commit = str(info["local_commit"])
        remote_commit = str(info["remote_commit"])
        behind_count = int(info["behind_count"])
        dirty = bool(info["dirty"])
        fetch_error = str(info["fetch_error"])

        update_available = behind_count > 0
        if dirty:
            msg = "检测到工作区存在未提交改动，已锁定自动更新以防覆盖本地代码"
            can_update = False
        elif fetch_error:
            if update_available:
                msg = f"拉取远端状态失败（{fetch_error}），但本地已有 {behind_count} 个待更新提交，可尝试直接更新"
                can_update = True
            else:
                msg = f"拉取远端状态失败: {fetch_error}"
                can_update = False
        elif not update_available:
            msg = "当前已是最新版本"
            can_update = False
        elif running_sessions > 0:
            msg = f"发现 {behind_count} 个新提交，但当前有 {running_sessions} 个会话正在运行"
            can_update = True
        else:
            msg = f"发现 {behind_count} 个新提交，可一键更新"
            can_update = True

        return NodeUpdateStatusResponse(
            current_version=__version__,
            git_available=True,
            branch=branch,
            local_commit=local_commit,
            remote_commit=remote_commit,
            behind_count=behind_count,
            dirty=dirty,
            running_sessions=running_sessions,
            update_available=update_available,
            can_update=can_update,
            message=msg,
        )

    async def check_update(self, *, fetch: bool = True, running_sessions: int = 0) -> NodeUpdateStatusResponse:
        async with self._lock:
            return await asyncio.to_thread(
                self._check_sync,
                fetch=fetch,
                running_sessions=running_sessions,
            )

    def _apply_sync(self, *, running_sessions: int, force: bool) -> NodeUpdateApplyResponse:
        if not self._is_git_repo():
            return NodeUpdateApplyResponse(
                ok=False,
                from_version=__version__,
                to_version=__version__,
                message="当前节点不是 git 仓库部署，无法远程自动更新",
            )

        info = self._get_branch_and_commits(fetch=True)
        behind_count = int(info["behind_count"])
        if info["fetch_error"] and behind_count <= 0:
            return NodeUpdateApplyResponse(
                ok=False,
                from_version=__version__,
                to_version=__version__,
                message=f"连接远端仓库失败: {info['fetch_error']}",
            )
        if info["dirty"]:
            return NodeUpdateApplyResponse(
                ok=False,
                from_version=__version__,
                to_version=__version__,
                message="工作区存在未提交改动，已中止更新以防覆盖本地代码",
            )
        if running_sessions > 0 and not force:
            return NodeUpdateApplyResponse(
                ok=False,
                from_version=__version__,
                to_version=__version__,
                message=f"当前有 {running_sessions} 个会话正在运行，请等待结束或开启强制更新",
            )

        before_commit = str(info["local_commit"])
        if behind_count <= 0:
            return NodeUpdateApplyResponse(
                ok=True,
                updated=False,
                restarting=False,
                from_version=__version__,
                to_version=__version__,
                commit=before_commit,
                message="当前已是最新版本，无需重启",
            )

        pyproject = self.repo_dir / "server" / "pyproject.toml"
        deps_before = _sha256_file(pyproject)

        upstream_ref = str(info["upstream_ref"])
        try:
            merge_res = self._run_git(["merge", "--ff-only", upstream_ref], timeout=20.0)
        except subprocess.TimeoutExpired:
            return NodeUpdateApplyResponse(
                ok=False,
                from_version=__version__,
                to_version=__version__,
                message="git merge 超时，请稍后重试",
            )

        if merge_res.returncode != 0:
            err = (merge_res.stderr or merge_res.stdout).strip()
            return NodeUpdateApplyResponse(
                ok=False,
                from_version=__version__,
                to_version=__version__,
                message=f"无法快进更新: {err}",
            )

        deps_after = _sha256_file(pyproject)
        deps_installed = False
        if deps_before != deps_after and pyproject.is_file():
            try:
                pip_res = subprocess.run(
                    [self.python_executable, "-m", "pip", "install", "-e", str(pyproject.parent), "--quiet"],
                    cwd=str(self.repo_dir),
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    timeout=180.0,
                    check=False,
                )
                if pip_res.returncode != 0:
                    err = (pip_res.stderr or pip_res.stdout).strip()
                    return NodeUpdateApplyResponse(
                        ok=False,
                        from_version=__version__,
                        to_version=_read_disk_version(self.repo_dir),
                        message=f"代码已拉取，但依赖安装失败: {err}",
                    )
                deps_installed = True
            except subprocess.TimeoutExpired:
                return NodeUpdateApplyResponse(
                    ok=False,
                    from_version=__version__,
                    to_version=_read_disk_version(self.repo_dir),
                    message="代码已拉取，但依赖安装超时",
                )

        after_commit_res = self._run_git(["rev-parse", "--short", "HEAD"], timeout=8.0)
        after_commit = after_commit_res.stdout.strip() if after_commit_res.returncode == 0 else before_commit
        new_version = _read_disk_version(self.repo_dir)
        changed = after_commit != before_commit
        suffix = "（已同步依赖）" if deps_installed else ""
        return NodeUpdateApplyResponse(
            ok=True,
            updated=changed,
            restarting=changed,
            from_version=__version__,
            to_version=new_version,
            commit=after_commit,
            message=(
                f"更新已就绪（v{__version__} → v{new_version}）{suffix}，节点正在重启..."
                if changed
                else "当前已是最新版本，无需重启"
            ),
        )

    async def apply_update(self, *, running_sessions: int = 0, force: bool = False) -> NodeUpdateApplyResponse:
        async with self._lock:
            return await asyncio.to_thread(
                self._apply_sync,
                running_sessions=running_sessions,
                force=force,
            )

    def schedule_restart(self, delay_seconds: float = 0.8) -> asyncio.Task[None]:
        async def _exit_soon() -> None:
            await asyncio.sleep(max(0.05, delay_seconds))
            self._exit_callback()

        return asyncio.create_task(_exit_soon())
