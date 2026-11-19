{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Plumbing command: anvil ls-tree.
  Lists the contents of a tree object, with optional recursive traversal.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_ls_tree;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_cli_common;

function RunCmdLsTree(const Args: TStringArray): Integer;

implementation

function ListTreeRecursive(ODB: TObjectDatabase; const TreeId: TObjectId;
                            const Prefix: string; Recursive, DirsOnly: Boolean;
                            Algo: THashAlgorithm): Boolean;
var
  RawData: TByteArray;
  ObjType: TObjectType;
  TreeObj: TTreeObject;
  I: Integer;
  Entry: TTreeEntry;
  Path: string;
begin
  if not ODB.ReadObjectRaw(TreeId, ObjType, RawData) or (ObjType <> otTree) then
  begin
    PrintError('fatal: cannot read tree ' + ObjectIdToHex(TreeId));
    Exit(False);
  end;

  TreeObj := TTreeObject.Create;
  try
    if Length(RawData) > 0 then
      TreeObj.Deserialize(@RawData[0], Length(RawData), Algo);
    for I := 0 to TreeObj.Count - 1 do
    begin
      Entry := TreeObj.GetEntry(I);
      if Prefix = '' then
        Path := Entry.Name
      else
        Path := Prefix + '/' + Entry.Name;

      if Entry.Mode = fmDirectory then
      begin
        if not Recursive or DirsOnly then
          PrintTreeEntry(Entry, Path);

        if Recursive and not ListTreeRecursive(ODB, Entry.Id, Path, Recursive, DirsOnly, Algo) then
          Exit(False);
      end
      else if not DirsOnly then
      begin
        PrintTreeEntry(Entry, Path);
      end;
    end;
  finally
    TreeObj.Free;
  end;
  Result := True;
end;

function RunCmdLsTree(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  Recursive, DirsOnly: Boolean;
  PosArgs: TStringArray;
  TargetRev: string;
  TargetId, TreeId: TObjectId;
  ObjType: TObjectType;
  RawData: TByteArray;
  CommitObj: TCommitObject;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    Recursive := HasFlag(Args, '-r', '--recursive');
    DirsOnly := HasFlag(Args, '-d', '');
    PosArgs := GetPositionalArgs(Args);

    if Length(PosArgs) = 0 then
    begin
      PrintUsage('ls-tree', '[-r] [-d] <tree-ish>', 'List the contents of a tree object');
      Exit;
    end;

    TargetRev := PosArgs[0];
    if not ResolveRevision(Ctx, TargetRev, TargetId) then
    begin
      PrintError('fatal: Not a valid object name: ' + TargetRev);
      Exit;
    end;

    if not Ctx.ODB.ReadObjectRaw(TargetId, ObjType, RawData) or
       not (ObjType in [otTree, otCommit]) then
    begin
      PrintError('fatal: not a tree-ish: ' + TargetRev);
      Exit;
    end;

    TreeId := TargetId;
    if ObjType = otCommit then
    begin
      CommitObj := TCommitObject.Create;
      try
        CommitObj.Deserialize(@RawData[0], Length(RawData));
        TreeId := CommitObj.TreeId;
      finally
        CommitObj.Free;
      end;
    end;

    if ListTreeRecursive(Ctx.ODB, TreeId, '', Recursive, DirsOnly, Ctx.Algo) then
      Result := 0;

  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
