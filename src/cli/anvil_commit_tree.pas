{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Plumbing command: anvil commit-tree.
  Creates a new commit object given a tree, parents, and commit message.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_commit_tree;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DateUtils,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_cli_common, anvil_utils;

function RunCmdCommitTree(const Args: TStringArray): Integer;

implementation

function RunCmdCommitTree(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  TreeRev, MsgStr: string;
  TreeId, ParentId, CommitId: TObjectId;
  CommitObj: TCommitObject;
  I: Integer;
  ParentStr: string;
  PosArgs: TStringArray;
  AuthorName, AuthorEmail: string;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    PosArgs := GetPositionalArgs(Args);
    if Length(PosArgs) = 0 then
    begin
      PrintUsage('commit-tree', '<tree> [-p <parent>]... -m <message>', 'Create a new commit object');
      Exit;
    end;

    TreeRev := PosArgs[0];
    if not GetOptionValue(Args, '-m', '', MsgStr) then
    begin
      PrintError('fatal: commit-tree requires a commit message (-m)');
      Exit;
    end;

    if not ResolveRevision(Ctx, TreeRev, TreeId) then
    begin
      PrintError('fatal: not a valid object name: ' + TreeRev);
      Exit;
    end;

    CommitObj := TCommitObject.Create;
    try
      CommitObj.TreeId := TreeId;

      { Extract all -p parent parameters }
      I := 0;
      while I < Length(Args) do
      begin
        if (Args[I] = '-p') and (I + 1 < Length(Args)) then
        begin
          ParentStr := Args[I + 1];
          if ResolveRevision(Ctx, ParentStr, ParentId) then
            CommitObj.AddParent(ParentId)
          else
          begin
            PrintError('fatal: bad parent: ' + ParentStr);
            Exit;
          end;
          Inc(I, 2);
          Continue;
        end;
        Inc(I);
      end;

      AuthorName := GetEnvironmentVariable('ANVIL_AUTHOR_NAME');
      if AuthorName = '' then AuthorName := 'Aneesh Krishna';
      AuthorEmail := GetEnvironmentVariable('ANVIL_AUTHOR_EMAIL');
      if AuthorEmail = '' then AuthorEmail := 'aneesh@engine.internal';

      CommitObj.Author := MakeIdentity(AuthorName, AuthorEmail, DateTimeToUnix(Now), 0);
      CommitObj.Committer := CommitObj.Author;
      if (MsgStr = '') or (MsgStr[Length(MsgStr)] <> #10) then
        MsgStr := MsgStr + #10;
      CommitObj.Message := MsgStr;

      CommitId := Ctx.ODB.WriteObject(CommitObj);
      Writeln(ObjectIdToHex(CommitId));
      Result := 0;

    finally
      CommitObj.Free;
    end;

  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
