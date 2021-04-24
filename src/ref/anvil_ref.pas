{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Reference management subsystem.
  Handles loose references, symbolic HEAD pointers, packed-refs file format,
  and atomic reference updates protected by transactional lockfiles.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_ref;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_utils;

const
  MAX_SYMREF_DEPTH = 8;
  PACKED_REFS_HEADER = '# pack-refs with: peeled fully-peeled sorted';

type
  { Reference type }
  TRefType = (
    rtDirect,    { Points directly to an ObjectId }
    rtSymbolic   { Points to another reference name (e.g. ref: refs/heads/main) }
  );

  { Single reference descriptor }
  TReference = class
  private
    FName: string;
    FRefType: TRefType;
    FTargetId: TObjectId;
    FSymbolicTarget: string;
    FPeeledId: TObjectId;
    FHasPeeled: Boolean;
  public
    constructor CreateDirect(const AName: string; const ATarget: TObjectId);
    constructor CreateSymbolic(const AName, ASymbolicTarget: string);
    function Clone: TReference;

    property Name: string read FName write FName;
    property RefType: TRefType read FRefType;
    property TargetId: TObjectId read FTargetId write FTargetId;
    property SymbolicTarget: string read FSymbolicTarget write FSymbolicTarget;
    property PeeledId: TObjectId read FPeeledId write FPeeledId;
    property HasPeeled: Boolean read FHasPeeled write FHasPeeled;
  end;

  { Reference storage manager }
  TRefManager = class
  private
    FGitDir: string;
    FAlgo: THashAlgorithm;
    FPackedRefs: TFPList; { List of TReference }
    procedure LoadPackedRefs;
    function ReadLooseRef(const RefPath: string; out Ref: TReference): Boolean;
    function WriteRefAtomic(const RefFilePath, Content: string): Boolean;
  public
    constructor Create(const AGitDir: string; Algo: THashAlgorithm = haSHA1);
    destructor Destroy; override;

    { Resolve a reference name (loose, packed, or symbolic) to an ObjectId }
    function Resolve(const RefName: string; out ResolvedId: TObjectId): Boolean;

    { Get the exact reference record (symbolic or direct) without resolving symbols }
    function GetReference(const RefName: string): TReference;

    { Atomically update or create a direct reference }
    procedure SetReference(const RefName: string; const TargetId: TObjectId);

    { Atomically update or create a symbolic reference }
    procedure SetSymbolicReference(const RefName, TargetRef: string);

    { Delete a reference (from loose storage and in-memory packed list) }
    function DeleteReference(const RefName: string): Boolean;

    { List all reference names matching a prefix (e.g. "refs/heads/") }
    function ListReferences(const Prefix: string = ''): TStringArray;

    { Consolidate all loose references into a sorted packed-refs file }
    procedure PackReferences;
  end;

function IsValidRefName(const Name: string): Boolean;

implementation

function IsValidRefName(const Name: string): Boolean;
var
  I: Integer;
begin
  if (Name = '') or (Name = 'HEAD') then
    Exit(True);

  if (Name[1] = '/') or (Name[Length(Name)] = '/') then
    Exit(False);

  if Pos('..', Name) > 0 then
    Exit(False);

  if Pos('@{', Name) > 0 then
    Exit(False);

  for I := 1 to Length(Name) do
  begin
    case Name[I] of
      ' ', '~', '^', ':', '?', '*', '[', '\': Exit(False);
      #0..#31, #127: Exit(False);
    end;
  end;

  Result := True;
end;

{ TReference implementation }

constructor TReference.CreateDirect(const AName: string; const ATarget: TObjectId);
begin
  inherited Create;
  FName := AName;
  FRefType := rtDirect;
  FTargetId := ATarget;
  FSymbolicTarget := '';
  FPeeledId := NullObjectId;
  FHasPeeled := False;
end;

constructor TReference.CreateSymbolic(const AName, ASymbolicTarget: string);
begin
  inherited Create;
  FName := AName;
  FRefType := rtSymbolic;
  FTargetId := NullObjectId;
  FSymbolicTarget := ASymbolicTarget;
  FPeeledId := NullObjectId;
  FHasPeeled := False;
end;

function TReference.Clone: TReference;
begin
  if FRefType = rtDirect then
  begin
    Result := TReference.CreateDirect(FName, FTargetId);
    Result.FPeeledId := FPeeledId;
    Result.FHasPeeled := FHasPeeled;
  end
  else
    Result := TReference.CreateSymbolic(FName, FSymbolicTarget);
end;

{ TRefManager implementation }

constructor TRefManager.Create(const AGitDir: string; Algo: THashAlgorithm);
begin
  inherited Create;
  FGitDir := AGitDir;
  FAlgo := Algo;
  FPackedRefs := TFPList.Create;
  LoadPackedRefs;
end;

destructor TRefManager.Destroy;
var
  I: Integer;
begin
  for I := 0 to FPackedRefs.Count - 1 do
    TReference(FPackedRefs[I]).Free;
  FPackedRefs.Free;
  inherited Destroy;
end;

procedure TRefManager.LoadPackedRefs;
var
  PackedPath: string;
  Content: string;
  Lines: TStringArray;
  I: Integer;
  Line: string;
  SpacePos: Integer;
  HexStr, RefName: string;
  TargetId, PeeledId: TObjectId;
  Ref: TReference;
begin
  for I := 0 to FPackedRefs.Count - 1 do
    TReference(FPackedRefs[I]).Free;
  FPackedRefs.Clear;

  PackedPath := JoinPaths(FGitDir, 'packed-refs');
  if not FileExists(PackedPath) then
    Exit;

  Content := ReadEntireFileString(PackedPath);
  Lines := SplitStringByChar(Content, #10);

  Ref := nil;
  for I := 0 to Length(Lines) - 1 do
  begin
    Line := Trim(Lines[I]);
    if (Line = '') or (Line[1] = '#') then
      Continue;

    if Line[1] = '^' then
    begin
      { Peeled tag identifier for previous reference }
      if Assigned(Ref) and TryHexToObjectId(Copy(Line, 2, Length(Line) - 1), PeeledId, FAlgo) then
      begin
        Ref.PeeledId := PeeledId;
        Ref.HasPeeled := True;
      end;
    end
    else
    begin
      SpacePos := Pos(' ', Line);
      if SpacePos > 0 then
      begin
        HexStr := Copy(Line, 1, SpacePos - 1);
        RefName := Copy(Line, SpacePos + 1, Length(Line) - SpacePos);

        if TryHexToObjectId(HexStr, TargetId, FAlgo) then
        begin
          Ref := TReference.CreateDirect(RefName, TargetId);
          FPackedRefs.Add(Ref);
        end;
      end;
    end;
  end;
end;

function TRefManager.ReadLooseRef(const RefPath: string; out Ref: TReference): Boolean;
var
  FullPath: string;
  Content: string;
  Line: string;
  TargetId: TObjectId;
begin
  Result := False;
  Ref := nil;
  FullPath := JoinPaths(FGitDir, RefPath);
  if not FileExists(FullPath) then
    Exit;

  Content := ReadEntireFileString(FullPath);
  Line := Trim(Content);
  if Line = '' then
    Exit;

  if Copy(Line, 1, 5) = 'ref: ' then
  begin
    Ref := TReference.CreateSymbolic(RefPath, Trim(Copy(Line, 6, Length(Line) - 5)));
    Result := True;
  end
  else if TryHexToObjectId(Line, TargetId, FAlgo) then
  begin
    Ref := TReference.CreateDirect(RefPath, TargetId);
    Result := True;
  end;
end;

function TRefManager.WriteRefAtomic(const RefFilePath, Content: string): Boolean;
var
  Dir: string;
  LockPath: string;
  FS: TFileStream;
begin
  Dir := ExtractFileDir(RefFilePath);
  EnsureDirectoryExists(Dir);

  LockPath := RefFilePath + '.lock';
  try
    FS := TFileStream.Create(LockPath, fmCreate);
    try
      if Length(Content) > 0 then
        FS.WriteBuffer(Content[1], Length(Content));
    finally
      FS.Free;
    end;

    { Atomically rename .lock to target }
    if FileExists(RefFilePath) then
      DeleteFile(RefFilePath);

    Result := RenameFile(LockPath, RefFilePath);
  except
    if FileExists(LockPath) then
      DeleteFile(LockPath);
    Result := False;
  end;
end;

function TRefManager.GetReference(const RefName: string): TReference;
var
  Ref: TReference;
  I: Integer;
begin
  { 1. Check loose ref first }
  if ReadLooseRef(RefName, Ref) then
    Exit(Ref);

  { 2. Check packed refs }
  for I := 0 to FPackedRefs.Count - 1 do
  begin
    Ref := TReference(FPackedRefs[I]);
    if Ref.Name = RefName then
      Exit(Ref.Clone);
  end;

  Result := nil;
end;

function TRefManager.Resolve(const RefName: string; out ResolvedId: TObjectId): Boolean;
var
  CurrName: string;
  Depth: Integer;
  Ref: TReference;
begin
  Result := False;
  ResolvedId := NullObjectId;
  CurrName := RefName;
  Depth := 0;

  while Depth < MAX_SYMREF_DEPTH do
  begin
    Ref := GetReference(CurrName);
    if not Assigned(Ref) then
    begin
      { Try looking up with refs/heads/ or refs/tags/ prefix }
      if Pos('refs/', CurrName) = 0 then
      begin
        Ref := GetReference('refs/heads/' + CurrName);
        if not Assigned(Ref) then
          Ref := GetReference('refs/tags/' + CurrName);
      end;
    end;

    if not Assigned(Ref) then
      Exit(False);

    try
      case Ref.RefType of
        rtDirect:
        begin
          ResolvedId := Ref.TargetId;
          Exit(True);
        end;
        rtSymbolic:
        begin
          CurrName := Ref.SymbolicTarget;
          Inc(Depth);
        end;
      end;
    finally
      Ref.Free;
    end;
  end;
end;

procedure TRefManager.SetReference(const RefName: string; const TargetId: TObjectId);
var
  RefPath: string;
  Content: string;
begin
  if not IsValidRefName(RefName) then
    raise EInvalidReference.CreateWithCode(ERR_INVALID_REFERENCE, 'Invalid reference name: ' + RefName);

  RefPath := JoinPaths(FGitDir, RefName);
  Content := ObjectIdToHex(TargetId) + #10;

  if not WriteRefAtomic(RefPath, Content) then
    raise EReferenceLocked.CreateWithCode(ERR_REFERENCE_LOCKED, 'Failed to lock reference for write: ' + RefName);
end;

procedure TRefManager.SetSymbolicReference(const RefName, TargetRef: string);
var
  RefPath: string;
  Content: string;
begin
  if not IsValidRefName(RefName) then
    raise EInvalidReference.CreateWithCode(ERR_INVALID_REFERENCE, 'Invalid reference name: ' + RefName);

  RefPath := JoinPaths(FGitDir, RefName);
  Content := 'ref: ' + TargetRef + #10;

  if not WriteRefAtomic(RefPath, Content) then
    raise EReferenceLocked.CreateWithCode(ERR_REFERENCE_LOCKED, 'Failed to lock reference for write: ' + RefName);
end;

function TRefManager.DeleteReference(const RefName: string): Boolean;
var
  FullPath: string;
  I: Integer;
  Ref: TReference;
begin
  Result := False;
  FullPath := JoinPaths(FGitDir, RefName);
  if FileExists(FullPath) then
    Result := DeleteFile(FullPath);

  for I := FPackedRefs.Count - 1 downto 0 do
  begin
    Ref := TReference(FPackedRefs[I]);
    if Ref.Name = RefName then
    begin
      Ref.Free;
      FPackedRefs.Delete(I);
      Result := True;
    end;
  end;
end;

function TRefManager.ListReferences(const Prefix: string): TStringArray;
var
  Rec: TSearchRec;
  BaseDir: string;
  PrefixLen: Integer;

  procedure ScanDir(const DirPath, RelPrefix: string);
  var
    SR: TSearchRec;
    ItemRel: string;
  begin
    if FindFirst(JoinPaths(DirPath, '*'), faAnyFile, SR) = 0 then
    begin
      repeat
        if (SR.Name <> '.') and (SR.Name <> '..') and (SR.Name <> '.lock') then
        begin
          if RelPrefix <> '' then
            ItemRel := RelPrefix + '/' + SR.Name
          else
            ItemRel := SR.Name;

          if (SR.Attr and faDirectory) <> 0 then
            ScanDir(JoinPaths(DirPath, SR.Name), ItemRel)
          else
          begin
            SetLength(Result, Length(Result) + 1);
            Result[Length(Result) - 1] := ItemRel;
          end;
        end;
      until FindNext(SR) <> 0;
      FindClose(SR);
    end;
  end;

var
  I, J: Integer;
  Ref: TReference;
  AlreadyPresent: Boolean;
  Tmp: string;
begin
  SetLength(Result, 0);

  { 1. Scan loose references under refs/ }
  BaseDir := JoinPaths(FGitDir, 'refs');
  if DirectoryExists(BaseDir) then
    ScanDir(BaseDir, 'refs');

  { Check HEAD }
  if FileExists(JoinPaths(FGitDir, 'HEAD')) then
  begin
    SetLength(Result, Length(Result) + 1);
    Result[Length(Result) - 1] := 'HEAD';
  end;

  { 2. Include packed references }
  for I := 0 to FPackedRefs.Count - 1 do
  begin
    Ref := TReference(FPackedRefs[I]);
    AlreadyPresent := False;
    for J := 0 to Length(Result) - 1 do
    begin
      if Result[J] = Ref.Name then
      begin
        AlreadyPresent := True;
        Break;
      end;
    end;

    if not AlreadyPresent then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[Length(Result) - 1] := Ref.Name;
    end;
  end;

  { 3. Filter by prefix if provided }
  if Prefix <> '' then
  begin
    PrefixLen := Length(Prefix);
    J := 0;
    for I := 0 to Length(Result) - 1 do
    begin
      if Copy(Result[I], 1, PrefixLen) = Prefix then
      begin
        Result[J] := Result[I];
        Inc(J);
      end;
    end;
    SetLength(Result, J);
  end;

  { 4. Sort results }
  for I := 0 to Length(Result) - 2 do
  begin
    for J := I + 1 to Length(Result) - 1 do
    begin
      if Result[I] > Result[J] then
      begin
        Tmp := Result[I];
        Result[I] := Result[J];
        Result[J] := Tmp;
      end;
    end;
  end;
end;

procedure TRefManager.PackReferences;
var
  AllRefs: TStringArray;
  I: Integer;
  RefName: string;
  TargetId: TObjectId;
  Content: string;
  PackedPath: string;
begin
  AllRefs := ListReferences('refs/');
  Content := PACKED_REFS_HEADER + #10;

  for I := 0 to Length(AllRefs) - 1 do
  begin
    RefName := AllRefs[I];
    if Resolve(RefName, TargetId) then
      Content := Content + ObjectIdToHex(TargetId) + ' ' + RefName + #10;
  end;

  PackedPath := JoinPaths(FGitDir, 'packed-refs');
  WriteRefAtomic(PackedPath, Content);
  LoadPackedRefs;
end;

end.
