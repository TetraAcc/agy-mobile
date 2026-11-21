Set WshShell = CreateObject("WScript.Shell")
' 后台静默启动 AGY Windows 桥接服务（带自动复活看门狗保护）
WshShell.Run "python -u watchdog_windows.py", 0, False
