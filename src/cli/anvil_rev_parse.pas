{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Plumbing command: anvil rev-parse.
  Resolves revisions, flags, and repository parameters.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_rev_parse;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_odb, anvil_ref,
  anvil_cli_common;

function RunCmdRevParse(const Args: TStringArray): Integer;

implementation

function RunCmdRevParse(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  I: Integer;
  Arg: string;
  ResolvedId: TObjectId;
  AllSuccess: Boolean;
begin
  Result := 1;
  if HasFlag(Args, '', '--git-dir') then
  begin
    if OpenRepoContext(Ctx, True) then
    begin
      Writeln(Ctx.GitDir);
      CloseRepoContext(Ctx);
      Result := 0;
      Exit;
    end;
    Exit;
  end;

  if HasFlag(Args, '', '--show-toplevel') then
  begin
    if OpenRepoContext(Ctx, True) then
    begin
      Writeln(Ctx.RepoRoot);
      CloseRepoContext(Ctx);
      Result := 0;
      Exit;
    end;
    Exit;
  end;

  if not OpenRepoContext(Ctx) then Exit;
  try
    AllSuccess := True;
    for I := 0 to Length(Args) - 1 do
    begin
      Arg := Args[I];
      if (Length(Arg) > 0) and (Arg[1] = '-') then Continue;

      if ResolveRevision(Ctx, Arg, ResolvedId) then
        Writeln(ObjectIdToHex(ResolvedId))
      else
      begin
        PrintError('fatal: ambiguous argument ''' + Arg + ''': unknown revision or path');
        AllSuccess := False;
      end;
    end;

    if AllSuccess then
      Result := 0;
  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
