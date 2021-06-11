{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Plumbing command: anvil write-tree.
  Creates a tree object from the current staging index.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_write_tree;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_odb, anvil_index,
  anvil_cli_common;

function RunCmdWriteTree(const Args: TStringArray): Integer;

implementation

function RunCmdWriteTree(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  TreeId: TObjectId;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    if Ctx.Index.HasConflicts then
    begin
      PrintError('fatal: cannot write-tree: there are unmerged index entries');
      Exit;
    end;

    TreeId := Ctx.Index.WriteTree(Ctx.ODB);
    Writeln(ObjectIdToHex(TreeId));
    Result := 0;
  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
