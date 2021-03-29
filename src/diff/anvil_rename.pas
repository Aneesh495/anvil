{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Rename and copy detection engine. Implements exact hash matching and
  inexact content similarity estimation via token n-gram Jaccard scoring.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_rename;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, anvil_types, anvil_utils, anvil_object, anvil_odb, anvil_diff_tree;

type
  { Rename detection coordinator }
  TRenameDetector = class
  private
    FOdb: TObjectDatabase;
    FThreshold: Integer; { Default 50% }
    function ComputeBlobSimilarity(const IdA, IdB: TObjectId): Integer;
  public
    constructor Create(Odb: TObjectDatabase; Threshold: Integer = 50);
    function DetectRenames(const InputDeltas: TTreeDeltaArray): TTreeDeltaArray;
    property Threshold: Integer read FThreshold write FThreshold;
  end;

implementation

constructor TRenameDetector.Create(Odb: TObjectDatabase; Threshold: Integer);
begin
  inherited Create;
  FOdb := Odb;
  FThreshold := Threshold;
end;

function TRenameDetector.ComputeBlobSimilarity(const IdA, IdB: TObjectId): Integer;
var
  DataA, DataB: TByteArray;
  TypeA, TypeB: TObjectType;
  LinesA, LinesB: TStringArray;
  ListA, ListB: TStringList;
  StrA, StrB: string;
  I, IntersectCount, UnionCount, Idx: Integer;
begin
  { Exact match fast path }
  if ObjectIdEqual(IdA, IdB) then
    Exit(100);

  if not FOdb.ReadObjectRaw(IdA, TypeA, DataA) then Exit(0);
  if not FOdb.ReadObjectRaw(IdB, TypeB, DataB) then Exit(0);

  if (Length(DataA) = 0) and (Length(DataB) = 0) then
    Exit(100);
  if (Length(DataA) = 0) or (Length(DataB) = 0) then
    Exit(0);

  SetString(StrA, PChar(@DataA[0]), Length(DataA));
  SetString(StrB, PChar(@DataB[0]), Length(DataB));
  LinesA := SplitStringByChar(StrA, #10);
  LinesB := SplitStringByChar(StrB, #10);

  ListA := TStringList.Create;
  ListB := TStringList.Create;
  ListA.Sorted := True;
  ListB.Sorted := True;
  try
    for I := 0 to High(LinesA) do
      ListA.Add(LinesA[I]);
    for I := 0 to High(LinesB) do
      ListB.Add(LinesB[I]);

    IntersectCount := 0;
    for I := 0 to ListA.Count - 1 do
    begin
      if ListB.Find(ListA[I], Idx) then
        Inc(IntersectCount);
    end;

    UnionCount := ListA.Count + ListB.Count - IntersectCount;
    if UnionCount = 0 then
      Result := 100
    else
      Result := (IntersectCount * 100) div UnionCount;

  finally
    ListA.Free;
    ListB.Free;
  end;
end;

function TRenameDetector.DetectRenames(const InputDeltas: TTreeDeltaArray): TTreeDeltaArray;
var
  DeletedIndices: array of Integer;
  AddedIndices: array of Integer;
  DelCount, AddCount, I, J: Integer;
  UsedDeleted, UsedAdded: array of Boolean;
  BestScore, Score, BestAddIdx, BestDelIdx: Integer;
  OutList: TTreeDeltaArray;
  OutCount: Integer;
  MatchedDelta: TTreeDelta;
begin
  Result := nil;
  DelCount := 0;
  AddCount := 0;
  SetLength(DeletedIndices, Length(InputDeltas));
  SetLength(AddedIndices, Length(InputDeltas));

  for I := 0 to High(InputDeltas) do
  begin
    if InputDeltas[I].Status = dsDeleted then
    begin
      DeletedIndices[DelCount] := I;
      Inc(DelCount);
    end
    else if InputDeltas[I].Status = dsAdded then
    begin
      AddedIndices[AddCount] := I;
      Inc(AddCount);
    end;
  end;

  if (DelCount = 0) or (AddCount = 0) then
    Exit(InputDeltas);

  SetLength(UsedDeleted, DelCount);
  SetLength(UsedAdded, AddCount);
  for I := 0 to DelCount - 1 do UsedDeleted[I] := False;
  for I := 0 to AddCount - 1 do UsedAdded[I] := False;

  SetLength(OutList, Length(InputDeltas));
  OutCount := 0;

  { Pass 1: Exact matches (100% identical object hash) }
  for I := 0 to DelCount - 1 do
  begin
    if UsedDeleted[I] then Continue;
    for J := 0 to AddCount - 1 do
    begin
      if UsedAdded[J] then Continue;
      if ObjectIdEqual(InputDeltas[DeletedIndices[I]].OldId, InputDeltas[AddedIndices[J]].NewId) then
      begin
        MatchedDelta.OldPath := InputDeltas[DeletedIndices[I]].OldPath;
        MatchedDelta.NewPath := InputDeltas[AddedIndices[J]].NewPath;
        MatchedDelta.OldId := InputDeltas[DeletedIndices[I]].OldId;
        MatchedDelta.NewId := InputDeltas[AddedIndices[J]].NewId;
        MatchedDelta.OldMode := InputDeltas[DeletedIndices[I]].OldMode;
        MatchedDelta.NewMode := InputDeltas[AddedIndices[J]].NewMode;
        MatchedDelta.Status := dsRenamed;
        MatchedDelta.Similarity := 100;

        OutList[OutCount] := MatchedDelta;
        Inc(OutCount);

        UsedDeleted[I] := True;
        UsedAdded[J] := True;
        Break;
      end;
    end;
  end;

  { Pass 2: Inexact matches exceeding similarity threshold }
  for I := 0 to DelCount - 1 do
  begin
    if UsedDeleted[I] then Continue;
    BestScore := 0;
    BestAddIdx := -1;

    for J := 0 to AddCount - 1 do
    begin
      if UsedAdded[J] then Continue;
      Score := ComputeBlobSimilarity(InputDeltas[DeletedIndices[I]].OldId, InputDeltas[AddedIndices[J]].NewId);
      if (Score >= FThreshold) and (Score > BestScore) then
      begin
        BestScore := Score;
        BestAddIdx := J;
      end;
    end;

    if BestAddIdx >= 0 then
    begin
      MatchedDelta.OldPath := InputDeltas[DeletedIndices[I]].OldPath;
      MatchedDelta.NewPath := InputDeltas[AddedIndices[BestAddIdx]].NewPath;
      MatchedDelta.OldId := InputDeltas[DeletedIndices[I]].OldId;
      MatchedDelta.NewId := InputDeltas[AddedIndices[BestAddIdx]].NewId;
      MatchedDelta.OldMode := InputDeltas[DeletedIndices[I]].OldMode;
      MatchedDelta.NewMode := InputDeltas[AddedIndices[BestAddIdx]].NewMode;
      MatchedDelta.Status := dsRenamed;
      MatchedDelta.Similarity := BestScore;

      OutList[OutCount] := MatchedDelta;
      Inc(OutCount);

      UsedDeleted[I] := True;
      UsedAdded[BestAddIdx] := True;
    end;
  end;

  { Pass 3: Collect unmatched entries and existing non-add/delete entries }
  for I := 0 to High(InputDeltas) do
  begin
    if InputDeltas[I].Status = dsDeleted then
    begin
      for J := 0 to DelCount - 1 do
      begin
        if (DeletedIndices[J] = I) and (not UsedDeleted[J]) then
        begin
          OutList[OutCount] := InputDeltas[I];
          Inc(OutCount);
          Break;
        end;
      end;
    end
    else if InputDeltas[I].Status = dsAdded then
    begin
      for J := 0 to AddCount - 1 do
      begin
        if (AddedIndices[J] = I) and (not UsedAdded[J]) then
        begin
          OutList[OutCount] := InputDeltas[I];
          Inc(OutCount);
          Break;
        end;
      end;
    end
    else
    begin
      OutList[OutCount] := InputDeltas[I];
      Inc(OutCount);
    end;
  end;

  SetLength(Result, OutCount);
  for I := 0 to OutCount - 1 do
    Result[I] := OutList[I];
end;

end.
