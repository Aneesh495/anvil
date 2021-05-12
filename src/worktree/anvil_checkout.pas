{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Safe checkout and branch switching engine.
  Enforces dirty working tree safety constraints, checks out target tree
  snapshots into filesystem, updates staging cache, and adjusts symbolic HEAD.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_checkout;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_index, anvil_index_entry, anvil_ref, anvil_worktree, anvil_utils;

type
  { Checkout options }
  TCheckoutOptions = record
    Force: Boolean;
    BranchName: string; { e.g. "main" or "" if detached commit }
  end;

  { Checkout result report }
  TCheckoutResult = record
    Success: Boolean;
    FilesUpdated: Integer;
    FilesDeleted: Integer;
    ErrorMessage: string;
  end;

  { Safe checkout manager }
  TCheckoutManager = class
  private
    FWorkingDir: string;
    FGitDir: string;
    FODB: TObjectDatabase;
    FIndex: TIndex;
    FRefMgr: TRefManager;

    procedure FlattenTree(const Prefix: string; const TreeId: TObjectId; var List: TTreeEntryArray; var Paths: TStringArray);
    function ReadBlobBytes(const Id: TObjectId): TByteArray;
    procedure WriteFileFromBlob(const FullPath: string; const BlobId: TObjectId; Mode: TFileMode);
  public
    constructor Create(const AWorkingDir, AGitDir: string;
                       AODB: TObjectDatabase; AIndex: TIndex; ARefMgr: TRefManager);

    { Perform safe checkout of target commit or tree }
    function CheckoutCommit(const TargetCommitId: TObjectId; const Options: TCheckoutOptions): TCheckoutResult;
    function CheckoutTree(const TargetTreeId: TObjectId; Force: Boolean = False): TCheckoutResult;
  end;

implementation

constructor TCheckoutManager.Create(const AWorkingDir, AGitDir: string;
                                    AODB: TObjectDatabase; AIndex: TIndex; ARefMgr: TRefManager);
begin
  inherited Create;
  FWorkingDir := AWorkingDir;
  FGitDir := AGitDir;
  FODB := AODB;
  FIndex := AIndex;
  FRefMgr := ARefMgr;
end;

procedure TCheckoutManager.FlattenTree(const Prefix: string; const TreeId: TObjectId;
                                      var List: TTreeEntryArray; var Paths: TStringArray);
var
  Obj: TAnvilObject;
  Tree: TTreeObject;
  I: Integer;
  Entry: TTreeEntry;
  ChildPrefix: string;
begin
  if IsNullObjectId(TreeId) then Exit;
  Obj := FODB.ReadObject(TreeId);
  if not Assigned(Obj) then Exit;
  if not (Obj is TTreeObject) then
  begin
    Obj.Free;
    Exit;
  end;

  Tree := TTreeObject(Obj);
  try
    for I := 0 to Tree.Count - 1 do
    begin
      Entry := Tree.GetEntry(I);
      if Prefix <> '' then
        ChildPrefix := Prefix + '/' + Entry.Name
      else
        ChildPrefix := Entry.Name;

      if Entry.Mode = fmDirectory then
        FlattenTree(ChildPrefix, Entry.Id, List, Paths)
      else
      begin
        SetLength(List, Length(List) + 1);
        List[Length(List) - 1] := Entry;
        SetLength(Paths, Length(Paths) + 1);
        Paths[Length(Paths) - 1] := ChildPrefix;
      end;
    end;
  finally
    Tree.Free;
  end;
end;

function TCheckoutManager.ReadBlobBytes(const Id: TObjectId): TByteArray;
var
  Obj: TAnvilObject;
  Blob: TBlobObject;
begin
  Obj := FODB.ReadObject(Id);
  if not Assigned(Obj) then
    raise EObjectNotFound.CreateForObject(Id);
  if not (Obj is TBlobObject) then
  begin
    Obj.Free;
    raise ECorruptObject.Create('Expected blob object: ' + ObjectIdToHex(Id));
  end;

  Blob := TBlobObject(Obj);
  try
    Result := Copy(Blob.Data, 0, Length(Blob.Data));
  finally
    Blob.Free;
  end;
end;

procedure TCheckoutManager.WriteFileFromBlob(const FullPath: string; const BlobId: TObjectId; Mode: TFileMode);
var
  Bytes: TByteArray;
  Dir: string;
begin
  Bytes := ReadBlobBytes(BlobId);
  Dir := ExtractFileDir(FullPath);
  EnsureDirectoryExists(Dir);
  WriteEntireFile(FullPath, Bytes);
end;

function TCheckoutManager.CheckoutTree(const TargetTreeId: TObjectId; Force: Boolean): TCheckoutResult;
var
  TargetEntries: TTreeEntryArray;
  TargetPaths: TStringArray;
  I, J: Integer;
  Path, FullPath: string;
  Entry: TIndexEntry;
  IdxEntry: TIndexEntry;
  FoundTarget: Boolean;
  TargetId: TObjectId;
  TargetMode: TFileMode;
  NowTime: TDateTime;
  CurrentHeadTreeId: TObjectId;
  Status: TWorktreeStatus;
begin
  Result.Success := False;
  Result.FilesUpdated := 0;
  Result.FilesDeleted := 0;
  Result.ErrorMessage := '';

  { 1. Dirty check: check if any uncommitted changes would be clobbered }
  if not Force then
  begin
    CurrentHeadTreeId := NullObjectId;
    if FRefMgr.Resolve('HEAD', TargetId) then
    begin
      { If HEAD resolves to a commit, find its tree }
      try
        TargetEntries := nil;
        TargetPaths := nil;
        FlattenTree('', TargetTreeId, TargetEntries, TargetPaths);
      except
      end;
    end;

    Status := GetWorkingTreeStatus(FWorkingDir, FGitDir, FODB, FIndex, TargetTreeId);
    if Length(Status.UnstagedModified) > 0 then
    begin
      Result.ErrorMessage := 'Cannot checkout: working tree contains unstaged modifications';
      Exit;
    end;
  end;

  { Flatten target tree }
  SetLength(TargetEntries, 0);
  SetLength(TargetPaths, 0);
  FlattenTree('', TargetTreeId, TargetEntries, TargetPaths);

  { 2. Delete files that exist in current index but are absent from target tree }
  for I := 0 to FIndex.Count - 1 do
  begin
    Path := FIndex.GetEntry(I).Path;
    FoundTarget := False;
    for J := 0 to Length(TargetPaths) - 1 do
    begin
      if TargetPaths[J] = Path then
      begin
        FoundTarget := True;
        Break;
      end;
    end;

    if not FoundTarget then
    begin
      FullPath := JoinPaths(FWorkingDir, Path);
      if FileExists(FullPath) then
      begin
        DeleteFile(FullPath);
        Inc(Result.FilesDeleted);
      end;
    end;
  end;

  { 3. Write target files onto disk }
  for I := 0 to Length(TargetPaths) - 1 do
  begin
    Path := TargetPaths[I];
    FullPath := JoinPaths(FWorkingDir, Path);
    TargetId := TargetEntries[I].Id;
    TargetMode := TargetEntries[I].Mode;

    WriteFileFromBlob(FullPath, TargetId, TargetMode);
    Inc(Result.FilesUpdated);
  end;

  { 4. Rebuild Index from target tree }
  FIndex.Clear;
  NowTime := Now;

  for I := 0 to Length(TargetPaths) - 1 do
  begin
    Path := TargetPaths[I];
    TargetId := TargetEntries[I].Id;
    TargetMode := TargetEntries[I].Mode;

    IdxEntry := MakeIndexEntry(Path, TargetId, TargetMode, 0, 0);
    FIndex.Add(IdxEntry);
  end;

  FIndex.WriteToFile;
  Result.Success := True;
end;

function TCheckoutManager.CheckoutCommit(const TargetCommitId: TObjectId; const Options: TCheckoutOptions): TCheckoutResult;
var
  Obj: TAnvilObject;
  Commit: TCommitObject;
  TreeRes: TCheckoutResult;
begin
  Result.Success := False;
  Result.FilesUpdated := 0;
  Result.FilesDeleted := 0;
  Result.ErrorMessage := '';

  Obj := FODB.ReadObject(TargetCommitId);
  if not Assigned(Obj) then
    raise EObjectNotFound.CreateForObject(TargetCommitId);
  if not (Obj is TCommitObject) then
  begin
    Obj.Free;
    raise ECorruptObject.Create('Object is not a commit: ' + ObjectIdToHex(TargetCommitId));
  end;

  Commit := TCommitObject(Obj);
  try
    TreeRes := CheckoutTree(Commit.TreeId, Options.Force);
    if not TreeRes.Success then
      Exit(TreeRes);

    Result := TreeRes;

    { Update HEAD reference }
    if Options.BranchName <> '' then
      FRefMgr.SetSymbolicReference('HEAD', 'refs/heads/' + Options.BranchName)
    else
      FRefMgr.SetReference('HEAD', TargetCommitId);

    Result.Success := True;
  finally
    Commit.Free;
  end;
end;

end.
