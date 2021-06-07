{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Shared CLI execution context, argument parsing primitives, and repository loaders.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_cli_common;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_odb, anvil_ref, anvil_reflog, anvil_revision, anvil_index, anvil_utils;

type
  { Open repository session context }
  TRepoContext = record
    RepoRoot: string;
    GitDir: string;
    ODB: TObjectDatabase;
    RefMgr: TRefManager;
    Index: TIndex;
    Algo: THashAlgorithm;
  end;

{ Repository discovery and context initialization }
function OpenRepoContext(out Ctx: TRepoContext; Required: Boolean = True): Boolean;
procedure CloseRepoContext(var Ctx: TRepoContext);

{ High-level revision resolution helpers }
function ResolveRevision(const Ctx: TRepoContext; const RevExpr: string; out Id: TObjectId): Boolean;
function ResolveRevisionRange(const Ctx: TRepoContext; const RangeExpr: string;
                              out IncludeIds, ExcludeIds: TObjectIdArray): Boolean;

{ Command line option parsers }
function HasFlag(const Args: TStringArray; const ShortFlag, LongFlag: string): Boolean;
function GetOptionValue(const Args: TStringArray; const ShortFlag, LongFlag: string; out Val: string): Boolean;
function GetPositionalArgs(const Args: TStringArray): TStringArray;

{ Standard CLI printing }
procedure PrintError(const Msg: string);
procedure PrintUsage(const CmdName, UsageStr, DescriptionStr: string);

implementation

function OpenRepoContext(out Ctx: TRepoContext; Required: Boolean): Boolean;
var
  CurrentDir: string;
  RepoRoot, DotDir: string;
begin
  Result := False;
  FillChar(Ctx, SizeOf(Ctx), 0);
  Ctx.Algo := haSHA1;

  CurrentDir := GetCurrentDir;
  if not FindRepositoryRoot(CurrentDir, RepoRoot, DotDir) then
  begin
    if Required then
      PrintError('fatal: not an anvil repository (or any of the parent directories): .anvil');
    Exit(False);
  end;

  Ctx.RepoRoot := RepoRoot;
  Ctx.GitDir := DotDir;
  Ctx.ODB := TObjectDatabase.Create(JoinPaths(DotDir, 'objects'), Ctx.Algo);
  Ctx.RefMgr := TRefManager.Create(DotDir, Ctx.Algo);
  Ctx.Index := TIndex.Create(JoinPaths(DotDir, 'index'), Ctx.Algo);

  Result := True;
end;

procedure CloseRepoContext(var Ctx: TRepoContext);
begin
  if Assigned(Ctx.Index) then
  begin
    Ctx.Index.Free;
    Ctx.Index := nil;
  end;
  if Assigned(Ctx.RefMgr) then
  begin
    Ctx.RefMgr.Free;
    Ctx.RefMgr := nil;
  end;
  if Assigned(Ctx.ODB) then
  begin
    Ctx.ODB.Free;
    Ctx.ODB := nil;
  end;
end;

function ResolveRevision(const Ctx: TRepoContext; const RevExpr: string; out Id: TObjectId): Boolean;
var
  ReflogMgr: TReflogManager;
  Parser: TRevisionParser;
begin
  ReflogMgr := TReflogManager.Create(Ctx.GitDir, Ctx.Algo);
  try
    Parser := TRevisionParser.Create(Ctx.RefMgr, ReflogMgr, Ctx.ODB, Ctx.Algo);
    try
      Result := Parser.Resolve(RevExpr, Id);
    finally
      Parser.Free;
    end;
  finally
    ReflogMgr.Free;
  end;
end;

function ResolveRevisionRange(const Ctx: TRepoContext; const RangeExpr: string;
                              out IncludeIds, ExcludeIds: TObjectIdArray): Boolean;
var
  ReflogMgr: TReflogManager;
  Parser: TRevisionParser;
begin
  ReflogMgr := TReflogManager.Create(Ctx.GitDir, Ctx.Algo);
  try
    Parser := TRevisionParser.Create(Ctx.RefMgr, ReflogMgr, Ctx.ODB, Ctx.Algo);
    try
      Result := Parser.ParseRange(RangeExpr, IncludeIds, ExcludeIds);
    finally
      Parser.Free;
    end;
  finally
    ReflogMgr.Free;
  end;
end;

function HasFlag(const Args: TStringArray; const ShortFlag, LongFlag: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to Length(Args) - 1 do
  begin
    if ((ShortFlag <> '') and (Args[I] = ShortFlag)) or
       ((LongFlag <> '') and (Args[I] = LongFlag)) then
      Exit(True);
  end;
end;

function GetOptionValue(const Args: TStringArray; const ShortFlag, LongFlag: string; out Val: string): Boolean;
var
  I: Integer;
  Arg: string;
begin
  Result := False;
  Val := '';
  I := 0;
  while I < Length(Args) do
  begin
    Arg := Args[I];
    if ((ShortFlag <> '') and (Arg = ShortFlag)) or
       ((LongFlag <> '') and (Arg = LongFlag)) then
    begin
      if I + 1 < Length(Args) then
      begin
        Val := Args[I + 1];
        Exit(True);
      end;
    end
    else if (LongFlag <> '') and (Copy(Arg, 1, Length(LongFlag) + 1) = LongFlag + '=') then
    begin
      Val := Copy(Arg, Length(LongFlag) + 2, Length(Arg) - Length(LongFlag) - 1);
      Exit(True);
    end;
    Inc(I);
  end;
end;

function GetPositionalArgs(const Args: TStringArray): TStringArray;
var
  I, Count: Integer;
  SkipNext: Boolean;
begin
  Result := nil;
  SetLength(Result, Length(Args));
  Count := 0;
  SkipNext := False;

  for I := 0 to Length(Args) - 1 do
  begin
    if SkipNext then
    begin
      SkipNext := False;
      Continue;
    end;

    if (Args[I] = '-m') or (Args[I] = '-p') or (Args[I] = '-t') or
       (Args[I] = '-b') or (Args[I] = '-n') or (Args[I] = '-L') then
    begin
      SkipNext := True;
      Continue;
    end;

    if (Length(Args[I]) > 0) and (Args[I][1] = '-') then
      Continue; { Flag or option }

    Result[Count] := Args[I];
    Inc(Count);
  end;

  SetLength(Result, Count);
end;

procedure PrintError(const Msg: string);
begin
  Writeln(StdErr, Msg);
end;

procedure PrintUsage(const CmdName, UsageStr, DescriptionStr: string);
begin
  Writeln('usage: anvil ', CmdName, ' ', UsageStr);
  if DescriptionStr <> '' then
  begin
    Writeln;
    Writeln('  ', DescriptionStr);
  end;
end;

end.
