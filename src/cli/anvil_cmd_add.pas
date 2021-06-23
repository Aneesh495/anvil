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
  anvil_types, anvil_errors, anvil_hash, anvil_odb, anvil_index,
  anvil_ignore, anvil_cli_common, anvil_utils;

function RunCmdAdd(const Args: TStringArray): Integer;

implementation

procedure AddPathRecursive(const RepoRoot, FullPath: string; ODB: TObjectDatabase;
                           Index: TIndex; Ignore: TIgnoreMatcher);
var
  RelPath: string;
  Rec: TSearchRec;
  SubPath: string;
  FileData: TByteArray;
  BlobId: TObjectId;
begin
  RelPath := MakeRelativePath(RepoRoot, FullPath);
  if (RelPath <> '') and (RelPath <> '.') and Ignore.IsIgnored(RelPath, DirectoryExists(FullPath)) then
    Exit;

  if DirectoryExists(FullPath) then
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
  begin
    FileData := ReadEntireFile(FullPath);
    if Length(FileData) > 0 then
      BlobId := ODB.WriteObjectRaw(otBlob, @FileData[0], Length(FileData))
    else
      BlobId := ODB.WriteObjectRaw(otBlob, nil, 0);

    Index.RemoveAllStages(RelPath);
    Index.AddFile(RelPath, BlobId, fmRegular, Length(FileData), 0);
  end;
end;

function RunCmdAdd(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  PosArgs: TStringArray;
  I: Integer;
  TargetArg, TargetPath: string;
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
          TargetPath := Ctx.RepoRoot
        else
        begin
          if ExtractFilePath(TargetArg) = '' then
            TargetPath := JoinPaths(GetCurrentDir, TargetArg)
          else
            TargetPath := ExpandFileName(TargetArg);
        end;

        if not FileExists(TargetPath) and not DirectoryExists(TargetPath) then
        begin
          PrintError('fatal: pathspec ''' + TargetArg + ''' did not match any files');
          Exit;
        end;

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
