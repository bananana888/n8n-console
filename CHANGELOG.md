# 更新日志

## [4.1.0] - 2026-08-23

- **家用机适配**：`Console.Home` 留空自动用脚本所在目录（换目录/换机器拷贝即用）；n8n 改用 npm 全局安装入口（`D:\npm-global`）；删除 `N8N_USER_FOLDER` 双嵌套（家用机数据走默认 `~\.n8n`）
- **修复家用机 n8n 启动卡死**：系统代理（`HTTP_PROXY` + `NODE_USE_ENV_PROXY=1`）导致 node 22.22 的 undici 外联挂起，进程存活但不监听端口；配置注入 `NODE_USE_ENV_PROXY=0` 直连外网（实测 12s 就绪）
- **服务入口自动探测**：便携 node / 配置绝对路径 / 本地安装 / npm 全局 / PATH shim 五级定位真实入口；npm 不在 PATH 时回退便携 node 的 `npm.cmd`；npm-install 完成判定改为「入口可探测到」
- **源码兼容性**：exe 定位逐级回退（便携 node → 配置绝对路径 → PATH）；入口失效自动探测替换；`create_shortcut.py` 硬编码路径改为脚本目录动态推导
- **打包完善**：WiX 新增 `license.rtf` 许可协议，Bundle/installer 同步调整
- **项目减重**：删除嵌套仓库副本（136MB）、Inno 遗留 `installer.iss`、WiX 中间产物与 worktree 残留
- 源码文件统一 CRLF 行尾

## [4.0.0] - 2026-08-21

- **多实例壳子**：`-ConfigFile` 指定配置，一套壳子复用管任意命令行服务
- **环境自检 + 自动安装**：缺 node/n8n 自动下载安装（便携 node + npm install + 数据初始化），窗口内进度条实时展示
- **日志轮转**：超过 2MB 自动滚动，保留 3 份
- **单实例锁**：防重复打开控制台
- `-Version` 查看版本、配置缺失校验、错误上下文
- GUI：异步启动（不冻结）、绿灯慢闪、内联 toast、关窗直接退出

## [3.0.0] - 2026-08-21

- 单文件 660 行重构拆分为 `n8n.ps1` + `lib/` + `n8n.config.psd1`（配置外置）
- 修复：node 版本导致启动即退、EPERM 缓存锁、PID 残留自愈、PS5.1 事件闭包陷阱、永久黄灯
- 启动异步化、绿灯慢闪、无托盘直退、进程死亡快速检测、exe 启动预检
