{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Porcelain command: anvil branch.
  List, create, or delete branches.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_cmd_branch;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_ref, anvil_cli_common;

function RunCmdBranch(const Args: TStringArray): Integer;

implementation

function RunCmdBranch(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  IsDelete, ShowAll: Boolean;
  PosArgs: TStringArray;
  BranchList: TStringArray;
  I: Integer;
  BranchName, FullRef: string;
  HeadRef: TReference;
  CurrentBranch: string;
  TargetId, ExistingId: TObjectId;
  StartRev: string;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    IsDelete := HasFlag(Args, '-d', '-D') or HasFlag(Args, '', '--delete');
    ShowAll := HasFlag(Args, '-a', '--all');
    PosArgs := GetPositionalArgs(Args);

    { Determine active branch }
    HeadRef := Ctx.RefMgr.GetReference('HEAD');
    if (HeadRef <> nil) and (HeadRef.RefType = rtSymbolic) then
    begin
      CurrentBranch := HeadRef.SymbolicTarget;
      if Copy(CurrentBranch, 1, 11) = 'refs/heads/' then
        CurrentBranch := Copy(CurrentBranch, 12, Length(CurrentBranch) - 11);
    end
    else
      CurrentBranch := '';

    { Case 1: Delete branch }
    if IsDelete then
    begin
      if Length(PosArgs) = 0 then
      begin
        PrintError('fatal: branch name required');
        Exit;
      end;
      BranchName := PosArgs[0];
      if BranchName = CurrentBranch then
      begin
        PrintError('fatal: Cannot delete branch ''' + BranchName + ''' checked out');
        Exit;
      end;
      FullRef := 'refs/heads/' + BranchName;
      if not Ctx.RefMgr.Resolve(FullRef, TargetId) then
      begin
        PrintError('error: branch ''' + BranchName + ''' not found.');
        Exit;
      end;
      Ctx.RefMgr.DeleteReference(FullRef);
      Writeln('Deleted branch ', BranchName, ' (was ', Copy(ObjectIdToHex(TargetId), 1, 7), ').');
      Result := 0;
      Exit;
    end;

    { Case 2: Create new branch }
    if Length(PosArgs) > 0 then
    begin
      BranchName := PosArgs[0];
      if Length(PosArgs) > 1 then
        StartRev := PosArgs[1]
      else
        StartRev := 'HEAD';

      if not ResolveRevision(Ctx, StartRev, TargetId) then
      begin
        PrintError('fatal: Not a valid object name: ''' + StartRev + '''.');
        Exit;
      end;

      FullRef := 'refs/heads/' + BranchName;
      if Ctx.RefMgr.Resolve(FullRef, ExistingId) then
      begin
        PrintError('fatal: A branch named ''' + BranchName + ''' already exists.');
        Exit;
      end;

      Ctx.RefMgr.SetReference(FullRef, TargetId);
      Result := 0;
      Exit;
    end;

    { Case 3: List branches }
    BranchList := Ctx.RefMgr.ListReferences('refs/heads/');
    for I := 0 to Length(BranchList) - 1 do
    begin
      BranchName := BranchList[I];
      if Copy(BranchName, 1, 11) = 'refs/heads/' then
        BranchName := Copy(BranchName, 12, Length(BranchName) - 11);

      if BranchName = CurrentBranch then
        Writeln('* ', BranchName)
      else
        Writeln('  ', BranchName);
    end;

    if ShowAll then
    begin
      BranchList := Ctx.RefMgr.ListReferences('refs/remotes/');
      for I := 0 to Length(BranchList) - 1 do
      begin
        BranchName := BranchList[I];
        Writeln('  remotes/', Copy(BranchName, 14, Length(BranchName) - 13));
      end;
    end;

    Result := 0;

  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
