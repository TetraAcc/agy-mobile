"""Cross-platform true PTY terminal sessions (POSIX pty + Windows ConPTY via pywinpty)."""

from __future__ import annotations

import asyncio
import codecs
import logging
import os
import shutil
import signal
import struct
import subprocess
import sys
import threading
from collections.abc import Callable
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)


class TerminalUnavailableError(RuntimeError):
    """Raised when PTY support cannot be initialized on the host."""


def _clamp_dimensions(cols: int, rows: int) -> tuple[int, int]:
    return max(20, min(300, int(cols))), max(8, min(120, int(rows)))


def _resolve_shell(platform_name: str) -> tuple[list[str], str]:
    if sys.platform == "win32":
        pwsh = shutil.which("pwsh")
        if pwsh:
            return [pwsh, "-NoLogo"], "pwsh"
        ps = shutil.which("powershell.exe") or shutil.which("powershell")
        if ps:
            return [ps, "-NoLogo"], "powershell"
        comspec = os.environ.get("COMSPEC") or "cmd.exe"
        return [comspec], Path(comspec).stem

    candidates = [
        os.environ.get("SHELL", "").strip(),
        shutil.which("bash") or "",
        "/bin/bash",
        shutil.which("zsh") or "",
        "/bin/sh",
    ]
    for cand in candidates:
        if cand and os.path.isfile(cand) and os.access(cand, os.X_OK):
            name = Path(cand).name
            # Use interactive shell so user PATH (~/.local/bin/agy) and aliases work smoothly
            if name in ("bash", "zsh"):
                return [cand, "-i"], name
            return [cand], name
    return ["/bin/sh"], "sh"


def _build_pty_env() -> dict[str, str]:
    env = os.environ.copy()
    env.setdefault("TERM", "xterm-256color")
    env.setdefault("COLORTERM", "truecolor")
    if sys.platform != "win32":
        env.setdefault("LANG", "C.UTF-8")
        local_bin = os.path.expanduser("~/.local/bin")
        cur_path = env.get("PATH", "")
        if local_bin and local_bin not in cur_path.split(os.pathsep):
            env["PATH"] = f"{local_bin}{os.pathsep}{cur_path}" if cur_path else local_bin
    return env


class PtySession:
    """Single interactive PTY session bridging shell I/O to asyncio callbacks."""

    def __init__(
        self,
        *,
        cwd: Path,
        cols: int = 96,
        rows: int = 28,
        platform_name: str = "",
    ) -> None:
        self.cwd = cwd if (cwd.exists() and cwd.is_dir()) else Path.home()
        self.cols, self.rows = _clamp_dimensions(cols, rows)
        self.platform_name = platform_name or ("windows" if sys.platform == "win32" else "linux")
        self.shell_name = ""
        self._closed = False
        self._loop: asyncio.AbstractEventLoop | None = None
        self._on_output: Callable[[str], None] | None = None
        self._on_exit: Callable[[int], None] | None = None

        # POSIX handles
        self._master_fd: int | None = None
        self._posix_proc: subprocess.Popen[bytes] | None = None
        self._utf8_decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")

        # Windows ConPTY handles
        self._win_proc: Any = None
        self._win_thread: threading.Thread | None = None

    def start(
        self,
        loop: asyncio.AbstractEventLoop,
        on_output: Callable[[str], None],
        on_exit: Callable[[int], None],
    ) -> None:
        self._loop = loop
        self._on_output = on_output
        self._on_exit = on_exit
        if sys.platform == "win32":
            self._start_windows()
        else:
            self._start_posix()

    def _start_posix(self) -> None:
        import fcntl
        import pty
        import termios

        argv, shell_name = _resolve_shell(self.platform_name)
        self.shell_name = shell_name
        master_fd, slave_fd = pty.openpty()
        try:
            winsize = struct.pack("HHHH", self.rows, self.cols, 0, 0)
            fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, winsize)
            fcntl.ioctl(master_fd, termios.TIOCSWINSZ, winsize)
            proc = subprocess.Popen(
                argv,
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                cwd=str(self.cwd),
                env=_build_pty_env(),
                start_new_session=True,
                close_fds=True,
            )
        except Exception:
            os.close(master_fd)
            os.close(slave_fd)
            raise
        finally:
            try:
                os.close(slave_fd)
            except OSError:
                pass

        os.set_blocking(master_fd, False)
        self._master_fd = master_fd
        self._posix_proc = proc
        assert self._loop is not None
        self._loop.add_reader(master_fd, self._on_posix_readable)

    def _on_posix_readable(self) -> None:
        if self._closed or self._master_fd is None:
            return
        try:
            chunk = os.read(self._master_fd, 4096)
        except BlockingIOError:
            return
        except OSError:
            chunk = b""

        if not chunk:
            code = 0
            if self._posix_proc is not None:
                rc = self._posix_proc.poll()
                if rc is not None:
                    code = int(rc)
            self._finish_with_exit(code)
            return

        text = self._utf8_decoder.decode(chunk, final=False)
        if text and self._on_output is not None:
            self._on_output(text)

    def _start_windows(self) -> None:
        try:
            from winpty import PtyProcess
        except Exception as exc:
            raise TerminalUnavailableError(
                "Windows 终端需要安装 pywinpty（请在后端 venv 中运行 pip install pywinpty）"
            ) from exc

        argv, shell_name = _resolve_shell(self.platform_name)
        self.shell_name = shell_name
        try:
            proc = PtyProcess.spawn(
                argv,
                cwd=str(self.cwd),
                env=_build_pty_env(),
                dimensions=(self.rows, self.cols),
            )
        except Exception as exc:
            raise TerminalUnavailableError(f"启动 Windows ConPTY 失败: {exc}") from exc

        self._win_proc = proc
        t = threading.Thread(target=self._windows_read_loop, name="agy-winpty-reader", daemon=True)
        self._win_thread = t
        t.start()

    def _windows_read_loop(self) -> None:
        proc = self._win_proc
        loop = self._loop
        if proc is None or loop is None:
            return
        exit_code = 0
        try:
            while not self._closed:
                try:
                    data = proc.read(4096)
                except EOFError:
                    break
                except Exception:
                    break
                if not data:
                    if not proc.isalive():
                        break
                    continue
                if isinstance(data, bytes):
                    text = data.decode("utf-8", errors="replace")
                else:
                    text = str(data)
                if text and not self._closed and self._on_output is not None:
                    try:
                        loop.call_soon_threadsafe(self._on_output, text)
                    except RuntimeError:
                        break
        finally:
            try:
                if proc.exitstatus is not None:
                    exit_code = int(proc.exitstatus)
            except Exception:
                exit_code = 0
            if not self._closed:
                try:
                    loop.call_soon_threadsafe(self._finish_with_exit, exit_code)
                except RuntimeError:
                    pass

    def _finish_with_exit(self, exit_code: int) -> None:
        if self._closed:
            return
        cb = self._on_exit
        self.close()
        if cb is not None:
            cb(exit_code)

    def write(self, data: str) -> None:
        if self._closed or not data:
            return
        if sys.platform == "win32":
            if self._win_proc is not None:
                try:
                    self._win_proc.write(data)
                except Exception as exc:
                    logger.debug("winpty write failed: %s", exc)
            return
        if self._master_fd is not None:
            try:
                os.write(self._master_fd, data.encode("utf-8", errors="replace"))
            except OSError as exc:
                logger.debug("posix pty write failed: %s", exc)

    def resize(self, cols: int, rows: int) -> None:
        if self._closed:
            return
        c, r = _clamp_dimensions(cols, rows)
        self.cols, self.rows = c, r
        if sys.platform == "win32":
            if self._win_proc is not None:
                try:
                    self._win_proc.setwinsize(r, c)
                except Exception as exc:
                    logger.debug("winpty resize failed: %s", exc)
            return
        if self._master_fd is not None:
            try:
                import fcntl
                import termios

                winsize = struct.pack("HHHH", r, c, 0, 0)
                fcntl.ioctl(self._master_fd, termios.TIOCSWINSZ, winsize)
            except OSError as exc:
                logger.debug("posix pty resize failed: %s", exc)

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True

        if sys.platform == "win32":
            proc = self._win_proc
            self._win_proc = None
            if proc is not None:
                try:
                    if proc.isalive():
                        proc.terminate(force=True)
                except Exception:
                    pass
                try:
                    proc.close()
                except Exception:
                    pass
            return

        fd = self._master_fd
        self._master_fd = None
        if fd is not None:
            if self._loop is not None:
                try:
                    self._loop.remove_reader(fd)
                except Exception:
                    pass
            try:
                os.close(fd)
            except OSError:
                pass

        proc = self._posix_proc
        self._posix_proc = None
        if proc is not None and proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except Exception:
                try:
                    proc.terminate()
                except Exception:
                    pass
            try:
                proc.wait(timeout=1.5)
            except Exception:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except Exception:
                    try:
                        proc.kill()
                    except Exception:
                        pass


class TerminalManager:
    """Tracks active PTY sessions with bounded concurrency and clean shutdown."""

    def __init__(self, max_sessions: int = 4) -> None:
        self.max_sessions = max(1, int(max_sessions))
        self._sessions: set[PtySession] = set()

    @property
    def active_count(self) -> int:
        return len(self._sessions)

    def can_open(self) -> bool:
        return len(self._sessions) < self.max_sessions

    def register(self, session: PtySession) -> None:
        self._sessions.add(session)

    def unregister(self, session: PtySession) -> None:
        self._sessions.discard(session)

    async def close_all(self) -> None:
        for sess in list(self._sessions):
            try:
                sess.close()
            except Exception:
                pass
        self._sessions.clear()
