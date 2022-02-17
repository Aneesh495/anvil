{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Porcelain command: anvil add.
  Updates the index using the current content found in the working tree,
  to prepare the content staged for the next commit.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_cmd_add;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_odb, anvil_index, anvil_index_entry,
  anvil_ignore, anvil_cli_common, anvil_utils;

function RunCmdAdd(const Args: TStringArray): Integer;

implementation

procedure StageRegularFile(const FullPath, RelPath: string; ODB: TObjectDatabase; Index: TIndex);
var
  FileData: TByteArray;
  BlobId: TObjectId;
begin
  FileData := ReadEntireFile(FullPath);
  if Length(FileData) > 0 then
    BlobId := ODB.WriteObjectRaw(otBlob, @FileData[0], Length(FileData))
  else
    BlobId := ODB.WriteObjectRaw(otBlob, nil, 0);

  Index.RemoveAllStages(RelPath);
  Index.AddFile(RelPath, BlobId, fmRegular, Length(FileData), 0);
end;

procedure StageTrackedBelow(const RepoRoot, RelPath: string; ODB: TObjectDatabase; Index: TIndex);
var
  Prefix, FullPath: string;
  TrackedPaths: TStringList;
  Entry: TIndexEntry;
  I: Integer;
begin
  Prefix := RelPath + '/';
  TrackedPaths := TStringList.Create;
  try
    { Collect paths before staging changes the index being traversed. }
    for I := 0 to Index.Count - 1 do
    begin
      Entry := Index.GetEntry(I);
      if Copy(Entry.Path, 1, Length(Prefix)) = Prefix then
        TrackedPaths.Add(Entry.Path);
    end;
    for I := 0 to TrackedPaths.Count - 1 do
    begin
      FullPath := JoinPaths(RepoRoot, TrackedPaths[I]);
      if FileExists(FullPath) then
        StageRegularFile(FullPath, TrackedPaths[I], ODB, Index);
    end;
  finally
    TrackedPaths.Free;
  end;
end;

procedure AddPathRecursive(const RepoRoot, FullPath: string; ODB: TObjectDatabase;
                           Index: TIndex; Ignore: TIgnoreMatcher);
var
  RelPath: string;
  Rec: TSearchRec;
  SubPath: string;
  IsDirectory: Boolean;
  Entry: TIndexEntry;
begin
  RelPath := MakeRelativePath(RepoRoot, FullPath);
  IsDirectory := DirectoryExists(FullPath);
  if (RelPath <> '') and (RelPath <> '.') and Ignore.IsIgnored(RelPath, IsDirectory) then
  begin
    if IsDirectory then
    begin
      StageTrackedBelow(RepoRoot, RelPath, ODB, Index);
      Exit;
    end;
    if not Index.FindAny(RelPath, Entry) then
      Exit;
  end;

  if IsDirectory then
  begin
    if FindFirst(JoinPaths(FullPath, '*'), faAnyFile, Rec) = 0 then
    begin
      repeat
        if (Rec.Name <> '.') and (Rec.Name <> '..') and (Rec.Name <> '.anvil') and (Rec.Name <> '.git') then
        begin
          SubPath := JoinPaths(FullPath, Rec.Name);
          AddPathRecursive(RepoRoot, SubPath, ODB, Index, Ignore);
        end;
      until FindNext(Rec) <> 0;
      FindClose(Rec);
    end;
  end
  else if FileExists(FullPath) then
    StageRegularFile(FullPath, RelPath, ODB, Index);
end;

procedure StageDirectoryDeletions(const RepoRoot, Scope: string; Index: TIndex);
var
  Prefix, FullPath: string;
  Entry: TIndexEntry;
  Missing: TStringList;
  I: Integer;
begin
  Prefix := '';
  if Scope <> '.' then
    Prefix := Scope + '/';
  Missing := TStringList.Create;
  try
    for I := 0 to Index.Count - 1 do
    begin
      Entry := Index.GetEntry(I);
      if (Prefix <> '') and (Copy(Entry.Path, 1, Length(Prefix)) <> Prefix) then
        Continue;
      FullPath := JoinPaths(RepoRoot, Entry.Path);
      if not FileExists(FullPath, False) and not DirectoryExists(FullPath, False) then
        Missing.Add(Entry.Path);
    end;
    for I := 0 to Missing.Count - 1 do
      Index.RemoveAllStages(Missing[I]);
  finally
    Missing.Free;
  end;
end;

function RunCmdAdd(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  Entry: TIndexEntry;
  PosArgs: TStringArray;
  I: Integer;
  TargetArg, TargetPath, RelPath: string;
  Ignore: TIgnoreMatcher;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    PosArgs := GetPositionalArgs(Args);
    if Length(PosArgs) = 0 then
    begin
      PrintUsage('add', '<pathspec>...', 'Add file contents to the index');
      Exit;
    end;

    Ignore := TIgnoreMatcher.Create(Ctx.RepoRoot);
    try
      if FileExists(JoinPaths(Ctx.RepoRoot, '.gitignore')) then
        Ignore.LoadFile(JoinPaths(Ctx.RepoRoot, '.gitignore'));

      for I := 0 to Length(PosArgs) - 1 do
      begin
        TargetArg := PosArgs[I];
        if TargetArg = '.' then
          TargetPath := GetCurrentDir
        else
        begin
          if ExtractFilePath(TargetArg) = '' then
            TargetPath := JoinPaths(GetCurrentDir, TargetArg)
          else
            TargetPath := ExpandFileName(TargetArg);
        end;

        TargetPath := ExpandFileName(TargetPath);
        RelPath := MakeRelativePath(Ctx.RepoRoot, TargetPath);
        if (RelPath = '') or (RelPath[1] = '/') then
        begin
          PrintError('fatal: pathspec ''' + TargetArg + ''' is outside the repository');
          Exit;
        end;

        if not FileExists(TargetPath) and not DirectoryExists(TargetPath) then
        begin
          if Ctx.Index.FindAny(RelPath, Entry) then
          begin
            Ctx.Index.RemoveAllStages(RelPath);
            Continue;
          end;
          PrintError('fatal: pathspec ''' + TargetArg + ''' did not match any files');
          Exit;
        end;

        if DirectoryExists(TargetPath) then
          StageDirectoryDeletions(Ctx.RepoRoot, RelPath, Ctx.Index);
        AddPathRecursive(Ctx.RepoRoot, TargetPath, Ctx.ODB, Ctx.Index, Ignore);
      end;

      Ctx.Index.WriteToFile;
      Result := 0;
    finally
      Ignore.Free;
    end;

  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
