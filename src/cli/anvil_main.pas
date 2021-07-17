{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Main command-line interface entry point.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

program anvil_main;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes,
  anvil_types, anvil_cli_router;

var
  Args: TStringArray;
  Cmd: string;
  I: Integer;
  ExitCodeVal: Integer;
begin
  if ParamCount = 0 then
  begin
    PrintMainHelp;
    Halt(0);
  end;

  Cmd := ParamStr(1);
  SetLength(Args, ParamCount - 1);
  for I := 2 to ParamCount do
    Args[I - 2] := ParamStr(I);

  try
    ExitCodeVal := DispatchCliCommand(Cmd, Args);
    Halt(ExitCodeVal);
  except
    on E: Exception do
    begin
      Writeln(StdErr, 'fatal: ', E.Message);
      Halt(128);
    end;
  end;
end.
