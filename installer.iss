; ERP Attendance Sync installer.
; Installs sync_attendance_to_erp.exe, asks for the BioTime and ERP
; connection details on a custom wizard page, writes them to config.json in
; %ProgramData%\ERPSync (the exe reads/writes config, state, and its log
; there rather than next to itself in Program Files, which is admin-write-
; only), and registers a Scheduled Task that runs it every 5 minutes
; indefinitely, as SYSTEM.
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
var
  ConfigPage: TInputQueryWizardPage;

procedure InitializeWizard;
begin
  ConfigPage := CreateInputQueryPage(wpSelectDir,
    'ERP Sync Settings', 'Enter the BioTime and ERP connection details',
    'These values are written to config.json in %ProgramData%\ERPSync (not the install folder, so the exe can run without elevation). If one already exists there, its current values are shown below -- leave them as-is to keep them, or edit to update.');
  ConfigPage.Add('BioTime URL (e.g. http://192.168.1.171:8090):', False);
  ConfigPage.Add('BioTime username:', False);
  ConfigPage.Add('BioTime password:', True);
  ConfigPage.Add('ERP URL (e.g. https://yoursite.digerp.com/process.php):', False);
  ConfigPage.Add('Default temperature (e.g. 36.5):', False);

  ConfigPage.Values[4] := '36.5';
end;

function JsonUnescape(S: String): String;
begin
  { Reverse order from JsonEscape: undo the quote-escape before the
    backslash-escape, or a real backslash immediately before an escaped
    quote would be mishandled. }
  StringChangeEx(S, '\"', '"', True);
  StringChangeEx(S, '\\', '\', True);
  Result := S;
end;

function GetJsonLineValue(const Json, Key: String): String;
var
  Lines: TStringList;
  I, ColonPos: Integer;
  Line, SearchKey, RawValue: String;
begin
  Result := '';
  SearchKey := '"' + Key + '"';
  Lines := TStringList.Create;
  try
    Lines.Text := Json;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if Pos(SearchKey, Line) = 1 then
      begin
        ColonPos := Pos(':', Line);
        if ColonPos > 0 then
        begin
          RawValue := Trim(Copy(Line, ColonPos + 1, Length(Line) - ColonPos));
          if (RawValue <> '') and (RawValue[Length(RawValue)] = ',') then
            RawValue := Copy(RawValue, 1, Length(RawValue) - 1);
          if (Length(RawValue) >= 2) and (RawValue[1] = '"') and (RawValue[Length(RawValue)] = '"') then
            RawValue := Copy(RawValue, 2, Length(RawValue) - 2);
          Result := JsonUnescape(RawValue);
        end;
        break;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
var
  ConfigPath: String;
  ExistingJson: AnsiString;
begin
  { Pre-fill from an existing config.json (a prior install) so a reinstall
    shows current values to review/edit instead of forcing blind re-entry
    of data that, previously, would have been silently discarded anyway. }
  if CurPageID = ConfigPage.ID then
  begin
    ConfigPath := ExpandConstant('{commonappdata}\ERPSync\config.json');
    if FileExists(ConfigPath) and LoadStringFromFile(ConfigPath, ExistingJson) then
    begin
      ConfigPage.Values[0] := GetJsonLineValue(ExistingJson, 'biotime_url');
      ConfigPage.Values[1] := GetJsonLineValue(ExistingJson, 'biotime_user');
      ConfigPage.Values[2] := GetJsonLineValue(ExistingJson, 'biotime_password');
      ConfigPage.Values[3] := GetJsonLineValue(ExistingJson, 'erp_url');
      ConfigPage.Values[4] := GetJsonLineValue(ExistingJson, 'temperature');
    end;
  end;
end;

function HasUrlScheme(S: String): Boolean;
begin
  Result := (Pos('http://', S) = 1) or (Pos('https://', S) = 1);
end;

function IsValidNumber(S: String): Boolean;
var
  I: Integer;
  DotSeen: Boolean;
begin
  Result := S <> '';
  DotSeen := False;
  for I := 1 to Length(S) do
  begin
    if S[I] = '.' then
    begin
      if DotSeen then
      begin
        Result := False;
        break;
      end;
      DotSeen := True;
    end
    else if (S[I] < '0') or (S[I] > '9') then
    begin
      Result := False;
      break;
    end;
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = ConfigPage.ID then
  begin
    if not HasUrlScheme(Trim(ConfigPage.Values[0])) then
    begin
      MsgBox('BioTime URL must start with http:// or https://', mbError, MB_OK);
      Result := False;
    end
    else if Trim(ConfigPage.Values[1]) = '' then
    begin
      MsgBox('BioTime username is required.', mbError, MB_OK);
      Result := False;
    end
    else if Trim(ConfigPage.Values[2]) = '' then
    begin
      MsgBox('BioTime password is required.', mbError, MB_OK);
      Result := False;
    end
    else if not HasUrlScheme(Trim(ConfigPage.Values[3])) then
    begin
      MsgBox('ERP URL must start with http:// or https://', mbError, MB_OK);
      Result := False;
    end
    else if not IsValidNumber(Trim(ConfigPage.Values[4])) then
    begin
      MsgBox('Default temperature must be a number.', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

function JsonEscape(S: String): String;
begin
  StringChangeEx(S, '\', '\\', True);
  StringChangeEx(S, '"', '\"', True);
  Result := S;
end;

function BuildConfigJson(): String;
var
  BiotimeUrl, BiotimeUser, BiotimePassword, ErpUrl, Temperature: String;
begin
  BiotimeUrl := JsonEscape(Trim(ConfigPage.Values[0]));
  BiotimeUser := JsonEscape(Trim(ConfigPage.Values[1]));
  BiotimePassword := JsonEscape(Trim(ConfigPage.Values[2]));
  ErpUrl := JsonEscape(Trim(ConfigPage.Values[3]));
  Temperature := Trim(ConfigPage.Values[4]);

  Result :=
    '{' + #13#10 +
    '  "biotime_url": "' + BiotimeUrl + '",' + #13#10 +
    '  "biotime_user": "' + BiotimeUser + '",' + #13#10 +
    '  "biotime_password": "' + BiotimePassword + '",' + #13#10 +
    '  "erp_url": "' + ErpUrl + '",' + #13#10 +
    '  "temperature": ' + Temperature + ',' + #13#10 +
    '  "lookback_minutes_on_first_run": 60,' + #13#10 +
    '  "page_size": 200' + #13#10 +
    '}' + #13#10;
end;

function RegisterTaskCommand(): String;
begin
  { schtasks' MINUTE schedule type repeats indefinitely by design -- no
    "repetition duration" concept to get wrong. PowerShell's
    Register-ScheduledTask + RepetitionInterval/RepetitionDuration route was
    tried first and rejected two different explicit Duration values
    ([TimeSpan]::MaxValue, then a 100-year span) as "incorrectly formatted or
    out of range" on the actual target machine, so this avoids that whole
    mechanism. schtasks also gives a real, reliable exit code and error text
    on stdout/stderr, unlike a PowerShell non-terminating error. }
  Result :=
    'schtasks /create /tn "{#MyTaskName}" /tr "' + ExpandConstant('{app}\{#MyAppExeName}') + '" ' +
    '/sc minute /mo 5 /ru SYSTEM /rl highest /f';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ConfigPath, TaskLogPath, Cmd: String;
  ResultCode: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    { config.json lives in %ProgramData%\ERPSync, not {app} (Program Files),
      so the exe can read/write its config, state, and log without needing
      elevation when run manually -- Program Files is admin-write-only.
      The wizard page was pre-filled from any existing config.json (see
      CurPageChanged), so what's here now is either the prior values
      unchanged or deliberately edited -- always write it, rather than
      silently discarding whatever the user just entered on a reinstall. }
    ForceDirectories(ExpandConstant('{commonappdata}\ERPSync'));
    ConfigPath := ExpandConstant('{commonappdata}\ERPSync\config.json');
    SaveStringToFile(ConfigPath, BuildConfigJson(), False);

    { Redirect stdout/stderr to a log file for diagnosis -- Exec() alone
      can't capture schtasks' own output. }
    TaskLogPath := ExpandConstant('{app}\task_register.log');
    Cmd := '/c ' + RegisterTaskCommand() + ' > "' + TaskLogPath + '" 2>&1';
    if not Exec('cmd.exe', Cmd, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
      MsgBox('Could not register the scheduled task automatically. See ' + TaskLogPath +
        ' for details, or create it manually with schtasks or Task Scheduler.', mbError, MB_OK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    Exec('cmd.exe', '/c schtasks /delete /tn "{#MyTaskName}" /f',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;
