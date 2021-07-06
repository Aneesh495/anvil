{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Porcelain command: anvil rebase.
  Reapply commits on top of another base tip.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_cmd_rebase;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DateUtils,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_ref, anvil_reflog, anvil_index, anvil_rebase, anvil_checkout,
  anvil_cli_common;

function RunCmdRebase(const Args: TStringArray): Integer;

implementation

function RunCmdRebase(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  PosArgs: TStringArray;
  UpstreamName: string;
  UpstreamId, HeadId: TObjectId;
  HeadRef: TReference;
  CurrentBranch: string;
  RebaseEngine: TRebaseEngine;
  Identity: TIdentity;
  RebaseRes: TRebaseResult;
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
      PrintUsage('rebase', '<upstream>', 'Reapply commits on top of another base tip');
      Exit;
    end;

    UpstreamName := PosArgs[0];
    if not ResolveRevision(Ctx, UpstreamName, UpstreamId) then
    begin
      PrintError('fatal: invalid upstream: ' + UpstreamName);
      Exit;
    end;

    if not Ctx.RefMgr.Resolve('HEAD', HeadId) then
    begin
      PrintError('fatal: nothing to rebase: current HEAD has no commits');
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
      RebaseRes := RebaseEngine.RebaseBranch(UpstreamId, HeadId);
      Ctx.Index.WriteToFile;

      if RebaseRes.HasConflict then
      begin
        Writeln('CONFLICT: Could not apply commit ', Copy(ObjectIdToHex(RebaseRes.FailedCommitId), 1, 7));
        for I := 0 to Length(RebaseRes.ConflictedPaths) - 1 do
          Writeln('  ', RebaseRes.ConflictedPaths[I]);
        PrintError('error: could not apply rebase; resolve conflicts and run anvil rebase --continue');
        Exit;
      end;

      if not RebaseRes.Success then
      begin
        PrintError('error: ' + RebaseRes.ErrorMessage);
        Exit;
      end;

      { Checkout new rebased tip }
      CheckoutMgr := TCheckoutManager.Create(Ctx.RepoRoot, Ctx.GitDir, Ctx.ODB, Ctx.Index, Ctx.RefMgr);
      try
        CheckOptions.Force := True;
        CheckOptions.BranchName := '';
        CheckoutMgr.CheckoutCommit(RebaseRes.NewTipCommitId, CheckOptions);
      finally
        CheckoutMgr.Free;
      end;

      Ctx.RefMgr.SetReference(CurrentBranch, RebaseRes.NewTipCommitId);

      ReflogMgr := TReflogManager.Create(Ctx.GitDir, Ctx.Algo);
      try
        ReflogMgr.Append(CurrentBranch, HeadId, RebaseRes.NewTipCommitId, Identity,
          'rebase: fast-forward onto ' + UpstreamName);
      finally
        ReflogMgr.Free;
      end;

      Writeln(Format('Successfully rebased and updated %s (replayed %d commits).',
        [CurrentBranch, RebaseRes.ReplayedCount]));
      Result := 0;

    finally
      RebaseEngine.Free;
    end;

  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
