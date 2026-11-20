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
  MaxCount: Integer;
  CommitCount: Integer;
  CommitId: TObjectId;
  Revisions: TStringArray;
  Arg, Revision: string;
  Exclude, CountOnly: Boolean;
  IncludeIds, ExcludeIds: TObjectIdArray;
  TargetId: TObjectId;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    if not ParseCommitLimit(Args, MaxCount) then Exit;
    CountOnly := HasFlag(Args, '', '--count');

    Revisions := GetPositionalArgs(Args);
    Walker := TCommitWalker.Create(Ctx.ODB, csoTopological);
    try
      for Arg in Revisions do
      begin
        if Pos('..', Arg) > 0 then
        begin
          if not ResolveRevisionRange(Ctx, Arg, IncludeIds, ExcludeIds) then
          begin
            PrintError('fatal: invalid revision range: ' + Arg);
            Exit;
          end;
          for CommitId in IncludeIds do Walker.Push(CommitId);
          for CommitId in ExcludeIds do Walker.Hide(CommitId);
        end
        else
        begin
          Exclude := (Length(Arg) > 0) and (Arg[1] = '^');
          if Exclude then
            Revision := Copy(Arg, 2, Length(Arg) - 1)
          else
            Revision := Arg;
          if (Revision = '') or not ResolveRevision(Ctx, Revision, TargetId, True) then
          begin
            PrintError('fatal: invalid revision: ' + Arg);
            Exit;
          end;
          if Exclude then
            Walker.Hide(TargetId)
          else
            Walker.Push(TargetId);
        end;
      end;

      { If no start points were specified, default to HEAD }
      if (Length(Revisions) = 0) and ResolveRevision(Ctx, 'HEAD', TargetId, True) then
        Walker.Push(TargetId);

      CommitCount := 0;
      while (CommitCount < MaxCount) and Walker.Next(CommitId) do
      begin
        if not CountOnly then
          Writeln(ObjectIdToHex(CommitId));
        Inc(CommitCount);
      end;
      if CountOnly then
        Writeln(CommitCount);

      Result := 0;
    finally
      Walker.Free;
    end;
  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
