{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Porcelain command: anvil cherry-pick.
  Apply the changes introduced by some existing commits.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_cmd_cherry_pick;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DateUtils,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_ref, anvil_reflog, anvil_index, anvil_rebase, anvil_checkout,
  anvil_cli_common;

function RunCmdCherryPick(const Args: TStringArray): Integer;

implementation

function RunCmdCherryPick(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  PosArgs: TStringArray;
  CommitRev: string;
  SourceCommitId, HeadId: TObjectId;
  HeadRef: TReference;
  CurrentBranch: string;
  RebaseEngine: TRebaseEngine;
  Identity: TIdentity;
  PickRes: TCherryPickResult;
  CheckoutMgr: TCheckoutManager;
  CheckOptions: TCheckoutOptions;
  ReflogMgr: TReflogManager;
  I: Integer;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    PosArgs := GetPositionalArgs(Args);
    if Length(PosArgs) = 0 then
    begin
      PrintUsage('cherry-pick', '<commit>', 'Apply the changes introduced by some existing commits');
      Exit;
    end;

    CommitRev := PosArgs[0];
    if not ResolveRevision(Ctx, CommitRev, SourceCommitId) then
    begin
      PrintError('fatal: bad revision ''' + CommitRev + '''');
      Exit;
    end;

    if not Ctx.RefMgr.Resolve('HEAD', HeadId) then
    begin
      PrintError('fatal: nothing to cherry-pick onto: current HEAD has no commits');
      Exit;
    end;

    HeadRef := Ctx.RefMgr.GetReference('HEAD');
    if (HeadRef <> nil) and (HeadRef.RefType = rtSymbolic) then
      CurrentBranch := HeadRef.SymbolicTarget
    else
      CurrentBranch := 'HEAD';

    Identity := MakeIdentity('Aneesh Krishna', 'aneesh@engine.internal', DateTimeToUnix(Now), 0);
    RebaseEngine := TRebaseEngine.Create(Ctx.ODB, Ctx.Index, Identity);
    try
      PickRes := RebaseEngine.CherryPick(SourceCommitId, HeadId);
      Ctx.Index.WriteToFile;

      if PickRes.HasConflict then
      begin
        Writeln('CONFLICT: Could not apply commit ', Copy(ObjectIdToHex(SourceCommitId), 1, 7));
        for I := 0 to Length(PickRes.ConflictedPaths) - 1 do
          Writeln('  ', PickRes.ConflictedPaths[I]);
        PrintError('error: could not apply cherry-pick; resolve conflicts and commit the result');
        Exit;
      end;

      if not PickRes.Success then
      begin
        PrintError('error: ' + PickRes.ErrorMessage);
        Exit;
      end;

      { Checkout new commit tree }
      CheckoutMgr := TCheckoutManager.Create(Ctx.RepoRoot, Ctx.GitDir, Ctx.ODB, Ctx.Index, Ctx.RefMgr);
      try
        CheckOptions.Force := True;
        CheckOptions.BranchName := '';
        CheckoutMgr.CheckoutCommit(PickRes.NewCommitId, CheckOptions);
      finally
        CheckoutMgr.Free;
      end;

      Ctx.RefMgr.SetReference(CurrentBranch, PickRes.NewCommitId);

      ReflogMgr := TReflogManager.Create(Ctx.GitDir, Ctx.Algo);
      try
        ReflogMgr.Append(CurrentBranch, HeadId, PickRes.NewCommitId, Identity,
          'cherry-pick: ' + Copy(ObjectIdToHex(SourceCommitId), 1, 7));
      finally
        ReflogMgr.Free;
      end;

      Writeln(Format('[%s %s] Cherry-picked commit %s',
        [CurrentBranch, Copy(ObjectIdToHex(PickRes.NewCommitId), 1, 7),
         Copy(ObjectIdToHex(SourceCommitId), 1, 7)]));
      Result := 0;

    finally
      RebaseEngine.Free;
    end;

  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
