{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Plumbing command: anvil rev-list.
  Lists commit objects in reverse chronological or topological order.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_rev_list;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_odb, anvil_ref,
  anvil_dag, anvil_cli_common;

function RunCmdRevList(const Args: TStringArray): Integer;

implementation

function RunCmdRevList(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  Walker: TCommitWalker;
  CountStr: string;
  MaxCount: Integer;
  EmittedCount: Integer;
  CommitId: TObjectId;
  I: Integer;
  Arg: string;
  IncludeIds, ExcludeIds: TObjectIdArray;
  TargetId: TObjectId;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    MaxCount := MaxInt;
    if GetOptionValue(Args, '-n', '--max-count', CountStr) then
      MaxCount := StrToIntDef(CountStr, MaxInt);

    Walker := TCommitWalker.Create(Ctx.ODB, csoTopological);
    try
      for I := 0 to Length(Args) - 1 do
      begin
        Arg := Args[I];
        if (Length(Arg) > 0) and (Arg[1] = '-') then Continue;

        if Pos('..', Arg) > 0 then
        begin
          if ResolveRevisionRange(Ctx, Arg, IncludeIds, ExcludeIds) then
          begin
            for CommitId in IncludeIds do Walker.Push(CommitId);
            for CommitId in ExcludeIds do Walker.Hide(CommitId);
          end;
        end
        else
        begin
          if ResolveRevision(Ctx, Arg, TargetId) then
            Walker.Push(TargetId);
        end;
      end;

      { If no start points were specified, default to HEAD }
      if ResolveRevision(Ctx, 'HEAD', TargetId) then
        Walker.Push(TargetId);

      EmittedCount := 0;
      while (EmittedCount < MaxCount) and Walker.Next(CommitId) do
      begin
        Writeln(ObjectIdToHex(CommitId));
        Inc(EmittedCount);
      end;

      Result := 0;
    finally
      Walker.Free;
    end;
  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
