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
  anvil_types, anvil_errors, anvil_index, anvil_index_entry, anvil_cli_common, anvil_utils;

function RunCmdRm(const Args: TStringArray): Integer;

implementation

function RunCmdRm(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  CachedOnly: Boolean;
  PosArgs: TStringArray;
  I: Integer;
  TargetArg, RelPath, FullPath: string;
  Entry: TIndexEntry;
  RemovedCount: Integer;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    CachedOnly := HasFlag(Args, '', '--cached');
    PosArgs := GetPositionalArgs(Args);

    if Length(PosArgs) = 0 then
    begin
      PrintUsage('rm', '[--cached] <file>...', 'Remove files from the working tree and from the index');
      Exit;
    end;

    RemovedCount := 0;
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

      Ctx.Index.RemoveAllStages(RelPath);
      Inc(RemovedCount);

      if not CachedOnly then
      begin
        if FileExists(FullPath) then
          DeleteFile(FullPath);
      end;
    end;

    if RemovedCount > 0 then
    begin
      Ctx.Index.WriteToFile;
      Result := 0;
    end;

  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
