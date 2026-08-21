' n8n 控制台无窗口启动器
' 用 wscript.exe 执行此 vbs, vbs 自身无 conhost 窗口
' WScript.Shell.Run 的第 2 个参数 0 = 完全隐藏窗口
' 注意: 公司卡巴斯基可能拦截 vbs→powershell 路径 (LOLBin 防护), 该文件默认未使用, 保留备用
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""D:\APP\n8n-console\n8n-control.ps1""", 0, False
