{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Porcelain command: anvil checkout.
  Switch branches or restore working tree files.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_cmd_checkout;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_ref, anvil_checkout,
  anvil_cli_common;

function RunCmdCheckout(const Args: TStringArray): Integer;

implementation

function RunCmdCheckout(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  NewBranch: string;
  PosArgs: TStringArray;
  TargetName: string;
  TargetCommitId, ExistingId: TObjectId;
  CheckoutMgr: TCheckoutManager;
  Options: TCheckoutOptions;
  CheckRes: TCheckoutResult;
  IsBranch: Boolean;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    GetOptionValue(Args, '-b', '', NewBranch);
    PosArgs := GetPositionalArgs(Args);

    if (NewBranch = '') and (Length(PosArgs) = 0) then
    begin
      PrintUsage('checkout', '[-b <new-branch>] <branch>', 'Switch branches or restore working tree files');
      Exit;
    end;

    if NewBranch <> '' then
    begin
      { Create new branch pointing to current HEAD or specified commit }
      if Length(PosArgs) > 0 then
        TargetName := PosArgs[0]
      else
        TargetName := 'HEAD';

      if not ResolveRevision(Ctx, TargetName, TargetCommitId) then
      begin
        PrintError('fatal: Cannot do -b with invalid revision: ' + TargetName);
        Exit;
      end;

      if Ctx.RefMgr.Resolve('refs/heads/' + NewBranch, ExistingId) then
      begin
        PrintError('fatal: A branch named ''' + NewBranch + ''' already exists.');
        Exit;
      end;

      Ctx.RefMgr.SetReference('refs/heads/' + NewBranch, TargetCommitId);
      TargetName := NewBranch;
    end
    else
      TargetName := PosArgs[0];

    { Resolve target branch or revision }
    IsBranch := Ctx.RefMgr.Resolve('refs/heads/' + TargetName, TargetCommitId);
    if not IsBranch then
    begin
      if not ResolveRevision(Ctx, TargetName, TargetCommitId) then
      begin
        PrintError('error: pathspec ''' + TargetName + ''' did not match any file(s) known to anvil');
        Exit;
      end;
    end;

    CheckoutMgr := TCheckoutManager.Create(Ctx.RepoRoot, Ctx.GitDir, Ctx.ODB, Ctx.Index, Ctx.RefMgr);
    try
      Options.Force := HasFlag(Args, '-f', '--force');
      if IsBranch then
        Options.BranchName := TargetName
      else
        Options.BranchName := '';

      CheckRes := CheckoutMgr.CheckoutCommit(TargetCommitId, Options);
      if CheckRes.Success then
      begin
        if IsBranch then
          Writeln('Switched to branch ''' + TargetName + '''')
        else
          Writeln('Note: switching to ''' + TargetName + '''.'#10 +
                  'You are in ''detached HEAD'' state.');
        Result := 0;
      end
      else
      begin
        PrintError('error: ' + CheckRes.ErrorMessage);
        Result := 1;
      end;
    finally
      CheckoutMgr.Free;
    end;

  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
