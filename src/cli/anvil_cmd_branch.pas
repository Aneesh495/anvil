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
  anvil_types, anvil_errors, anvil_hash, anvil_odb, anvil_ref, anvil_lca, anvil_cli_common;

function RunCmdBranch(const Args: TStringArray): Integer;

implementation

function BranchMergedIntoHead(const Ctx: TRepoContext; const BranchId: TObjectId): Boolean;
var
  HeadId, BaseId: TObjectId;
  Finder: TLcaFinder;
begin
  if not Ctx.RefMgr.Resolve('HEAD', HeadId) then
    Exit(False);
  Finder := TLcaFinder.Create(Ctx.ODB);
  try
    Result := Finder.FindBestMergeBase(HeadId, BranchId, BaseId) and ObjectIdEqual(BaseId, BranchId);
  finally
    Finder.Free;
  end;
end;

function RunCmdBranch(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  IsDelete, IsForceDelete, ShowAll: Boolean;
  PosArgs: TStringArray;
  BranchList: TStringArray;
  I: Integer;
  BranchName, FullRef: string;
  HeadRef: TReference;
  CurrentBranch: string;
  TargetId, ExistingId: TObjectId;
  StartRev: string;
  ObjType: TObjectType;
  RawData: TByteArray;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    IsForceDelete := HasFlag(Args, '-D', '');
    IsDelete := IsForceDelete or HasFlag(Args, '-d', '--delete');
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
      if not IsForceDelete and not BranchMergedIntoHead(Ctx, TargetId) then
      begin
        PrintError('error: branch ''' + BranchName + ''' is not fully merged into HEAD. Use -D to force deletion.');
        Exit;
      end;
      if not Ctx.RefMgr.DeleteReference(FullRef) then
      begin
        PrintError('error: failed to delete branch ''' + BranchName + '''.');
        Exit;
      end;
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

      if not ResolveRevision(Ctx, StartRev, TargetId) or
         not Ctx.ODB.ReadObjectRaw(TargetId, ObjType, RawData) or (ObjType <> otCommit) then
      begin
        PrintError('fatal: not a valid commit revision: ' + StartRev);
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
