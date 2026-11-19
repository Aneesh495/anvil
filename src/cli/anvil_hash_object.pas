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
  WriteObj, ParseOptions: Boolean;
  Arg, TypeStr, FilePath: string;
  I: Integer;
  Data: TByteArray;
  Blob: TBlobObject;
  CalculatedId: TObjectId;
  HasRepo: Boolean;
begin
  Result := 1;
  WriteObj := False;
  ParseOptions := True;
  TypeStr := 'blob';
  FilePath := '';
  I := 0;
  while I < Length(Args) do
  begin
    Arg := Args[I];
    Inc(I);
    if ParseOptions then
      case Arg of
        '-w':
        begin
          WriteObj := True;
          Continue;
        end;
        '-t':
        begin
          if I = Length(Args) then
          begin
            PrintError('fatal: -t requires an object type');
            Exit;
          end;
          TypeStr := Args[I];
          Inc(I);
          Continue;
        end;
        '--':
        begin
          ParseOptions := False;
          Continue;
        end;
      else
        if (Length(Arg) > 1) and (Arg[1] = '-') then
        begin
          PrintError('fatal: unknown hash-object option: ' + Arg);
          Exit;
        end;
      end;
    if FilePath <> '' then
    begin
      PrintError('fatal: hash-object requires exactly one file');
      Exit;
    end;
    FilePath := Arg;
  end;
  if TypeStr <> 'blob' then
  begin
    PrintError('fatal: hash-object supports only the blob type');
    Exit;
  end;

  if FilePath = '' then
  begin
    PrintUsage('hash-object', '[-t blob] [-w] [--] <file>', 'Compute an object ID and optionally store the file');
    Exit;
  end;

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

    Writeln(ObjectIdToHex(CalculatedId));
    Result := 0;
  finally
    Blob.Free;
  end;
end;

end.
