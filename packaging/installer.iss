; ============================================================
;  n8n 控制台 安装脚本（Inno Setup）
;  构建流程: packaging/build.ps1 先收集文件到 tools\stage，再调本脚本编译
;  用法: ISCC.exe installer.iss  （输出 ../release/setup.exe）
;  安装位置: 用户目录 %LOCALAPPDATA%\n8n-console（免管理员）
; ============================================================
#define MyAppName "n8n 控制台"
#define MyAppVersion "4.0.0"
#define MyAppPublisher "bananana888"
#define MyAppExeName "n8n-control.ps1"
#define StageDir "tools\stage"

[Setup]
AppId={{D3A7F8B2-9C4E-4E1A-8F2B-6C5D9E1A7B3C}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\n8n-console
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\release
OutputBaseFilename=setup
SetupIconFile=..\assets\n8n.ico
UninstallDisplayIcon={app}\assets\n8n.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
Source: "{#StageDir}\n8n.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\n8n-control.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\n8n.config.psd1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\example.config.psd1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\lib\*"; DestDir: "{app}\lib"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageDir}\assets\*"; DestDir: "{app}\assets"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageDir}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\CHANGELOG.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userdesktop}\n8n 控制台"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\n8n-control.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\n8n.ico"

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\n8n-control.ps1"""; Description: "启动 n8n 控制台"; Flags: nowait skipifsilent
