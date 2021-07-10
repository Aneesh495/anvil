{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Porcelain command: anvil reset.
  Reset current HEAD to the specified state.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_cmd_reset;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_ref, anvil_checkout, anvil_cli_common;

function RunCmdReset(const Args: TStringArray): Integer;

implementation

function RunCmdReset(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  Mode: TResetMode;
  PosArgs: TStringArray;
  TargetRev: string;
  TargetCommitId, TargetTreeId: TObjectId;
  HeadRef: TReference;
  CurrentBranch: string;
  ObjType: TObjectType;
  RawData: TByteArray;
  CommitObj: TCommitObject;
  CheckoutMgr: TCheckoutManager;
  CheckOptions: TCheckoutOptions;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    Mode := rmMixed;
    if HasFlag(Args, '', '--soft') then
      Mode := rmSoft
    else if HasFlag(Args, '', '--hard') then
      Mode := rmHard
    else if HasFlag(Args, '', '--mixed') then
      Mode := rmMixed;

    PosArgs := GetPositionalArgs(Args);
    if Length(PosArgs) > 0 then
      TargetRev := PosArgs[0]
    else
      TargetRev := 'HEAD';

    if not ResolveRevision(Ctx, TargetRev, TargetCommitId) then
    begin
      PrintError('fatal: ambiguous argument ''' + TargetRev + ''': unknown revision');
      Exit;
    end;

    { Extract target tree ID }
    if not Ctx.ODB.ReadObjectRaw(TargetCommitId, ObjType, RawData) or (ObjType <> otCommit) then
    begin
      PrintError('fatal: Could not parse object ''' + TargetRev + '''');
      Exit;
    end;

    CommitObj := TCommitObject.Create;
    try
      CommitObj.Deserialize(@RawData[0], Length(RawData));
      TargetTreeId := CommitObj.TreeId;
    finally
      CommitObj.Free;
    end;

    { Move current branch or HEAD }
    HeadRef := Ctx.RefMgr.GetReference('HEAD');
    if (HeadRef <> nil) and (HeadRef.RefType = rtSymbolic) then
      CurrentBranch := HeadRef.SymbolicTarget
    else
      CurrentBranch := 'HEAD';

    Ctx.RefMgr.SetReference(CurrentBranch, TargetCommitId);

    case Mode of
      rmSoft:
      begin
        { Index and working tree are untouched }
      end;

      rmMixed:
      begin
        { Reset index to target tree }
        Ctx.Index.ReadTree(Ctx.ODB, TargetTreeId);
        Ctx.Index.WriteToFile;
      end;

      rmHard:
      begin
        { Reset index and checkout files to working directory }
        CheckoutMgr := TCheckoutManager.Create(Ctx.RepoRoot, Ctx.GitDir, Ctx.ODB, Ctx.Index, Ctx.RefMgr);
        try
          CheckOptions.Force := True;
          CheckOptions.BranchName := '';
          CheckoutMgr.CheckoutCommit(TargetCommitId, CheckOptions);
        finally
          CheckoutMgr.Free;
        end;
      end;
    end;

    Writeln('HEAD is now at ', Copy(ObjectIdToHex(TargetCommitId), 1, 7));
    Result := 0;

  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
