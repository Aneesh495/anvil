{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  C ABI foreign function interface (FFI) shared library.
  Exports stable C-compatible symbols for embedding Anvil into Python,
  C, C++, Rust, and external language runtimes.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

library libanvil;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, DateUtils,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_ref, anvil_reflog, anvil_index, anvil_index_entry,
  anvil_worktree, anvil_checkout, anvil_lca, anvil_merge_tree,
  anvil_cli_common, anvil_utils;

type
  { Opaque repository context pointer wrapper for C clients }
  PAnvilRepo = ^TAnvilRepoHandle;
  TAnvilRepoHandle = record
    Ctx: TRepoContext;
  end;

const
  ANVIL_LIB_VERSION = '1.0.0';

{ Exports }

function anvil_version(): PChar; cdecl; export;
begin
  Result := PChar(ANVIL_LIB_VERSION);
end;

function anvil_repo_open(const APath: PChar): Pointer; cdecl; export;
var
  Handle: PAnvilRepo;
  RepoRoot, DotDir: string;
  StartPath: string;
begin
  if APath = nil then
    StartPath := GetCurrentDir
  else
    StartPath := StrPas(APath);

  if not FindRepositoryRoot(StartPath, RepoRoot, DotDir) then
    Exit(nil);

  New(Handle);
  FillChar(Handle^, SizeOf(TAnvilRepoHandle), 0);
  Handle^.Ctx.Algo := haSHA1;
  Handle^.Ctx.RepoRoot := RepoRoot;
  Handle^.Ctx.GitDir := DotDir;
  Handle^.Ctx.ODB := TObjectDatabase.Create(JoinPaths(DotDir, 'objects'), Handle^.Ctx.Algo);
  Handle^.Ctx.RefMgr := TRefManager.Create(DotDir, Handle^.Ctx.Algo);
  Handle^.Ctx.Index := TIndex.Create(JoinPaths(DotDir, 'index'), Handle^.Ctx.Algo);

  Result := Handle;
end;

procedure anvil_repo_close(Repo: Pointer); cdecl; export;
var
  Handle: PAnvilRepo;
begin
  if Repo = nil then Exit;
  Handle := PAnvilRepo(Repo);
  CloseRepoContext(Handle^.Ctx);
  Dispose(Handle);
end;

function anvil_repo_init(const APath: PChar; IsBare: LongBool): Integer; cdecl; export;
var
  TargetDir, DotDir: string;
  ConfigContent: string;
begin
  if APath = nil then
    TargetDir := GetCurrentDir
  else
    TargetDir := ExpandFileName(StrPas(APath));

  if IsBare then
    DotDir := TargetDir
  else
    DotDir := JoinPaths(TargetDir, '.anvil');

  EnsureDirectoryExists(DotDir);
  EnsureDirectoryExists(JoinPaths(DotDir, 'objects'));
  EnsureDirectoryExists(JoinPaths(DotDir, JoinPaths('objects', 'pack')));
  EnsureDirectoryExists(JoinPaths(DotDir, 'refs'));
  EnsureDirectoryExists(JoinPaths(DotDir, JoinPaths('refs', 'heads')));
  EnsureDirectoryExists(JoinPaths(DotDir, JoinPaths('refs', 'tags')));
  EnsureDirectoryExists(JoinPaths(DotDir, 'logs'));
  EnsureDirectoryExists(JoinPaths(DotDir, JoinPaths('logs', 'refs')));
  EnsureDirectoryExists(JoinPaths(DotDir, JoinPaths('logs', JoinPaths('refs', 'heads'))));

  WriteEntireFileString(JoinPaths(DotDir, 'HEAD'), 'ref: refs/heads/main'#10);

  ConfigContent :=
    '[core]'#10 +
    #9'repositoryformatversion = 0'#10 +
    #9'filemode = true'#10 +
    #9'bare = ' + BoolToStr(IsBare, 'true', 'false') + #10 +
    #9'logallrefupdates = true'#10;
  WriteEntireFileString(JoinPaths(DotDir, 'config'), ConfigContent);

  Result := 0;
end;

function anvil_hash_buffer(const Data: Pointer; Len: Integer; OutHex: PChar): Integer; cdecl; export;
var
  Blob: TBlobObject;
  Hex: string;
begin
  if OutHex = nil then Exit(-1);
  if Len > 0 then
    Blob := TBlobObject.CreateWithData(Data, Len)
  else
    Blob := TBlobObject.CreateWithData(nil, 0);
  try
    Hex := ObjectIdToHex(Blob.ObjectId);
    StrLCopy(OutHex, PChar(Hex), 40);
    Result := 0;
  finally
    Blob.Free;
  end;
end;

function anvil_add(Repo: Pointer; const FilePath: PChar): Integer; cdecl; export;
var
  Handle: PAnvilRepo;
  FullPath, RelPath: string;
  Data: TByteArray;
  BlobId: TObjectId;
begin
  if (Repo = nil) or (FilePath = nil) then Exit(-1);
  Handle := PAnvilRepo(Repo);

  FullPath := ExpandFileName(StrPas(FilePath));
  if not FileExists(FullPath) then Exit(-2);

  RelPath := MakeRelativePath(Handle^.Ctx.RepoRoot, FullPath);
  Data := ReadEntireFile(FullPath);
  if Length(Data) > 0 then
    BlobId := Handle^.Ctx.ODB.WriteObjectRaw(otBlob, @Data[0], Length(Data))
  else
    BlobId := Handle^.Ctx.ODB.WriteObjectRaw(otBlob, nil, 0);

  Handle^.Ctx.Index.RemoveAllStages(RelPath);
  Handle^.Ctx.Index.AddFile(RelPath, BlobId, fmRegular, Length(Data), 0);
  Handle^.Ctx.Index.WriteToFile;

  Result := 0;
end;

function anvil_commit(Repo: Pointer; const Msg: PChar; OutCommitHex: PChar; MaxLen: Integer): Integer; cdecl; export;
var
  Handle: PAnvilRepo;
  TreeId, HeadCommitId, NewCommitId: TObjectId;
  HasHead: Boolean;
  CommitObj: TCommitObject;
  HeadRef: TReference;
  BranchName: string;
  Identity: TIdentity;
  Hex: string;
  MsgStr: string;
  ReflogMgr: TReflogManager;
begin
  if (Repo = nil) or (Msg = nil) then Exit(-1);
  Handle := PAnvilRepo(Repo);

  if Handle^.Ctx.Index.Count = 0 then Exit(-2);
  TreeId := Handle^.Ctx.Index.WriteTree(Handle^.Ctx.ODB);
  HasHead := Handle^.Ctx.RefMgr.Resolve('HEAD', HeadCommitId);

  CommitObj := TCommitObject.Create;
  try
    CommitObj.TreeId := TreeId;
    if HasHead then
      CommitObj.AddParent(HeadCommitId);

    Identity := MakeIdentity('Aneesh Krishna', 'aneesh@engine.internal', DateTimeToUnix(Now), 0);
    CommitObj.Author := Identity;
    CommitObj.Committer := Identity;
    MsgStr := StrPas(Msg);
    if (MsgStr = '') or (MsgStr[Length(MsgStr)] <> #10) then
      MsgStr := MsgStr + #10;
    CommitObj.Message := MsgStr;

    NewCommitId := Handle^.Ctx.ODB.WriteObject(CommitObj);

    HeadRef := Handle^.Ctx.RefMgr.GetReference('HEAD');
    if (HeadRef <> nil) and (HeadRef.RefType = rtSymbolic) then
      BranchName := HeadRef.SymbolicTarget
    else
      BranchName := 'HEAD';

    Handle^.Ctx.RefMgr.SetReference(BranchName, NewCommitId);

    ReflogMgr := TReflogManager.Create(Handle^.Ctx.GitDir, Handle^.Ctx.Algo);
    try
      ReflogMgr.Append(BranchName, HeadCommitId, NewCommitId, Identity, 'commit: ' + Copy(MsgStr, 1, Length(MsgStr) - 1));
    finally
      ReflogMgr.Free;
    end;

    if OutCommitHex <> nil then
    begin
      Hex := ObjectIdToHex(NewCommitId);
      StrLCopy(OutCommitHex, PChar(Hex), MaxLen);
    end;

    Result := 0;
  finally
    CommitObj.Free;
  end;
end;

function anvil_status(Repo: Pointer; out IsCleanVal: LongBool; out StagedCount: Integer): Integer; cdecl; export;
var
  Handle: PAnvilRepo;
  Scanner: TWorktreeScanner;
  Status: TWorktreeStatus;
  HeadCommitId, HeadTreeId: TObjectId;
  ObjType: TObjectType;
  RawData: TByteArray;
  CommitObj: TCommitObject;
begin
  if Repo = nil then Exit(-1);
  Handle := PAnvilRepo(Repo);

  HeadTreeId := NullObjectId(Handle^.Ctx.Algo);
  if Handle^.Ctx.RefMgr.Resolve('HEAD', HeadCommitId) then
  begin
    if Handle^.Ctx.ODB.ReadObjectRaw(HeadCommitId, ObjType, RawData) and (ObjType = otCommit) then
    begin
      CommitObj := TCommitObject.Create;
      try
        CommitObj.Deserialize(@RawData[0], Length(RawData));
        HeadTreeId := CommitObj.TreeId;
      finally
        CommitObj.Free;
      end;
    end;
  end;

  Scanner := TWorktreeScanner.Create(Handle^.Ctx.RepoRoot, Handle^.Ctx.GitDir, Handle^.Ctx.ODB, Handle^.Ctx.Index);
  try
    Status := Scanner.ComputeStatus(HeadTreeId);
    IsCleanVal := Status.IsClean;
    StagedCount := Length(Status.StagedNew) + Length(Status.StagedModified) + Length(Status.StagedDeleted);
    Result := 0;
  finally
    Scanner.Free;
  end;
end;

function anvil_branch_create(Repo: Pointer; const Name: PChar; const StartRev: PChar): Integer; cdecl; export;
var
  Handle: PAnvilRepo;
  BranchName, StartRevStr, FullRef: string;
  TargetId, ExistingId: TObjectId;
begin
  if (Repo = nil) or (Name = nil) then Exit(-1);
  Handle := PAnvilRepo(Repo);

  BranchName := StrPas(Name);
  if StartRev <> nil then
    StartRevStr := StrPas(StartRev)
  else
    StartRevStr := 'HEAD';

  if not ResolveRevision(Handle^.Ctx, StartRevStr, TargetId) then Exit(-2);

  FullRef := 'refs/heads/' + BranchName;
  if Handle^.Ctx.RefMgr.Resolve(FullRef, ExistingId) then Exit(-3);

  Handle^.Ctx.RefMgr.SetReference(FullRef, TargetId);
  Result := 0;
end;

function anvil_checkout(Repo: Pointer; const Target: PChar): Integer; cdecl; export;
var
  Handle: PAnvilRepo;
  TargetStr: string;
  TargetCommitId: TObjectId;
  CheckoutMgr: TCheckoutManager;
  Options: TCheckoutOptions;
  CheckRes: TCheckoutResult;
  IsBranch: Boolean;
begin
  if (Repo = nil) or (Target = nil) then Exit(-1);
  Handle := PAnvilRepo(Repo);

  TargetStr := StrPas(Target);
  IsBranch := Handle^.Ctx.RefMgr.Resolve('refs/heads/' + TargetStr, TargetCommitId);
  if not IsBranch then
  begin
    if not ResolveRevision(Handle^.Ctx, TargetStr, TargetCommitId) then
      Exit(-2);
  end;

  CheckoutMgr := TCheckoutManager.Create(Handle^.Ctx.RepoRoot, Handle^.Ctx.GitDir, Handle^.Ctx.ODB, Handle^.Ctx.Index, Handle^.Ctx.RefMgr);
  try
    Options.Force := False;
    if IsBranch then
      Options.BranchName := TargetStr
    else
      Options.BranchName := '';

    CheckRes := CheckoutMgr.CheckoutCommit(TargetCommitId, Options);
    if CheckRes.Success then
      Result := 0
    else
      Result := -3;
  finally
    CheckoutMgr.Free;
  end;
end;

function anvil_rev_parse(Repo: Pointer; const RevExpr: PChar; OutHex: PChar; MaxLen: Integer): Integer; cdecl; export;
var
  Handle: PAnvilRepo;
  Expr: string;
  ResolvedId: TObjectId;
  Hex: string;
begin
  if (Repo = nil) or (RevExpr = nil) or (OutHex = nil) then Exit(-1);
  Handle := PAnvilRepo(Repo);

  Expr := StrPas(RevExpr);
  if ResolveRevision(Handle^.Ctx, Expr, ResolvedId) then
  begin
    Hex := ObjectIdToHex(ResolvedId);
    StrLCopy(OutHex, PChar(Hex), MaxLen);
    Result := 0;
  end
  else
    Result := -2;
end;

exports
  anvil_version,
  anvil_repo_open,
  anvil_repo_close,
  anvil_repo_init,
  anvil_hash_buffer,
  anvil_add,
  anvil_commit,
  anvil_status,
  anvil_branch_create,
  anvil_checkout,
  anvil_rev_parse;

begin
end.
