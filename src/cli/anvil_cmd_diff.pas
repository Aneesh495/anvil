{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Porcelain command: anvil diff.
  Show changes between commits, commit and working tree, etc.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_cmd_diff;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_index, anvil_index_entry, anvil_diff_tree, anvil_myers, anvil_patch,
  anvil_cli_common, anvil_utils;

function RunCmdDiff(const Args: TStringArray): Integer;

implementation

function RunCmdDiff(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  IsStaged: Boolean;
  PosArgs: TStringArray;
  TreeDiff: TTreeDiff;
  Deltas: TTreeDeltaArray;
  Delta: TTreeDelta;
  OldTreeId, NewTreeId: TObjectId;
  HeadCommitId: TObjectId;
  ObjType: TObjectType;
  RawData: TByteArray;
  CommitObj: TCommitObject;
  OldBlobData, NewBlobData: TByteArray;
  OldText, NewText: string;
  DiffLinesRes: TDiffLineArray;
  PatchGen: TPatchGenerator;
  PatchText: string;
  I: Integer;
  RevA, RevB: string;
  DotDotPos: Integer;
  Entry: TIndexEntry;
  WorktreeFileText: string;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    IsStaged := HasFlag(Args, '', '--staged') or HasFlag(Args, '', '--cached');
    PosArgs := GetPositionalArgs(Args);

    OldTreeId := NullObjectId(Ctx.Algo);
    NewTreeId := NullObjectId(Ctx.Algo);

    if Length(PosArgs) > 0 then
    begin
      { Commit-to-commit range comparison }
      RevA := PosArgs[0];
      DotDotPos := Pos('..', RevA);
      if DotDotPos > 0 then
      begin
        RevB := Copy(RevA, DotDotPos + 2, Length(RevA) - DotDotPos - 1);
        RevA := Copy(RevA, 1, DotDotPos - 1);
      end
      else if Length(PosArgs) > 1 then
        RevB := PosArgs[1]
      else
        RevB := 'HEAD';

      if not ResolveRevision(Ctx, RevA, OldTreeId) or
         not ResolveRevision(Ctx, RevB, NewTreeId) then
      begin
        PrintError('fatal: invalid revision range: ' + PosArgs[0]);
        Exit;
      end;

      { If resolved objects are commits, extract root trees }
      if Ctx.ODB.ReadObjectRaw(OldTreeId, ObjType, RawData) and (ObjType = otCommit) then
      begin
        CommitObj := TCommitObject.Create;
        try
          CommitObj.Deserialize(@RawData[0], Length(RawData));
          OldTreeId := CommitObj.TreeId;
        finally
          CommitObj.Free;
        end;
      end;

      if Ctx.ODB.ReadObjectRaw(NewTreeId, ObjType, RawData) and (ObjType = otCommit) then
      begin
        CommitObj := TCommitObject.Create;
        try
          CommitObj.Deserialize(@RawData[0], Length(RawData));
          NewTreeId := CommitObj.TreeId;
        finally
          CommitObj.Free;
        end;
      end;
    end
    else if IsStaged then
    begin
      { Staged: compare HEAD commit tree vs Index tree }
      if Ctx.RefMgr.Resolve('HEAD', HeadCommitId) then
      begin
        if Ctx.ODB.ReadObjectRaw(HeadCommitId, ObjType, RawData) and (ObjType = otCommit) then
        begin
          CommitObj := TCommitObject.Create;
          try
            CommitObj.Deserialize(@RawData[0], Length(RawData));
            OldTreeId := CommitObj.TreeId;
          finally
            CommitObj.Free;
          end;
        end;
      end;

      NewTreeId := Ctx.Index.WriteTree(Ctx.ODB);
    end
    else
    begin
      { Working tree vs Index comparison }
      PatchGen := TPatchGenerator.Create(3);
      try
        for I := 0 to Ctx.Index.Count - 1 do
        begin
          Entry := Ctx.Index.GetEntry(I);
          if FileExists(JoinPaths(Ctx.RepoRoot, Entry.Path)) then
          begin
            WorktreeFileText := ReadEntireFileString(JoinPaths(Ctx.RepoRoot, Entry.Path));
            if Ctx.ODB.ReadObjectRaw(Entry.Id, ObjType, OldBlobData) then
            begin
              if Length(OldBlobData) > 0 then
                OldText := PChar(@OldBlobData[0])
              else
                OldText := '';
              NewText := WorktreeFileText;

              DiffLinesRes := MyersDiffStrings(OldText, NewText);

              { Check if any modification exists }
              if Length(DiffLinesRes) > 0 then
              begin
                FillChar(Delta, SizeOf(Delta), 0);
                Delta.OldPath := Entry.Path;
                Delta.NewPath := Entry.Path;
                Delta.OldId := Entry.Id;
                Delta.OldMode := Entry.Mode;
                Delta.NewMode := Entry.Mode;
                Delta.Status := dsModified;

                PatchText := PatchGen.FormatFileDiff(Delta, DiffLinesRes);
                Write(PatchText);
              end;
            end;
          end;
        end;
        Result := 0;
      finally
        PatchGen.Free;
      end;
      Exit;
    end;

    { Perform tree diff }
    TreeDiff := TTreeDiff.Create(Ctx.ODB);
    PatchGen := TPatchGenerator.Create(3);
    try
      Deltas := TreeDiff.Diff(OldTreeId, NewTreeId);
      for I := 0 to Length(Deltas) - 1 do
      begin
        Delta := Deltas[I];
        SetLength(OldBlobData, 0);
        SetLength(NewBlobData, 0);

        if not IsNullObjectId(Delta.OldId) then
          Ctx.ODB.ReadObjectRaw(Delta.OldId, ObjType, OldBlobData);
        if not IsNullObjectId(Delta.NewId) then
          Ctx.ODB.ReadObjectRaw(Delta.NewId, ObjType, NewBlobData);

        if Length(OldBlobData) > 0 then
          OldText := PChar(@OldBlobData[0])
        else
          OldText := '';

        if Length(NewBlobData) > 0 then
          NewText := PChar(@NewBlobData[0])
        else
          NewText := '';

        DiffLinesRes := MyersDiffStrings(OldText, NewText);
        PatchText := PatchGen.FormatFileDiff(Delta, DiffLinesRes);
        Write(PatchText);
      end;

      Result := 0;
    finally
      PatchGen.Free;
      TreeDiff.Free;
    end;

  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
