import os
import sys
import time
import subprocess
import urllib.request

SERVER_DIR = os.path.dirname(os.path.abspath(__file__))
SERVER_SCRIPT = os.path.join(SERVER_DIR, "server_windows.py")
HEALTH_URL = "http://127.0.0.1:8765/api/health"
LOG_FILE = os.path.join(SERVER_DIR, "watchdog.log")

def log(msg: str):
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    formatted = f"[{timestamp}] [Watchdog] {msg}"
    print(formatted)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(formatted + "\n")
    except Exception:
        pass

def is_server_healthy() -> bool:
    try:
        req = urllib.request.Request(HEALTH_URL, headers={"User-Agent": "Watchdog"})
        with urllib.request.urlopen(req, timeout=3) as resp:
            return resp.status == 200
    except Exception:
        return False

def clean_port_8765():
    try:
        if os.name == 'nt':
            cmd = "Get-NetTCPConnection -LocalPort 8765 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess | Stop-Process -Force -ErrorAction SilentlyContinue"
            subprocess.run(["powershell", "-NoProfile", "-Command", cmd], capture_output=True, timeout=5)
    except Exception as e:
        log(f"清理端口占用失败: {e}")

def main():
    log("==================================================")
    log("  AGY Windows 本地看门狗守护服务已启动 (Auto-Recovery)")
    log(f"  👉 监控目标: {SERVER_SCRIPT}")
    log("==================================================")

    clean_port_8765()
    restart_count = 0

    while True:
        log(f"正在拉起主服务进程 (第 {restart_count + 1} 次启动)...")
        clean_port_8765()
        
        proc = subprocess.Popen(
            [sys.executable, "-u", SERVER_SCRIPT],
            cwd=SERVER_DIR,
            stdout=sys.stdout,
            stderr=sys.stderr
        )

        # 启动后等待 2 秒并确认是否成功存活
        time.sleep(2)
        if proc.poll() is not None:
            log(f"[-] 警告：主服务未能成功启动，退出代码: {proc.returncode}，将在 3 秒后重试...")
            time.sleep(3)
            restart_count += 1
            continue

        log(f"[+] 主服务进程已稳定运行 (PID: {proc.pid})")
        restart_count = 0

        # 主循环：监听进程存活与健康状态
        fail_pings = 0
        while True:
            exit_code = proc.poll()
            if exit_code is not None:
                log(f"[!] 警告：主服务异常退出！退出代码: {exit_code}。正在触发自愈自启...")
                break

            # 每 15 秒做一次健康探测
            time.sleep(15)
            if not is_server_healthy():
                fail_pings += 1
                log(f"[-] 健康检查未通过 ({fail_pings}/3)...")
                if fail_pings >= 3:
                    log("[!] 连续 3 次健康检查失败，服务可能挂起，正在强制重启...")
                    try:
                        proc.terminate()
                        proc.wait(timeout=3)
                    except Exception:
                        proc.kill()
                    break
            else:
                fail_pings = 0

        time.sleep(1.5)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("看门狗收到终止信号，正常退出。")
