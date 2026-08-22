# -*- coding: utf-8 -*-
"""创建桌面快捷方式「n8n 控制台.lnk」——直接启动 n8n-console.exe

n8n-console.exe 是 C# 编译的 winexe 启动器（无 console 子系统，双击无 conhost
黑框一闪），内部经 PowerShell 拉起 n8n.ps1 主入口。桌面/安装包的快捷方式均指向它。
"""
import os
import sys
import winreg

import pylnk3


def get_desktop_path():
    key = winreg.OpenKey(
        winreg.HKEY_CURRENT_USER,
        r"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders",
    )
    value, _ = winreg.QueryValueEx(key, "Desktop")
    winreg.CloseKey(key)
    return os.path.expandvars(value)


def main():
    desktop = get_desktop_path()
    lnk_path = os.path.join(desktop, "n8n 控制台.lnk")

    # 控制台根目录 = 脚本所在目录（换机器/换目录拷贝即用，无需改路径）
    root = os.path.dirname(os.path.abspath(__file__))
    launcher = os.path.join(root, "n8n-console.exe")
    icon = os.path.join(root, "assets", "n8n.ico")

    pylnk3.for_file(
        target_file=launcher,
        lnk_name=lnk_path,
        description="n8n 工作流平台控制台 - 启动/停止/状态",
        icon_file=icon,
        icon_index=0,
        work_dir=root,
    )

    print(f"已重建快捷方式: {lnk_path}")
    print(f"存在: {os.path.exists(lnk_path)} ({os.path.getsize(lnk_path)} bytes)")
    with open(lnk_path, "rb") as f:
        data = f.read()
    flags = int.from_bytes(data[20:24], "little")
    print(f"LinkFlags: 0x{flags:08X}")
    print(f"IsUnicode(0x80): {'YES' if flags & 0x80 else 'NO'}")
    print(f"HasIconLocation(0x40): {'YES' if flags & 0x40 else 'NO'}")


if __name__ == "__main__":
    sys.exit(main())
