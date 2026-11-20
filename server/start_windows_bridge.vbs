Set WshShell = CreateObject("WScript.Shell")
' 后台静默启动 AGY Windows 桥接服务
WshShell.Run "python -u server_windows.py", 0, False
