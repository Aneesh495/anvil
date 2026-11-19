{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Porcelain command: anvil rm.
  Remove files from the working tree and from the index.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_cmd_rm;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_index, anvil_index_entry, anvil_cli_common, anvil_utils;

function RunCmdRm(const Args: TStringArray): Integer;

implementation

function HeadTreeId(const Ctx: TRepoContext): TObjectId;
var
  CommitId: TObjectId;
  Obj: TAnvilObject;
begin
  Result := NullObjectId(Ctx.Algo);
  if not Ctx.RefMgr.Resolve('HEAD', CommitId) then Exit;
  Obj := Ctx.ODB.ReadObject(CommitId);
  try
    if Obj is TCommitObject then
      Result := TCommitObject(Obj).TreeId;
  finally
    Obj.Free;
  end;
end;

function MatchesHead(const Odb: TObjectDatabase; const RootTree: TObjectId; const Entry: TIndexEntry): Boolean;
var
  Components: TStringArray;
  Component: string;
  TreeId: TObjectId;
  Obj: TAnvilObject;
  TreeEntry: TTreeEntry;
begin
  Result := False;
  if (Entry.Stage <> 0) or IsNullObjectId(RootTree) then Exit;
  Components := SplitStringByChar(Entry.Path, '/');
  if Length(Components) = 0 then Exit;
  TreeId := RootTree;
  for Component in Components do
  begin
    Obj := Odb.ReadObject(TreeId);
    try
      if not (Obj is TTreeObject) or not TTreeObject(Obj).FindEntry(Component, TreeEntry) then
        Exit;
      TreeId := TreeEntry.Id;
    finally
      Obj.Free;
    end;
  end;
  Result := ObjectIdEqual(TreeId, Entry.Id) and (TreeEntry.Mode = Entry.Mode);
end;

function MatchesWorkingFile(const FullPath: string; const Entry: TIndexEntry; Algo: THashAlgorithm): Boolean;
var
  Content: TFileStream;
begin
  Content := TFileStream.Create(FullPath, fmOpenRead or fmShareDenyNone);
  try
    Result := ObjectIdEqual(HashGitObjectStream(otBlob, Content, Content.Size, Algo), Entry.Id);
  finally
    Content.Free;
  end;
end;

function RunCmdRm(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  CachedOnly, CheckLocalChanges, HeadMatches, FilePresent, CanRemove: Boolean;
  PosArgs, FullPaths, RelPaths: TStringArray;
  I: Integer;
  TargetArg, RelPath, FullPath: string;
  Entry: TIndexEntry;
  HeadTree: TObjectId;
  RemovedCount: Integer;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    CachedOnly := HasFlag(Args, '', '--cached');
    CheckLocalChanges := not HasFlag(Args, '-f', '--force');
    PosArgs := GetPositionalArgs(Args);

    if Length(PosArgs) = 0 then
    begin
      PrintUsage('rm', '[-f] [--cached] <file>...', 'Remove files from the working tree and from the index');
      Exit;
    end;

    SetLength(FullPaths, Length(PosArgs));
    SetLength(RelPaths, Length(PosArgs));
    if CheckLocalChanges then
      HeadTree := HeadTreeId(Ctx);
    { Resolve all pathspecs before removing any working files. }
    for I := 0 to Length(PosArgs) - 1 do
    begin
      TargetArg := PosArgs[I];
      if ExtractFilePath(TargetArg) = '' then
        FullPath := JoinPaths(GetCurrentDir, TargetArg)
      else
        FullPath := ExpandFileName(TargetArg);

      RelPath := MakeRelativePath(Ctx.RepoRoot, FullPath);
      if not Ctx.Index.FindAny(RelPath, Entry) then
      begin
        PrintError('fatal: pathspec ''' + TargetArg + ''' did not match any files');
        Exit;
      end;
      if CheckLocalChanges then
      begin
        HeadMatches := MatchesHead(Ctx.ODB, HeadTree, Entry);
        FilePresent := FileExists(FullPath);
        if CachedOnly then
          CanRemove := HeadMatches or (FilePresent and MatchesWorkingFile(FullPath, Entry, Ctx.Algo))
        else
          CanRemove := HeadMatches and (not FilePresent or MatchesWorkingFile(FullPath, Entry, Ctx.Algo));
        if not CanRemove then
        begin
          PrintError('fatal: pathspec ''' + TargetArg + ''' has local changes. Use -f to force removal.');
          Exit;
        end;
      end;

      FullPaths[I] := FullPath;
      RelPaths[I] := RelPath;
    end;

    RemovedCount := 0;
    for I := 0 to High(RelPaths) do
    begin
      if not CachedOnly and FileExists(FullPaths[I]) and not DeleteFile(FullPaths[I]) then
      begin
        PrintError('fatal: could not remove ''' + PosArgs[I] + '''');
        Break;
      end;
      Ctx.Index.RemoveAllStages(RelPaths[I]);
      Inc(RemovedCount);
    end;

    if RemovedCount > 0 then
      Ctx.Index.WriteToFile;
    if RemovedCount = Length(RelPaths) then
      Result := 0;

  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
