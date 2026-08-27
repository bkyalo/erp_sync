; ERP Attendance Sync installer.
; Installs sync_attendance_to_erp.exe and registers a Scheduled Task that
; runs it every 5 minutes indefinitely, as SYSTEM.
;
; Built by CI (see .github/workflows/build-installer.yml) with:
;   iscc installer.iss
; Expects dist\sync_attendance_to_erp.exe to already exist (built by PyInstaller).

#define MyAppName "ERP Attendance Sync"
#define MyAppVersion "1.0"
#define MyAppExeName "sync_attendance_to_erp.exe"
#define MyTaskName "ERP Attendance Sync"

[Setup]
AppId={{C2C1D9C1-6D6B-4C6E-9E9B-ERPSYNC00001}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={autopf}\ERPSync
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=Output
OutputBaseFilename=ERPSyncInstaller
Compression=lzma
SolidCompression=yes
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}

[Files]
Source: "dist\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "config.example.json"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"

[Code]
function RegisterTaskCommand(): String;
begin
  Result :=
    '$action = New-ScheduledTaskAction -Execute ''' + ExpandConstant('{app}\{#MyAppExeName}') + ''';' +
    '$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) ' +
    '-RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::MaxValue);' +
    '$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries;' +
    'Register-ScheduledTask -TaskName ''{#MyTaskName}'' -Action $action -Trigger $trigger ' +
    '-Settings $settings -User ''SYSTEM'' -RunLevel Highest -Force';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ConfigPath, ExamplePath, Cmd: String;
  ResultCode: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    { Seed config.json from the template on first install; never overwrite an existing one. }
    ConfigPath := ExpandConstant('{app}\config.json');
    ExamplePath := ExpandConstant('{app}\config.example.json');
    if not FileExists(ConfigPath) then
      FileCopy(ExamplePath, ConfigPath, False);

    Cmd := '-NoProfile -ExecutionPolicy Bypass -Command "' + RegisterTaskCommand() + '"';
    if not Exec('powershell.exe', Cmd, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
      MsgBox('Could not register the scheduled task automatically. You can create it manually with schtasks or Task Scheduler.', mbError, MB_OK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    Exec('powershell.exe',
      '-NoProfile -ExecutionPolicy Bypass -Command "Unregister-ScheduledTask -TaskName ''{#MyTaskName}'' -Confirm:$false -ErrorAction SilentlyContinue"',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;
