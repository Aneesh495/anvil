{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Plumbing command: anvil fsck.
  Verifies the connectivity and validity of the objects in the database.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_fsck;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_ref, anvil_cli_common, anvil_utils;

function RunCmdFsck(const Args: TStringArray): Integer;

implementation

function RunCmdFsck(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  AllIds: TObjectIdArray;
  I, J: Integer;
  Id: TObjectId;
  ObjType: TObjectType;
  RawData: TByteArray;
  TreeObj: TTreeObject;
  CommitObj: TCommitObject;
  Entry: TTreeEntry;
  ErrorsFound: Integer;
  RefList: TStringArray;
  RefId: TObjectId;
  RefName: string;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    ErrorsFound := 0;
    Writeln('Checking object directories: 100%');

    AllIds := Ctx.ODB.EnumerateAllObjects;
    for I := 0 to Length(AllIds) - 1 do
    begin
      Id := AllIds[I];
      if not Ctx.ODB.ReadObjectRaw(Id, ObjType, RawData) then
      begin
        PrintError('error: missing or unreadable object: ' + ObjectIdToHex(Id));
        Inc(ErrorsFound);
        Continue;
      end;

      case ObjType of
        otTree:
        begin
          TreeObj := TTreeObject.Create;
          try
            try
              TreeObj.Deserialize(@RawData[0], Length(RawData), Ctx.Algo);
              for J := 0 to TreeObj.Count - 1 do
              begin
                Entry := TreeObj.GetEntry(J);
                if not Ctx.ODB.Exists(Entry.Id) then
                begin
                  PrintError(Format('broken link from tree %s to %s',
                    [ObjectIdToHex(Id), ObjectIdToHex(Entry.Id)]));
                  Inc(ErrorsFound);
                end;
              end;
            except
              on E: Exception do
              begin
                PrintError(Format('error in tree %s: %s', [ObjectIdToHex(Id), E.Message]));
                Inc(ErrorsFound);
              end;
            end;
          finally
            TreeObj.Free;
          end;
        end;

        otCommit:
        begin
          CommitObj := TCommitObject.Create;
          try
            try
              CommitObj.Deserialize(@RawData[0], Length(RawData));
              if not Ctx.ODB.Exists(CommitObj.TreeId) then
              begin
                PrintError(Format('broken link from commit %s to tree %s',
                  [ObjectIdToHex(Id), ObjectIdToHex(CommitObj.TreeId)]));
                Inc(ErrorsFound);
              end;
              for J := 0 to Length(CommitObj.ParentIds) - 1 do
              begin
                if not Ctx.ODB.Exists(CommitObj.ParentIds[J]) then
                begin
                  PrintError(Format('broken link from commit %s to parent %s',
                    [ObjectIdToHex(Id), ObjectIdToHex(CommitObj.ParentIds[J])]));
                  Inc(ErrorsFound);
                end;
              end;
            except
              on E: Exception do
              begin
                PrintError(Format('error in commit %s: %s', [ObjectIdToHex(Id), E.Message]));
                Inc(ErrorsFound);
              end;
            end;
          finally
            CommitObj.Free;
          end;
        end;
      end;
    end;

    { Check references }
    RefList := Ctx.RefMgr.ListReferences('');
    for I := 0 to Length(RefList) - 1 do
    begin
      RefName := RefList[I];
      if Ctx.RefMgr.Resolve(RefName, RefId) then
      begin
        if not Ctx.ODB.Exists(RefId) then
        begin
          PrintError(Format('dangling reference %s points to missing object %s',
            [RefName, ObjectIdToHex(RefId)]));
          Inc(ErrorsFound);
        end;
      end;
    end;

    if ErrorsFound = 0 then
    begin
      Writeln('Verification complete: repository is clean with zero errors.');
      Result := 0;
    end
    else
    begin
      PrintError(Format('Verification failed: %d errors identified.', [ErrorsFound]));
      Result := 1;
    end;

  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
