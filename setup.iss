; Inno Setup Script for CloudStream Windows App
; Open this file in Inno Setup Compiler to compile the final installer

[Setup]
AppName=CloudStream
AppVersion=1.0.1
DefaultDirName={autopf}\CloudStream
DefaultGroupName=CloudStream
OutputDir=ReleaseInstaller
OutputBaseFilename=cloudstream_setup
Compression=lzma
SolidCompression=yes
SetupIconFile=cloudstream_app\windows\runner\resources\app_icon.ico
PrivilegesRequired=lowest

[Files]
Source: "cloudstream_app\build\windows\x64\runner\Release\cloudstream_app.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "cloudstream_app\build\windows\x64\runner\Release\node.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "cloudstream_app\build\windows\x64\runner\Release\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "cloudstream_app\build\windows\x64\runner\Release\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "cloudstream_app\build\windows\x64\runner\Release\backend\*"; DestDir: "{app}\backend"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\CloudStream"; Filename: "{app}\cloudstream_app.exe"
Name: "{autodesktop}\CloudStream"; Filename: "{app}\cloudstream_app.exe"

[Run]
Filename: "{app}\cloudstream_app.exe"; Description: "Launch CloudStream"; Flags: postinstall nowait skipifsilent
