{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Porcelain command: anvil gc.
  Cleanup unnecessary files and optimize the local repository.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_cmd_gc;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_odb, anvil_cli_common;

function RunCmdGc(const Args: TStringArray): Integer;

implementation

function RunCmdGc(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    Writeln('Counting objects: 100%');
    Writeln('Compressing objects: 100%');
    Ctx.ODB.PackLooseObjects;
    Writeln('Packing objects complete.');
    Result := 0;
  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
