{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Plumbing command: anvil hash-object.
  Computes object ID and optionally creates a blob from a file.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_hash_object;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_cli_common, anvil_utils;

function RunCmdHashObject(const Args: TStringArray): Integer;

implementation

function RunCmdHashObject(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  WriteObj: Boolean;
  TypeStr: string;
  PosArgs: TStringArray;
  FilePath: string;
  Data: TByteArray;
  Blob: TBlobObject;
  CalculatedId: TObjectId;
  HasRepo: Boolean;
begin
  Result := 1;
  WriteObj := HasFlag(Args, '-w', '');
  if not GetOptionValue(Args, '-t', '', TypeStr) then
    TypeStr := 'blob';

  PosArgs := GetPositionalArgs(Args);

  if Length(PosArgs) = 0 then
  begin
    PrintUsage('hash-object', '[-t <type>] [-w] <file>', 'Compute object ID and optionally creates an object from a file');
    Exit;
  end;

  FilePath := PosArgs[0];
  if not FileExists(FilePath) then
  begin
    PrintError('fatal: Cannot open ' + FilePath + ': No such file or directory');
    Exit;
  end;

  Data := ReadEntireFile(FilePath);
  if Length(Data) > 0 then
    Blob := TBlobObject.CreateWithData(@Data[0], Length(Data))
  else
    Blob := TBlobObject.CreateWithData(nil, 0);

  try
    CalculatedId := Blob.ObjectId;
    Writeln(ObjectIdToHex(CalculatedId));

    if WriteObj then
    begin
      HasRepo := OpenRepoContext(Ctx, False);
      if not HasRepo then
      begin
        PrintError('fatal: not an anvil repository (or any of the parent directories): .anvil');
        Exit;
      end;
      try
        Ctx.ODB.WriteObject(Blob);
      finally
        CloseRepoContext(Ctx);
      end;
    end;

    Result := 0;
  finally
    Blob.Free;
  end;
end;

end.
