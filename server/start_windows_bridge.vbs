Set WshShell = CreateObject("WScript.Shell")
WshShell.CurrentDirectory = "C:\Users\29280\.gemini\antigravity\scratch\agy_mobile_app\server"
WshShell.Run "pythonw.exe -u watchdog_windows.py", 0, False
