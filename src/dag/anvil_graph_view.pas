{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Terminal ASCII branch graph renderer.
  Constructs multi-column branch lane topologies with visual fork and merge
  connectors (*, |, /, \), reference decorators, and commit metadata.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_graph_view;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DateUtils,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_ref, anvil_dag, anvil_utils;

type
  { Single graph line item }
  TGraphLine = record
    CommitId: TObjectId;
    Glyphs: string;
    Decorations: string;
    Message: string;
    Author: string;
    CommitDate: string;
  end;
  TGraphLineArray = array of TGraphLine;

  { ASCII graph visualizer }
  TGraphRenderer = class
  private
    FODB: TObjectDatabase;
    FRefMgr: TRefManager;
    FUseAnsiColors: Boolean;

    function FormatDecorations(const CommitId: TObjectId): string;
  public
    constructor Create(AODB: TObjectDatabase; ARefMgr: TRefManager = nil; UseAnsiColors: Boolean = False);

    { Render DAG from a list of commits }
    function RenderGraph(const CommitIds: TObjectIdArray): TGraphLineArray;

    { Render complete history starting from tip }
    function RenderHistory(const StartCommitId: TObjectId; MaxCommits: Integer = 50): TGraphLineArray;

    { Format lines into complete printable string }
    function FormatGraphString(const Lines: TGraphLineArray): string;
  end;

implementation

constructor TGraphRenderer.Create(AODB: TObjectDatabase; ARefMgr: TRefManager; UseAnsiColors: Boolean);
begin
  inherited Create;
  FODB := AODB;
  FRefMgr := ARefMgr;
  FUseAnsiColors := UseAnsiColors;
end;

function TGraphRenderer.FormatDecorations(const CommitId: TObjectId): string;
var
  Refs: TStringArray;
  I: Integer;
  ResolvedId: TObjectId;
  Matched: TStringArray;
  RefName, ShortName: string;
  HeadTarget: string;
  HeadRef: TReference;
begin
  Result := '';
  if not Assigned(FRefMgr) then Exit;

  Refs := FRefMgr.ListReferences('');
  SetLength(Matched, 0);

  { Check HEAD }
  HeadRef := FRefMgr.GetReference('HEAD');
  if Assigned(HeadRef) then
  begin
    try
      if (HeadRef.RefType = rtDirect) and ObjectIdEqual(HeadRef.TargetId, CommitId) then
      begin
        SetLength(Matched, Length(Matched) + 1);
        Matched[Length(Matched) - 1] := 'HEAD';
      end
      else if (HeadRef.RefType = rtSymbolic) and FRefMgr.Resolve('HEAD', ResolvedId) and ObjectIdEqual(ResolvedId, CommitId) then
      begin
        HeadTarget := HeadRef.SymbolicTarget;
        if Copy(HeadTarget, 1, 11) = 'refs/heads/' then
          HeadTarget := Copy(HeadTarget, 12, Length(HeadTarget) - 11);
        SetLength(Matched, Length(Matched) + 1);
        Matched[Length(Matched) - 1] := 'HEAD -> ' + HeadTarget;
      end;
    finally
      HeadRef.Free;
    end;
  end;

  { Check other refs }
  for I := 0 to Length(Refs) - 1 do
  begin
    RefName := Refs[I];
    if RefName = 'HEAD' then Continue;

    if FRefMgr.Resolve(RefName, ResolvedId) and ObjectIdEqual(ResolvedId, CommitId) then
    begin
      ShortName := RefName;
      if Copy(ShortName, 1, 11) = 'refs/heads/' then
        ShortName := Copy(ShortName, 12, Length(ShortName) - 11)
      else if Copy(ShortName, 1, 10) = 'refs/tags/' then
        ShortName := 'tag: ' + Copy(ShortName, 11, Length(ShortName) - 10);

      { Avoid duplicate if HEAD was already displayed as HEAD -> branch }
      if (Length(Matched) > 0) and (Matched[0] = 'HEAD -> ' + ShortName) then
        Continue;

      SetLength(Matched, Length(Matched) + 1);
      Matched[Length(Matched) - 1] := ShortName;
    end;
  end;

  if Length(Matched) > 0 then
    Result := '(' + string.Join(', ', Matched) + ')';
end;

function TGraphRenderer.RenderGraph(const CommitIds: TObjectIdArray): TGraphLineArray;
type
  TColumnArray = array of TObjectId;
var
  Columns: TColumnArray;
  I, J, ColIdx: Integer;
  CommitId: TObjectId;
  Obj: TAnvilObject;
  Commit: TCommitObject;
  Line: TGraphLine;
  GlyphStr: string;
  Parents: TObjectIdArray;
  P1, P2: TObjectId;
  P1Col, P2Col: Integer;
begin
  SetLength(Result, Length(CommitIds));
  SetLength(Columns, 0);

  for I := 0 to Length(CommitIds) - 1 do
  begin
    CommitId := CommitIds[I];
    Obj := FODB.ReadObject(CommitId);
    if not Assigned(Obj) or not (Obj is TCommitObject) then
    begin
      if Assigned(Obj) then Obj.Free;
      Continue;
    end;

    Commit := TCommitObject(Obj);
    try
      Parents := Commit.ParentIds;

      { Find which column this commit belongs to }
      ColIdx := -1;
      for J := 0 to Length(Columns) - 1 do
      begin
        if ObjectIdEqual(Columns[J], CommitId) then
        begin
          ColIdx := J;
          Break;
        end;
      end;

      if ColIdx = -1 then
      begin
        { Assign next available column }
        ColIdx := Length(Columns);
        SetLength(Columns, ColIdx + 1);
        Columns[ColIdx] := CommitId;
      end;

      { Construct visual glyph prefix for this row }
      GlyphStr := '';
      for J := 0 to Length(Columns) - 1 do
      begin
        if J = ColIdx then
          GlyphStr := GlyphStr + '* '
        else if not IsNullObjectId(Columns[J]) then
          GlyphStr := GlyphStr + '| '
        else
          GlyphStr := GlyphStr + '  ';
      end;

      { Update column tracking for next row }
      if Length(Parents) = 0 then
      begin
        { Root commit: column ends }
        Columns[ColIdx] := NullObjectId;
      end
      else if Length(Parents) = 1 then
      begin
        { Linear continuation: replace commit with first parent }
        Columns[ColIdx] := Parents[0];
      end
      else
      begin
        { Merge commit: assign first parent to current column, second to next }
        Columns[ColIdx] := Parents[0];
        P2 := Parents[1];
        P2Col := -1;
        for J := 0 to Length(Columns) - 1 do
        begin
          if ObjectIdEqual(Columns[J], P2) then
          begin
            P2Col := J;
            Break;
          end;
        end;

        if P2Col = -1 then
        begin
          SetLength(Columns, Length(Columns) + 1);
          Columns[Length(Columns) - 1] := P2;
        end;
      end;

      { Trim empty trailing columns }
      while (Length(Columns) > 0) and IsNullObjectId(Columns[Length(Columns) - 1]) do
        SetLength(Columns, Length(Columns) - 1);

      Line.CommitId := CommitId;
      Line.Glyphs := GlyphStr;
      Line.Decorations := FormatDecorations(CommitId);
      Line.Message := Commit.Message;
      Line.Author := Commit.Author.Name;
      Line.CommitDate := FormatDateTime('yyyy-mm-dd', UnixToDateTime(Commit.Author.When.Seconds));

      Result[I] := Line;
    finally
      Commit.Free;
    end;
  end;
end;

function TGraphRenderer.RenderHistory(const StartCommitId: TObjectId; MaxCommits: Integer): TGraphLineArray;
var
  Walker: TCommitWalker;
  CommitIds: TObjectIdArray;
  Id: TObjectId;
  Count: Integer;
begin
  Walker := TCommitWalker.Create(FODB, csoChronological);
  try
    Walker.Push(StartCommitId);
    SetLength(CommitIds, MaxCommits);
    Count := 0;

    while (Count < MaxCommits) and Walker.Next(Id) do
    begin
      CommitIds[Count] := Id;
      Inc(Count);
    end;

    SetLength(CommitIds, Count);
    Result := RenderGraph(CommitIds);
  finally
    Walker.Free;
  end;
end;

function TGraphRenderer.FormatGraphString(const Lines: TGraphLineArray): string;
var
  I: Integer;
  Row: string;
  ShortSha: string;
  Deco: string;
begin
  Result := '';
  for I := 0 to Length(Lines) - 1 do
  begin
    ShortSha := Copy(ObjectIdToHex(Lines[I].CommitId), 1, 8);
    Deco := Lines[I].Decorations;
    if Deco <> '' then Deco := ' ' + Deco;

    Row := Format('%-6s %s%s %s (%s, %s)'#10, [
      Lines[I].Glyphs,
      ShortSha,
      Deco,
      Lines[I].Message,
      Lines[I].Author,
      Lines[I].CommitDate
    ]);
    Result := Result + Row;
  end;
end;

end.
