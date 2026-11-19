{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Plumbing command: anvil cat-file.
  Provides content, type, and size inspection for repository objects.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_cat_file;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_cli_common;

function RunCmdCatFile(const Args: TStringArray): Integer;

implementation

uses Math;

{ Write the payload exactly as stored, including embedded zero bytes. }
function WriteRawOutput(const Data: TByteArray): Integer;
const
  ChunkSize = 16 * 1024 * 1024;
var
  Offset: SizeInt;
  Written: LongInt;
begin
  Flush(Output);
  Offset := 0;
  while Offset < Length(Data) do
  begin
    Written := FileWrite(TextRec(Output).Handle, Data[Offset],
      Min(Length(Data) - Offset, SizeInt(ChunkSize)));
    if Written <= 0 then
    begin
      PrintError('fatal: cat-file: could not write object to standard output');
      Exit(1);
    end;
    Inc(Offset, Written);
  end;
  Result := 0;
end;

function RunCmdCatFile(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  ShowType, ShowSize, PrettyPrint, ExistsOnly: Boolean;
  TargetRev: string;
  TargetId: TObjectId;
  RawData: TByteArray;
  ObjType: TObjectType;
  TreeObj: TTreeObject;
  CommitObj: TCommitObject;
  Entry: TTreeEntry;
  I: Integer;
  PosArgs: TStringArray;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    ShowType := HasFlag(Args, '-t', '');
    ShowSize := HasFlag(Args, '-s', '');
    PrettyPrint := HasFlag(Args, '-p', '');
    ExistsOnly := HasFlag(Args, '-e', '');

    { These mode flags do not consume an option value. }
    PosArgs := nil;
    for I := 0 to High(Args) do
      if (Args[I] <> '-t') and (Args[I] <> '-s') and (Args[I] <> '-p') and (Args[I] <> '-e') then
      begin
        SetLength(PosArgs, Length(PosArgs) + 1);
        PosArgs[High(PosArgs)] := Args[I];
      end;
    if Length(PosArgs) = 0 then
    begin
      PrintUsage('cat-file', '[-t | -s | -p | -e] <object>', 'Inspect a repository object');
      Exit;
    end;
    if ExistsOnly and (ShowType or ShowSize or PrettyPrint or (Length(PosArgs) <> 1)) then
    begin
      PrintError('fatal: use cat-file -e with exactly one object and no other mode');
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
      if not ExistsOnly then
        PrintError('fatal: git cat-file ' + TargetRev + ': bad object');
      Exit;
    end;
    if ExistsOnly then
      Exit(0);

    if ShowType then
    begin
      Writeln(ObjectTypeToString(ObjType));
      Result := 0;
      Exit;
    end;

    if ShowSize then
    begin
      Writeln(Length(RawData));
      Result := 0;
      Exit;
    end;

    if PrettyPrint then
    begin
      case ObjType of
        otBlob, otTag:
          Exit(WriteRawOutput(RawData));

        otTree:
        begin
          TreeObj := TTreeObject.Create;
          try
            if Length(RawData) > 0 then
              TreeObj.Deserialize(@RawData[0], Length(RawData), Ctx.Algo);
            for I := 0 to TreeObj.Count - 1 do
            begin
              Entry := TreeObj.GetEntry(I);
              PrintTreeEntry(Entry, Entry.Name);
            end;
          finally
            TreeObj.Free;
          end;
        end;

        otCommit:
        begin
          CommitObj := TCommitObject.Create;
          try
            CommitObj.Deserialize(@RawData[0], Length(RawData));
            Writeln('tree ', ObjectIdToHex(CommitObj.TreeId));
            for I := 0 to Length(CommitObj.ParentIds) - 1 do
              Writeln('parent ', ObjectIdToHex(CommitObj.ParentIds[I]));
            Writeln('author ', FormatIdentity(CommitObj.Author));
            Writeln('committer ', FormatIdentity(CommitObj.Committer));
            Writeln;
            Write(CommitObj.Message);
          finally
            CommitObj.Free;
          end;
        end;

      end;

      Result := 0;
      Exit;
    end;

    Result := WriteRawOutput(RawData);

  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
