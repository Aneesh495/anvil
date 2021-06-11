{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Plumbing command: anvil read-tree.
  Reads tree information into the staging index.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_read_tree;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb, anvil_index,
  anvil_cli_common;

function RunCmdReadTree(const Args: TStringArray): Integer;

implementation

function RunCmdReadTree(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
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
    PosArgs := GetPositionalArgs(Args);
    if Length(PosArgs) = 0 then
    begin
      PrintUsage('read-tree', '<tree-ish>', 'Reads tree information into the index');
      Exit;
    end;

    TargetRev := PosArgs[0];
    if not ResolveRevision(Ctx, TargetRev, TargetId) then
    begin
      PrintError('fatal: Not a valid object name: ' + TargetRev);
      Exit;
    end;

    if not Ctx.ODB.ReadObjectRaw(TargetId, ObjType, RawData) then
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

    Ctx.Index.ReadTree(Ctx.ODB, TreeId);
    Ctx.Index.WriteToFile;
    Result := 0;

  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
