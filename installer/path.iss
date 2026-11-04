// Included by setup.iss inside [Code]. Only the selected registry scope is edited.
// Never reconstruct a persisted PATH from the installer's process environment.
function ScopeRoot: HKEY;
begin
  if IsUninstaller then Result := UninstallScopeRoot
  else if IsAdminInstallMode then Result := HKLM64 else Result := HKCU64;
end;

function OtherScopeRoot: HKEY;
begin
  if IsAdminInstallMode then Result := HKCU64 else Result := HKLM64;
end;

function ScopeName: String;
begin
  if ScopeRoot = HKLM64 then Result := 'AllUsers' else Result := 'CurrentUser';
end;

function EnvironmentKey: String;
begin
  if ScopeRoot = HKLM64 then
    Result := 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
  else
    Result := 'Environment';
end;

function NormalizePathToken(Value: String): String;
begin
  Value := Trim(Value);
  if Length(Value) >= 2 then
    if (Value[1] = '"') and (Value[Length(Value)] = '"') then
      Value := Copy(Value, 2, Length(Value) - 2);
  while Length(Value) > 0 do begin
    if Value[Length(Value)] <> '\' then Break;
    Delete(Value, Length(Value), 1);
  end;
  Result := LowerCase(Value);
end;

function FindPathToken(const Value, Token: String; var Start, Count: Integer): Boolean;
var
  I, First: Integer;
  Expected: String;
begin
  Result := False;
  Expected := NormalizePathToken(Token);
  First := 1;
  for I := 1 to Length(Value) + 1 do begin
    if I <= Length(Value) then begin
      if Value[I] <> ';' then Continue;
    end;
    if NormalizePathToken(Copy(Value, First, I - First)) = Expected then begin
      Start := First;
      Count := I - First;
      Result := True;
      Exit;
    end;
    First := I + 1;
  end;
end;

function RemoveOwnedToken(var Value: String; const Token: String): Boolean;
var
  First, Count: Integer;
begin
  Result := FindPathToken(Value, Token, First, Count);
  if not Result then Exit;
  { Remove one complete token, not every path sharing the installation prefix.
    Prefer the separator preceding it, preserving an original trailing empty token. }
  if First > 1 then begin
    First := First - 1;
    Count := Count + 1;
  end else if Count < Length(Value) then
    Count := Count + 1;
  Delete(Value, First, Count);
end;

procedure ReadPersistedPath(var Value: String; var ValueType: Cardinal; var Exists: Boolean);
var
  Key, Root: HKEY;
  Status: LongInt;
  Bytes: Cardinal;
begin
  Value := '';
  ValueType := 2; { A newly created value is REG_EXPAND_SZ. }
  Exists := False;
  if ScopeRoot = HKLM64 then Root := HKEY_LOCAL_MACHINE else Root := HKEY_CURRENT_USER;
  Status := BundleRegOpenKeyEx(Root, EnvironmentKey, 0, $0101, Key);
  if Status = 2 then Exit;
  if Status <> 0 then RaiseException('Cannot read the selected scope PATH: ' + SysErrorMessage(Status));
  try
    Bytes := 0;
    Status := BundleRegQueryValueEx(Key, 'Path', 0, ValueType, 0, Bytes);
    if Status = 2 then begin
      ValueType := 2;
      Exit;
    end;
    if Status <> 0 then RaiseException('Cannot inspect PATH registry type: ' + SysErrorMessage(Status));
    if (ValueType <> 1) and (ValueType <> 2) then
      RaiseException('PATH must be REG_SZ or REG_EXPAND_SZ; no value was changed.');
    if not RegQueryStringValue(ScopeRoot, EnvironmentKey, 'Path', Value) then
      RaiseException('Cannot read the persisted PATH value.');
    Exists := True;
  finally
    Status := BundleRegCloseKey(Key);
    if Status <> 0 then RaiseException('Cannot close PATH registry key: ' + SysErrorMessage(Status));
  end;
end;

procedure WritePersistedPath(const Value: String; ValueType: Cardinal; DeleteEmpty: Boolean);
var
  Success: Boolean;
begin
  if DeleteEmpty and (Value = '') then begin
    if RegValueExists(ScopeRoot, EnvironmentKey, 'Path') then
      if not RegDeleteValue(ScopeRoot, EnvironmentKey, 'Path') then
        RaiseException('Cannot remove the empty PATH value created by this product.');
    Exit;
  end;
  if ValueType = 1 then
    Success := RegWriteStringValue(ScopeRoot, EnvironmentKey, 'Path', Value)
  else
    Success := RegWriteExpandStringValue(ScopeRoot, EnvironmentKey, 'Path', Value);
  if not Success then RaiseException('Cannot update PATH in the selected installation scope.');
end;

procedure ReadPathOwnership(var Owned, Created: Cardinal; var Token: String);
var
  StoredScope, StoredDir: String;
begin
  Owned := 0;
  Created := 0;
  Token := AddBackslash(ExpandConstant('{app}')) + 'cmd';
  if not RegKeyExists(ScopeRoot, ProductKey) then Exit;
  if not RegQueryStringValue(ScopeRoot, ProductKey, 'InstallScope', StoredScope) then
    RaiseException('Missing product InstallScope metadata.');
  if StoredScope <> ScopeName then RaiseException('Product scope metadata does not match this installer.');
  if not RegQueryStringValue(ScopeRoot, ProductKey, 'InstallDir', StoredDir) then
    RaiseException('Missing product InstallDir metadata.');
  if not SameText(RemoveBackslashUnlessRoot(ExpandFileName(StoredDir)),
      RemoveBackslashUnlessRoot(ExpandFileName(ExpandConstant('{app}')))) then
    RaiseException('Product directory metadata does not match this installer.');
  if not RegQueryStringValue(ScopeRoot, ProductKey, 'PathToken', Token) then
    RaiseException('Missing product PathToken metadata.');
  if NormalizePathToken(Token) <> NormalizePathToken(AddBackslash(StoredDir) + 'cmd') then
    RaiseException('Invalid product PATH ownership token.');
  if not RegQueryDWordValue(ScopeRoot, ProductKey, 'PathOwned', Owned) then
    RaiseException('Missing product PathOwned metadata.');
  if not RegQueryDWordValue(ScopeRoot, ProductKey, 'PathCreated', Created) then
    RaiseException('Missing product PathCreated metadata.');
  if (Owned > 1) or (Created > 1) then RaiseException('Invalid product PATH ownership metadata.');
end;

procedure SavePathOwnership(Owned, Created: Cardinal; const Token: String);
begin
  if not RegWriteStringValue(ScopeRoot, ProductKey, 'InstallScope', ScopeName) then
    RaiseException('Cannot save product scope.');
  if not RegWriteStringValue(ScopeRoot, ProductKey, 'InstallDir', ExpandConstant('{app}')) then
    RaiseException('Cannot save product directory.');
  if not RegWriteStringValue(ScopeRoot, ProductKey, 'PathToken', Token) then
    RaiseException('Cannot save product PATH token.');
  if not RegWriteDWordValue(ScopeRoot, ProductKey, 'PathOwned', Owned) then
    RaiseException('Cannot save product PATH ownership.');
  if not RegWriteDWordValue(ScopeRoot, ProductKey, 'PathCreated', Created) then
    RaiseException('Cannot save product PATH creation state.');
end;

procedure ApplyPathTask;
var
  Value, Token: String;
  ValueType, Owned, Created: Cardinal;
  Exists: Boolean;
  First, Count: Integer;
begin
  ReadPathOwnership(Owned, Created, Token);
  ReadPersistedPath(Value, ValueType, Exists);
  if WizardIsTaskSelected('addtopath') then begin
    if not FindPathToken(Value, Token, First, Count) then begin
      { If a user removed our old entry, this is a new owned append. }
      Created := 0;
      if not Exists then Created := 1;
      if Value <> '' then Value := Value + ';';
      Value := Value + Token;
      { Record ownership before changing PATH so a partial failure is recoverable. }
      SavePathOwnership(1, Created, Token);
      WritePersistedPath(Value, ValueType, False);
      Owned := 1;
    end;
    { An equivalent pre-existing token is never adopted by a new installation. }
  end else begin
    if Owned = 1 then
      if RemoveOwnedToken(Value, Token) then
        WritePersistedPath(Value, ValueType, Created = 1);
    Owned := 0;
    Created := 0;
  end;
  SavePathOwnership(Owned, Created, Token);
end;

procedure RemoveProductPath;
var
  Value, Token: String;
  ValueType, Owned, Created: Cardinal;
  Exists: Boolean;
begin
  ReadPathOwnership(Owned, Created, Token);
  if Owned = 0 then Exit;
  ReadPersistedPath(Value, ValueType, Exists);
  if RemoveOwnedToken(Value, Token) then
    WritePersistedPath(Value, ValueType, Created = 1);
  { Do not restore a snapshot: unrelated changes made since install must survive. }
  SavePathOwnership(0, 0, Token);
end;
