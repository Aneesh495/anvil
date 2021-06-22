{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Porcelain command: anvil status.
  Displays paths that have differences between the index file and the current HEAD commit,
  paths that have differences between the working tree and the index file,
  and paths in the working tree that are not tracked.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_cmd_status;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_ref, anvil_worktree, anvil_cli_common;

function RunCmdStatus(const Args: TStringArray): Integer;

implementation

function RunCmdStatus(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  HeadRef: TReference;
  HeadCommitId, HeadTreeId: TObjectId;
  ObjType: TObjectType;
  RawData: TByteArray;
  CommitObj: TCommitObject;
  Scanner: TWorktreeScanner;
  Status: TWorktreeStatus;
  IsShort: Boolean;
  BranchName: string;
  I: Integer;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    IsShort := HasFlag(Args, '-s', '--short');

    { Determine active branch name }
    HeadRef := Ctx.RefMgr.GetReference('HEAD');
    if HeadRef = nil then
      BranchName := 'detached'
    else if HeadRef.RefType = rtSymbolic then
    begin
      BranchName := HeadRef.SymbolicTarget;
      if Copy(BranchName, 1, 11) = 'refs/heads/' then
        BranchName := Copy(BranchName, 12, Length(BranchName) - 11);
    end
    else
      BranchName := 'detached at ' + Copy(ObjectIdToHex(HeadRef.TargetId), 1, 7);

    { Resolve HEAD tree }
    HeadTreeId := NullObjectId(Ctx.Algo);
    if Ctx.RefMgr.Resolve('HEAD', HeadCommitId) then
    begin
      if Ctx.ODB.ReadObjectRaw(HeadCommitId, ObjType, RawData) and (ObjType = otCommit) then
      begin
        CommitObj := TCommitObject.Create;
        try
          CommitObj.Deserialize(@RawData[0], Length(RawData));
          HeadTreeId := CommitObj.TreeId;
        finally
          CommitObj.Free;
        end;
      end;
    end;

    Scanner := TWorktreeScanner.Create(Ctx.RepoRoot, Ctx.GitDir, Ctx.ODB, Ctx.Index);
    try
      Status := Scanner.ComputeStatus(HeadTreeId);

      if IsShort then
      begin
        for I := 0 to Length(Status.ConflictedFiles) - 1 do
          Writeln('UU ', Status.ConflictedFiles[I]);
        for I := 0 to Length(Status.StagedNew) - 1 do
          Writeln('A  ', Status.StagedNew[I]);
        for I := 0 to Length(Status.StagedModified) - 1 do
          Writeln('M  ', Status.StagedModified[I]);
        for I := 0 to Length(Status.StagedDeleted) - 1 do
          Writeln('D  ', Status.StagedDeleted[I]);
        for I := 0 to Length(Status.UnstagedModified) - 1 do
          Writeln(' M ', Status.UnstagedModified[I]);
        for I := 0 to Length(Status.UnstagedDeleted) - 1 do
          Writeln(' D ', Status.UnstagedDeleted[I]);
        for I := 0 to Length(Status.Untracked) - 1 do
          Writeln('?? ', Status.Untracked[I]);
      end
      else
      begin
        Writeln('On branch ', BranchName);
        if IsNullObjectId(HeadTreeId) then
          Writeln(#10'No commits yet'#10);

        if Status.HasConflicts then
        begin
          Writeln(#10'Unmerged paths:');
          Writeln('  (use "anvil add <file>..." to mark resolution)'#10);
          for I := 0 to Length(Status.ConflictedFiles) - 1 do
            Writeln('	both modified:   ', Status.ConflictedFiles[I]);
        end;

        if (Length(Status.StagedNew) > 0) or
           (Length(Status.StagedModified) > 0) or
           (Length(Status.StagedDeleted) > 0) then
        begin
          Writeln(#10'Changes to be committed:');
          Writeln('  (use "anvil restore --staged <file>..." to unstage)'#10);
          for I := 0 to Length(Status.StagedNew) - 1 do
            Writeln('	new file:   ', Status.StagedNew[I]);
          for I := 0 to Length(Status.StagedModified) - 1 do
            Writeln('	modified:   ', Status.StagedModified[I]);
          for I := 0 to Length(Status.StagedDeleted) - 1 do
            Writeln('	deleted:    ', Status.StagedDeleted[I]);
        end;

        if (Length(Status.UnstagedModified) > 0) or
           (Length(Status.UnstagedDeleted) > 0) then
        begin
          Writeln(#10'Changes not staged for commit:');
          Writeln('  (use "anvil add <file>..." to update what will be committed)'#10);
          for I := 0 to Length(Status.UnstagedModified) - 1 do
            Writeln('	modified:   ', Status.UnstagedModified[I]);
          for I := 0 to Length(Status.UnstagedDeleted) - 1 do
            Writeln('	deleted:    ', Status.UnstagedDeleted[I]);
        end;

        if Length(Status.Untracked) > 0 then
        begin
          Writeln(#10'Untracked files:');
          Writeln('  (use "anvil add <file>..." to include in what will be committed)'#10);
          for I := 0 to Length(Status.Untracked) - 1 do
            Writeln('	', Status.Untracked[I]);
        end;

        if Status.IsClean then
        begin
          if not IsNullObjectId(HeadTreeId) then
            Writeln('nothing to commit, working tree clean');
        end;
      end;

      Result := 0;
    finally
      Scanner.Free;
    end;

  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
