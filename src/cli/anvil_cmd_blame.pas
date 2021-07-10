{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Porcelain command: anvil blame.
  Show what revision and author last modified each line of a file.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_cmd_blame;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_blame, anvil_cli_common, anvil_utils;

function RunCmdBlame(const Args: TStringArray): Integer;

implementation

function RunCmdBlame(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  PosArgs: TStringArray;
  TargetFile, RelPath: string;
  HeadId: TObjectId;
  BlameEngine: TBlameEngine;
  BlameLines: TBlameLineArray;
  FormattedText: string;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    PosArgs := GetPositionalArgs(Args);
    if Length(PosArgs) = 0 then
    begin
      PrintUsage('blame', '[-L <range>] <file>', 'Show what revision and author last modified each line of a file');
      Exit;
    end;

    TargetFile := PosArgs[0];
    if ExtractFilePath(TargetFile) = '' then
      RelPath := TargetFile
    else
      RelPath := MakeRelativePath(Ctx.RepoRoot, ExpandFileName(TargetFile));

    if not Ctx.RefMgr.Resolve('HEAD', HeadId) then
    begin
      PrintError('fatal: no commit to blame from: empty repository');
      Exit;
    end;

    BlameEngine := TBlameEngine.Create(Ctx.ODB, RelPath, HeadId);
    try
      BlameLines := BlameEngine.Execute;
      if Length(BlameLines) = 0 then
      begin
        PrintError('fatal: no such path ''' + RelPath + ''' in HEAD');
        Exit;
      end;

      FormattedText := BlameEngine.FormatOutput(BlameLines);
      Write(FormattedText);
      Result := 0;
    finally
      BlameEngine.Free;
    end;

  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
