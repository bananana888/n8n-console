# -*- coding: utf-8 -*-
"""创建桌面快捷方式「n8n 控制台.lnk」——直接启动 powershell.exe

注意: 公司电脑卡巴斯基拦截 vbs→powershell 路径 (LOLBin 防护), 因此直接用 powershell.exe
      作为快捷方式目标。Windows console subsystem 进程会瞬时显示 conhost 窗口 (一闪),
      这是固有限制, 需 IT 在卡巴斯基给 launcher.vbs 加白名单后才能彻底无闪。
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

    powershell = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    args = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "D:\\APP\\n8n-console\\n8n-control.ps1"'

    pylnk3.for_file(
        target_file=powershell,
        lnk_name=lnk_path,
        arguments=args,
        description="n8n 工作流平台控制台 - 启动/停止/状态 (常驻托盘)",
        icon_file=r"D:\APP\n8n-console\assets\n8n.ico",
        icon_index=0,
        work_dir=r"D:\APP\n8n-console",
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
