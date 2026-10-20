; Script generated for ARA Assessment
; To use this script:
; 1. Download and install Inno Setup (https://jrsoftware.org/isdl.php)
; 2. Open this file in Inno Setup or run via scripts/build_windows.sh or scripts/build_windows.ps1

#ifndef MyAppVersion
#define MyAppVersion "1.0.0+1"
#endif

#define MyAppName "ARA Assessment"
#define MyAppPublisher "ARA Assessment"
#define MyAppURL "https://ara-assessment.com"
#define MyAppExeName "ara_desktop.exe"
#define MyOutputBaseFilename "ARA_Assessment_Setup"

[Setup]
; NOTE: The value of AppId uniquely identifies this application.
AppId={{4E3C6294-D962-4C79-B3A9-7A5E95587E23}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
UninstallDisplayIcon={app}\{#MyAppExeName}
SetupIconFile=windows\runner\resources\app_icon.ico
DefaultDirName={localappdata}\Programs\{#MyAppName}
DisableProgramGroupPage=yes
; Non-administrative install mode (install for current user only, no admin/UAC required)
PrivilegesRequired=lowest
OutputDir=build\windows
OutputBaseFilename={#MyOutputBaseFilename}
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "build\windows\x64\runner\Release\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Microsoft Visual C++ CRT DLLs for app-local deployment (zero-admin execution)
Source: "windows\redist\*"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall

[Code]
var
  ShouldDeleteData: Boolean;

function InitializeUninstall(): Boolean;
var
  Form: TSetupForm;
  OKButton, CancelButton: TNewButton;
  CheckBox: TNewCheckBox;
  StaticText: TNewStaticText;
begin
  // Initialize result to False (cancel uninstall)
  Result := False;

  // Modern Inno Setup (6.6.0+) requires width, height, and resizing parameters
  Form := CreateCustomForm(ScaleX(400), ScaleY(160), False, False);
  Form.Caption := 'Uninstall ' + ExpandConstant('{#MyAppName}');
  Form.Position := poScreenCenter;

  StaticText := TNewStaticText.Create(Form);
  StaticText.Parent := Form;
  StaticText.Top := ScaleY(20);
  StaticText.Left := ScaleX(20);
  StaticText.Width := Form.ClientWidth - ScaleX(40);
  StaticText.Caption := 'Are you sure you want to completely remove ' + ExpandConstant('{#MyAppName}') + ' and all of its components?';
  StaticText.WordWrap := True;

  CheckBox := TNewCheckBox.Create(Form);
  CheckBox.Parent := Form;
  CheckBox.Top := StaticText.Top + StaticText.Height + ScaleY(15);
  CheckBox.Left := ScaleX(20);
  CheckBox.Width := Form.ClientWidth - ScaleX(40);
  CheckBox.Caption := 'Delete cache, temporary exam data, and downloaded documents';
  CheckBox.Checked := False;

  OKButton := TNewButton.Create(Form);
  OKButton.Parent := Form;
  OKButton.Caption := 'Uninstall';
  OKButton.Default := True;
  OKButton.ModalResult := mrOk;
  OKButton.Left := Form.ClientWidth - ScaleX(190);
  OKButton.Top := Form.ClientHeight - ScaleY(40);

  CancelButton := TNewButton.Create(Form);
  CancelButton.Parent := Form;
  CancelButton.Caption := 'Cancel';
  CancelButton.ModalResult := mrCancel;
  CancelButton.Left := Form.ClientWidth - ScaleX(95);
  CancelButton.Top := Form.ClientHeight - ScaleY(40);

  if Form.ShowModal() = mrOk then
  begin
    ShouldDeleteData := CheckBox.Checked;
    Result := True;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataPath: string;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    if ShouldDeleteData then
    begin
      // 1. Delete Documents folder (downloaded exam documents, etc.)
      DataPath := ExpandConstant('{userdocs}\ara_documents');
      if DirExists(DataPath) then DelTree(DataPath, True, True, True);
      DataPath := ExpandConstant('{userdocs}\ARA Assessment');
      if DirExists(DataPath) then DelTree(DataPath, True, True, True);

      // 2. Delete Local AppData (WebView2 cache, cookies, local storage)
      DataPath := ExpandConstant('{localappdata}\ara_desktop');
      if DirExists(DataPath) then DelTree(DataPath, True, True, True);
      DataPath := ExpandConstant('{localappdata}\com.ara.assessment');
      if DirExists(DataPath) then DelTree(DataPath, True, True, True);
      DataPath := ExpandConstant('{localappdata}\ARA Assessment');
      if DirExists(DataPath) then DelTree(DataPath, True, True, True);

      // 3. Delete Roaming AppData
      DataPath := ExpandConstant('{userappdata}\ara_desktop');
      if DirExists(DataPath) then DelTree(DataPath, True, True, True);
      DataPath := ExpandConstant('{userappdata}\com.ara.assessment');
      if DirExists(DataPath) then DelTree(DataPath, True, True, True);
      DataPath := ExpandConstant('{userappdata}\ARA Assessment');
      if DirExists(DataPath) then DelTree(DataPath, True, True, True);

      Log('Completed optional data deletion.');
    end;
  end;
end;
