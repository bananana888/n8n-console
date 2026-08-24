' n8n 控制台无窗口启动器
' 用 wscript.exe 执行此 vbs, vbs 自身无 conhost 窗口
' WScript.Shell.Run 的第 2 个参数 0 = 完全隐藏窗口
' 注意: 公司卡巴斯基可能拦截 vbs→powershell 路径 (LOLBin 防护), 该文件默认未使用, 保留备用
' 按脚本自身所在目录动态定位 n8n-control.ps1（目录迁移/换机器无需改路径）
Dim fso, scriptDir
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptDir & "\n8n-control.ps1""", 0, False
