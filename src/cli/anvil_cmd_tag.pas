{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Porcelain command: anvil tag.
  Create, list, or delete a tag object.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_cmd_tag;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_ref, anvil_cli_common;

function RunCmdTag(const Args: TStringArray): Integer;

implementation

function RunCmdTag(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  IsDelete: Boolean;
  PosArgs: TStringArray;
  TagName, FullRef, TargetRev: string;
  TargetId, ExistingId: TObjectId;
  TagList: TStringArray;
  I: Integer;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    IsDelete := HasFlag(Args, '-d', '--delete');
    PosArgs := GetPositionalArgs(Args);

    if IsDelete then
    begin
      if Length(PosArgs) = 0 then
      begin
        PrintError('fatal: tag name required');
        Exit;
      end;
      TagName := PosArgs[0];
      FullRef := 'refs/tags/' + TagName;
      if not Ctx.RefMgr.Resolve(FullRef, TargetId) then
      begin
        PrintError('error: tag ''' + TagName + ''' not found.');
        Exit;
      end;
      Ctx.RefMgr.DeleteReference(FullRef);
      Writeln('Deleted tag ''' + TagName + ''' (was ', Copy(ObjectIdToHex(TargetId), 1, 7), ')');
      Result := 0;
      Exit;
    end;

    if Length(PosArgs) > 0 then
    begin
      TagName := PosArgs[0];
      if Length(PosArgs) > 1 then
        TargetRev := PosArgs[1]
      else
        TargetRev := 'HEAD';

      if not ResolveRevision(Ctx, TargetRev, TargetId) then
      begin
        PrintError('fatal: Failed to resolve ''' + TargetRev + ''' as a valid revision.');
        Exit;
      end;

      FullRef := 'refs/tags/' + TagName;
      if Ctx.RefMgr.Resolve(FullRef, ExistingId) then
      begin
        PrintError('fatal: tag ''' + TagName + ''' already exists');
        Exit;
      end;

      Ctx.RefMgr.SetReference(FullRef, TargetId);
      Result := 0;
      Exit;
    end;

    { List all tags }
    TagList := Ctx.RefMgr.ListReferences('refs/tags/');
    for I := 0 to Length(TagList) - 1 do
    begin
      TagName := TagList[I];
      if Copy(TagName, 1, 10) = 'refs/tags/' then
        TagName := Copy(TagName, 11, Length(TagName) - 10);
      Writeln(TagName);
    end;

    Result := 0;

  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
