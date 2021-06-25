{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Porcelain command: anvil commit.
  Record changes to the repository.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_cmd_commit;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DateUtils,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_ref, anvil_reflog, anvil_index, anvil_cli_common, anvil_utils;

function RunCmdCommit(const Args: TStringArray): Integer;

implementation

function RunCmdCommit(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  MsgStr: string;
  IsAmend: Boolean;
  TreeId, HeadCommitId, OldCommitId, NewCommitId: TObjectId;
  HasHead: Boolean;
  HeadRef: TReference;
  CommitObj, OldCommitObj: TCommitObject;
  AuthorName, AuthorEmail: string;
  Identity: TIdentity;
  BranchName: string;
  ReflogMgr: TReflogManager;
  ShortSha: string;
  FirstLineMsg: string;
  RawData: TByteArray;
  ObjType: TObjectType;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    IsAmend := HasFlag(Args, '', '--amend');
    if not GetOptionValue(Args, '-m', '--message', MsgStr) then
    begin
      PrintError('fatal: no commit message specified (use -m <msg>)');
      Exit;
    end;

    if Ctx.Index.HasConflicts then
    begin
      PrintError('fatal: cannot commit: you have unmerged paths');
      Exit;
    end;

    if Ctx.Index.Count = 0 then
    begin
      PrintError('fatal: nothing added to commit but untracked files present');
      Exit;
    end;

    HasHead := Ctx.RefMgr.Resolve('HEAD', HeadCommitId);

    { Write current staging index to a root tree }
    TreeId := Ctx.Index.WriteTree(Ctx.ODB);

    { If not amending and tree is unchanged, check if changes exist }
    if HasHead and not IsAmend then
    begin
      if Ctx.ODB.ReadObjectRaw(HeadCommitId, ObjType, RawData) and (ObjType = otCommit) then
      begin
        OldCommitObj := TCommitObject.Create;
        try
          OldCommitObj.Deserialize(@RawData[0], Length(RawData));
          if ObjectIdEqual(OldCommitObj.TreeId, TreeId) then
          begin
            Writeln('On branch main'#10'nothing to commit, working tree clean');
            Result := 0;
            Exit;
          end;
        finally
          OldCommitObj.Free;
        end;
      end;
    end;

    CommitObj := TCommitObject.Create;
    try
      CommitObj.TreeId := TreeId;

      if IsAmend and HasHead then
      begin
        { Re-use parents from current commit }
        if Ctx.ODB.ReadObjectRaw(HeadCommitId, ObjType, RawData) and (ObjType = otCommit) then
        begin
          OldCommitObj := TCommitObject.Create;
          try
            OldCommitObj.Deserialize(@RawData[0], Length(RawData));
            CommitObj.ParentIds := OldCommitObj.ParentIds;
            OldCommitId := OldCommitObj.ObjectId;
          finally
            OldCommitObj.Free;
          end;
        end;
      end
      else if HasHead then
      begin
        CommitObj.AddParent(HeadCommitId);
        OldCommitId := HeadCommitId;
      end
      else
        OldCommitId := NullObjectId(Ctx.Algo);

      AuthorName := GetEnvironmentVariable('ANVIL_AUTHOR_NAME');
      if AuthorName = '' then AuthorName := 'Aneesh Krishna';
      AuthorEmail := GetEnvironmentVariable('ANVIL_AUTHOR_EMAIL');
      if AuthorEmail = '' then AuthorEmail := 'aneesh@engine.internal';

      Identity := MakeIdentity(AuthorName, AuthorEmail, DateTimeToUnix(Now), 0);
      CommitObj.Author := Identity;
      CommitObj.Committer := Identity;

      if (MsgStr = '') or (MsgStr[Length(MsgStr)] <> #10) then
        MsgStr := MsgStr + #10;
      CommitObj.Message := MsgStr;

      NewCommitId := Ctx.ODB.WriteObject(CommitObj);

      { Update active branch or HEAD }
      HeadRef := Ctx.RefMgr.GetReference('HEAD');
      if (HeadRef <> nil) and (HeadRef.RefType = rtSymbolic) then
      begin
        BranchName := HeadRef.SymbolicTarget;
        Ctx.RefMgr.SetReference(BranchName, NewCommitId);
      end
      else
      begin
        BranchName := 'HEAD';
        Ctx.RefMgr.SetReference('HEAD', NewCommitId);
      end;

      { Record in reflog }
      ReflogMgr := TReflogManager.Create(Ctx.GitDir, Ctx.Algo);
      try
        ReflogMgr.Append(BranchName, OldCommitId, NewCommitId, Identity, 'commit: ' + Copy(MsgStr, 1, Length(MsgStr) - 1));
      finally
        ReflogMgr.Free;
      end;

      ShortSha := Copy(ObjectIdToHex(NewCommitId), 1, 7);
      FirstLineMsg := Copy(MsgStr, 1, Pos(#10, MsgStr) - 1);
      if Copy(BranchName, 1, 11) = 'refs/heads/' then
        BranchName := Copy(BranchName, 12, Length(BranchName) - 11);

      Writeln(Format('[%s %s] %s', [BranchName, ShortSha, FirstLineMsg]));
      if Ctx.Index.Count = 1 then
        Writeln(' 1 file staged')
      else
        Writeln(Format(' %d files staged', [Ctx.Index.Count]));
      Result := 0;

    finally
      CommitObj.Free;
    end;

  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
