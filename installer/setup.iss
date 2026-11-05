; MinGit BusyBox Bundle: independent, offline, inseparable x64 payload.
; Compile with Inno Setup 7 using the four required /D values below.
#ifndef PayloadDir
  #error PayloadDir must be the absolute path to the completed payload
#endif
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef FileVersion
  #error FileVersion is required (four numeric version components)
#endif
#ifndef ReleaseTag
  #error ReleaseTag is required
#endif
#ifndef OutputBaseFilename
  #define OutputBaseFilename "MinGit-BusyBox-Bundle-" + ReleaseTag + "-x64"
#endif

[Setup]
AppId=MinGitBusyBoxBundle
AppName=MinGit BusyBox Bundle
AppVersion={#AppVersion}
AppPublisher=MinGit BusyBox Bundle contributors
AppComments=Unofficial custom Git build with BusyBox, Git LFS, offline HTML manuals and native Git translations.
VersionInfoVersion={#FileVersion}
VersionInfoDescription=MinGit BusyBox Bundle offline installer
VersionInfoProductName=MinGit BusyBox Bundle
VersionInfoProductVersion={#FileVersion}
VersionInfoProductTextVersion={#AppVersion}
DefaultDirName={autopf}\MinGit BusyBox Bundle
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
UsePreviousPrivileges=yes
UsePreviousAppDir=yes
UsePreviousTasks=yes
ChangesEnvironment=yes
SetupArchitecture=x64
ArchitecturesAllowed=x64compatible and not arm64
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.18362
Compression=lzma2/ultra64
SolidCompression=yes
OutputDir=..\dist
OutputBaseFilename={#OutputBaseFilename}
DisableProgramGroupPage=yes
DisableDirPage=no
DisableWelcomePage=no
AllowNoIcons=yes
UninstallDisplayName=MinGit BusyBox Bundle
UninstallDisplayIcon={app}\cmd\git.exe
UninstallLogMode=append
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Tasks]
Name: "addtopath"; Description: "Add this installation's cmd directory to PATH"; GroupDescription: "Command-line access:"

[Files]
; Keep this first for fast, embedded-only extraction during preflight validation.
Source: "{#PayloadDir}\payload-files.txt"; Flags: dontcopy noencryption
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Excludes: "\etc\gitconfig"; Flags: ignoreversion recursesubdirs createallsubdirs
; Mutable system configuration is neither overwritten on upgrade nor uninstalled.
Source: "{#PayloadDir}\etc\gitconfig"; DestDir: "{app}\etc"; Flags: onlyifdoesntexist uninsneveruninstall

[Messages]
FinishedLabel=MinGit BusyBox Bundle has been installed with Git, BusyBox, Git LFS, offline HTML manuals and Git translations.%n%nOpen a new terminal and run "where git" to check which Git is selected. Another Git already on your system PATH may still take precedence. Existing Git installations were not modified.

[Code]
const
  ProductKey = 'Software\MinGitBusyBoxBundle';
  ProductUninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\MinGitBusyBoxBundle_is1';
  ManifestName = 'payload-files.txt';
  InvalidAttributes = $FFFFFFFF;
  DirectoryAttribute = $10;
  ReparsePointAttribute = $400;

var
  NewFiles, OldFiles, StaleFiles: TStringList;
  Prepared: Boolean;
  UninstallScopeRoot: HKEY;

function BundleRegOpenKeyEx(Root: HKEY; SubKey: String; Options, Access: Cardinal; var Key: HKEY): LongInt;
  external 'RegOpenKeyExW@advapi32.dll stdcall';
function BundleRegQueryValueEx(Key: HKEY; ValueName: String; Reserved: NativeUInt;
  var ValueType: Cardinal; Data: NativeUInt; var DataSize: Cardinal): LongInt;
  external 'RegQueryValueExW@advapi32.dll stdcall';
function BundleRegCloseKey(Key: HKEY): LongInt;
  external 'RegCloseKey@advapi32.dll stdcall';
function BundleGetFileAttributes(FileName: String): Cardinal;
  external 'GetFileAttributesW@kernel32.dll stdcall';

#include "path.iss"

procedure ResolveUninstallScope;
var
  UserDir, MachineDir: String;
  UserMatch, MachineMatch: Boolean;
begin
  { Administrative privilege is not an installation scope: a user uninstaller
    can be launched elevated. Select only the persisted record for this app. }
  UserMatch := False;
  MachineMatch := False;
  if RegQueryStringValue(HKCU64, ProductKey, 'InstallDir', UserDir) then
    UserMatch := SameText(RemoveBackslashUnlessRoot(ExpandFileName(UserDir)),
      RemoveBackslashUnlessRoot(ExpandFileName(ExpandConstant('{app}'))));
  if RegQueryStringValue(HKLM64, ProductKey, 'InstallDir', MachineDir) then
    MachineMatch := SameText(RemoveBackslashUnlessRoot(ExpandFileName(MachineDir)),
      RemoveBackslashUnlessRoot(ExpandFileName(ExpandConstant('{app}'))));
  if UserMatch = MachineMatch then
    RaiseException('Cannot identify a unique persisted scope for this uninstall directory.');
  if MachineMatch then UninstallScopeRoot := HKLM64 else UninstallScopeRoot := HKCU64;
end;

function CanonicalDirectory(const Value: String): String;
begin
  Result := RemoveBackslashUnlessRoot(ExpandFileName(Value));
end;

procedure CheckNoReparseAncestors(const FileName: String);
var
  Current, Parent: String;
  Attributes, Error: Cardinal;
begin
  Current := RemoveBackslashUnlessRoot(FileName);
  while Current <> '' do begin
    Attributes := BundleGetFileAttributes(Current);
    if Attributes = InvalidAttributes then begin
      Error := DLLGetLastError;
      if (Error <> 2) and (Error <> 3) then
        RaiseException('Cannot inspect installation path ' + Current + ': ' + SysErrorMessage(Error));
    end else if (Attributes and ReparsePointAttribute) <> 0 then
      RaiseException('Refusing an installation path through a reparse point: ' + Current);
    Parent := ExtractFileDir(Current);
    if SameText(Parent, Current) then Break;
    Current := Parent;
  end;
end;

function CheckedRelativePath(Value: String): String;
var
  I, First, Dot: Integer;
  Part, Base: String;
begin
  StringChangeEx(Value, '/', '\', True);
  if (Value = '') or PathIsRooted(Value) or (Pos(':', Value) <> 0) then
    RaiseException('Invalid absolute or empty payload manifest entry: ' + Value);
  First := 1;
  for I := 1 to Length(Value) + 1 do begin
    if I <= Length(Value) then begin
      if (Ord(Value[I]) < 32) or (Pos(Value[I], '*?"<>|') <> 0) then
        RaiseException('Invalid character in payload manifest entry: ' + Value);
      if Value[I] <> '\' then Continue;
    end;
    Part := Copy(Value, First, I - First);
    if (Part = '') or (Part = '.') or (Part = '..') then
      RaiseException('Invalid path segment in payload manifest entry: ' + Value);
    if (Part[Length(Part)] = '.') or (Part[Length(Part)] = ' ') then
      RaiseException('Ambiguous Windows path in payload manifest entry: ' + Value);
    Base := UpperCase(Part);
    Dot := Pos('.', Base);
    if Dot <> 0 then Base := Copy(Base, 1, Dot - 1);
    if (Base = 'CON') or (Base = 'PRN') or (Base = 'AUX') or (Base = 'NUL') or
       (Base = 'CONIN$') or (Base = 'CONOUT$') then
      RaiseException('Device name in payload manifest entry: ' + Value);
    if Length(Base) = 4 then
      if ((Copy(Base, 1, 3) = 'COM') or (Copy(Base, 1, 3) = 'LPT')) and
         (Pos(Base[4], '123456789' + #$00B9 + #$00B2 + #$00B3) <> 0) then
        RaiseException('Device name in payload manifest entry: ' + Value);
    First := I + 1;
  end;
  if SameText(Value, 'etc\gitconfig') then
    RaiseException('Mutable etc/gitconfig must not be owned by the payload manifest.');
  Result := Value;
end;

function CheckedOwnedPath(const Relative: String): String;
var
  Root, Canonical: String;
  Attributes: Cardinal;
begin
  Root := AddBackslash(CanonicalDirectory(ExpandConstant('{app}')));
  Result := Root + CheckedRelativePath(Relative);
  Canonical := ExpandFileName(Result);
  if not SameText(Copy(Canonical, 1, Length(Root)), Root) then
    RaiseException('Payload manifest entry escapes the installation directory: ' + Relative);
  CheckNoReparseAncestors(Result);
  Attributes := BundleGetFileAttributes(Result);
  if Attributes <> InvalidAttributes then
    if (Attributes and DirectoryAttribute) <> 0 then
      RaiseException('A payload-owned file has been replaced by a directory: ' + Result);
end;

procedure LoadManifest(const FileName: String; Files: TStringList);
var
  Lines: TArrayOfString;
  I: Integer;
  Relative, FullName: String;
begin
  CheckNoReparseAncestors(FileName);
  if not LoadStringsFromFile(FileName, Lines) then
    RaiseException('Cannot read required payload ownership manifest: ' + FileName);
  Files.Clear;
  for I := 0 to GetArrayLength(Lines) - 1 do begin
    Relative := CheckedRelativePath(Lines[I]);
    FullName := CheckedOwnedPath(Relative);
    if Files.IndexOf(Relative) >= 0 then
      RaiseException('Duplicate payload manifest entry: ' + Relative);
    Files.Add(Relative);
  end;
  if (Files.IndexOf(ManifestName) < 0) or (Files.IndexOf('build-manifest.json') < 0) then
    RaiseException('The payload manifest must own itself and build-manifest.json.');
end;

procedure CheckInstallRegistration;
var
  PreviousDir, UninstallDir, StoredScope: String;
  Owned, Created: Cardinal;
  Token, AppDir: String;
  HasMetadata, HasUninstaller: Boolean;
begin
  if RegKeyExists(OtherScopeRoot, ProductKey) or
     RegKeyExists(OtherScopeRoot, ProductUninstallKey) then
    RaiseException('MinGit BusyBox Bundle is registered in the other installation scope. ' +
      'Uninstall it before changing between CurrentUser and AllUsers. No existing installation was changed.');
  AppDir := CanonicalDirectory(ExpandConstant('{app}'));
  if (Pos(';', AppDir) <> 0) or (Pos('"', AppDir) <> 0) then
    RaiseException('The installation directory must not contain a semicolon or quotation mark.');
  if (Length(ExtractFileDrive(AppDir)) <> 2) or
     SameText(AppDir, AddBackslash(ExtractFileDrive(AppDir))) then
    RaiseException('Choose a dedicated directory on a local drive, not a drive root.');
  CheckNoReparseAncestors(AppDir);
  HasMetadata := RegKeyExists(ScopeRoot, ProductKey);
  HasUninstaller := RegKeyExists(ScopeRoot, ProductUninstallKey);
  if HasMetadata <> HasUninstaller then
    RaiseException('Incomplete MinGit BusyBox Bundle registration. Restore or uninstall the existing installation before installing again.');
  if HasMetadata then begin
    if not RegQueryStringValue(ScopeRoot, ProductKey, 'InstallDir', PreviousDir) then
      RaiseException('The existing product registration has no InstallDir.');
    if not SameText(CanonicalDirectory(PreviousDir), AppDir) then
      RaiseException('An upgrade must use the registered installation directory: ' + PreviousDir +
        '. Uninstall first to change directories.');
    if not RegQueryStringValue(ScopeRoot, ProductUninstallKey, 'InstallLocation', UninstallDir) then
      RaiseException('The existing uninstaller registration has no InstallLocation.');
    if not SameText(CanonicalDirectory(UninstallDir), AppDir) then
      RaiseException('Product and uninstaller directories disagree; installation was stopped.');
    if not RegQueryStringValue(ScopeRoot, ProductKey, 'InstallScope', StoredScope) then
      RaiseException('The existing product registration has no InstallScope.');
    if StoredScope <> ScopeName then RaiseException('The existing product scope does not match.');
    ReadPathOwnership(Owned, Created, Token);
  end else if FileOrDirExists(AddBackslash(AppDir) + ManifestName) then
    RaiseException('The destination contains an unregistered bundle. Choose an unused directory; existing files will not be adopted.');
end;

function NewManifestList: TStringList;
begin
  Result := TStringList.Create;
  Result.CaseSensitive := False;
  Result.Sorted := True;
  Result.Duplicates := dupError;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  I: Integer;
  Value, FullName: String;
  ValueType: Cardinal;
  Exists: Boolean;
begin
  Result := '';
  Prepared := False;
  try
    CheckInstallRegistration;
    { Fail before touching files if the selected scope has an unsupported PATH type. }
    ReadPersistedPath(Value, ValueType, Exists);
    ExtractTemporaryFile(ManifestName);
    if NewFiles = nil then NewFiles := NewManifestList;
    if OldFiles = nil then OldFiles := NewManifestList;
    if StaleFiles = nil then StaleFiles := NewManifestList;
    OldFiles.Clear;
    StaleFiles.Clear;
    LoadManifest(ExpandConstant('{tmp}\') + ManifestName, NewFiles);
    { The separately installed mutable config must also not traverse a junction. }
    CheckNoReparseAncestors(ExpandConstant('{app}\etc\gitconfig'));
    if RegKeyExists(ScopeRoot, ProductKey) then
      LoadManifest(ExpandConstant('{app}\') + ManifestName, OldFiles);
    for I := 0 to OldFiles.Count - 1 do
      if NewFiles.IndexOf(OldFiles[I]) < 0 then StaleFiles.Add(OldFiles[I]);
    { Validate the entire difference before deleting even one obsolete file. }
    for I := 0 to StaleFiles.Count - 1 do
      FullName := CheckedOwnedPath(StaleFiles[I]);
    Prepared := True;
  except
    Result := GetExceptionMessage;
  end;
end;

procedure DeleteStaleFiles;
var
  I: Integer;
  FileName: String;
begin
  if not Prepared then RaiseException('Payload ownership preflight did not complete.');
  for I := 0 to StaleFiles.Count - 1 do begin
    { Recheck immediately before deletion; never recursively clear a directory. }
    FileName := CheckedOwnedPath(StaleFiles[I]);
    if FileExists(FileName) then begin
      Log('Removing obsolete product-owned file: ' + FileName);
      if not DeleteFile(FileName) then
        RaiseException('Cannot remove obsolete product file: ' + FileName + '. Close processes using it and retry.');
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then DeleteStaleFiles;
  if CurStep = ssPostInstall then ApplyPathTask;
end;

procedure DeinitializeSetup;
begin
  if NewFiles <> nil then NewFiles.Free;
  if OldFiles <> nil then OldFiles.Free;
  if StaleFiles <> nil then StaleFiles.Free;
end;

procedure CheckUninstallTree(const Directory: String);
var
  FindRec: TFindRec;
  Child: String;
  Error: Cardinal;
begin
  CheckNoReparseAncestors(Directory);
  if not DirExists(Directory) then Exit;
  if not FindFirst(AddBackslash(Directory) + '*', FindRec) then begin
    Error := DLLGetLastError;
    if (Error <> 2) and (Error <> 18) then
      RaiseException('Cannot inspect the uninstall directory: ' + Directory);
    Exit;
  end;
  try
    repeat
      if (FindRec.Name <> '.') and (FindRec.Name <> '..') then begin
        Child := AddBackslash(Directory) + FindRec.Name;
        if (FindRec.Attributes and ReparsePointAttribute) <> 0 then
          RaiseException('Remove or relocate this reparse point before uninstalling: ' + Child);
        if (FindRec.Attributes and DirectoryAttribute) <> 0 then CheckUninstallTree(Child);
      end;
    until not FindNext(FindRec);
  finally
    FindClose(FindRec);
  end;
end;

function InitializeUninstall: Boolean;
var
  Owned, Created, ValueType: Cardinal;
  Token, Value: String;
  Exists: Boolean;
begin
  Result := False;
  try
    ResolveUninstallScope;
    if not RegKeyExists(ScopeRoot, ProductKey) then
      RaiseException('Missing product ownership registration; uninstall was stopped.');
    ReadPathOwnership(Owned, Created, Token);
    if Owned = 1 then ReadPersistedPath(Value, ValueType, Exists);
    { Inno's accumulated uninstall log can name files from earlier versions.
      Reject all reparse points in the tree, including those in obsolete directories. }
    CheckUninstallTree(ExpandConstant('{app}'));
    Result := True;
  except
    Log(GetExceptionMessage);
    SuppressibleMsgBox(GetExceptionMessage, mbError, MB_OK, IDOK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then begin
    CheckUninstallTree(ExpandConstant('{app}'));
    RemoveProductPath;
  end;
  if CurUninstallStep = usPostUninstall then begin
    { Only this product's metadata is removed; Inno owns its uninstall key/log. }
    if RegKeyExists(ScopeRoot, ProductKey) then
      if not RegDeleteKeyIncludingSubkeys(ScopeRoot, ProductKey) then
        RaiseException('Cannot remove MinGit BusyBox Bundle ownership registration.');
  end;
end;
