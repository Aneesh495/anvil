{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Bram Cohen Patience Diff algorithm implementation.
  Finds unique matching anchor lines between files and computes
  the Longest Increasing Subsequence (LIS) via patience sorting,
  producing human-readable diffs for refactored and moved code.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_patience;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, anvil_types, anvil_utils, anvil_myers;

type
  { Unique line match anchor }
  TPatienceMatch = record
    LineA: Integer;
    LineB: Integer;
    Text: string;
  end;
  TPatienceMatchArray = array of TPatienceMatch;

  { Patience diff engine }
  TPatienceDiff = class
  private
    FLinesA: TStringArray;
    FLinesB: TStringArray;
    function FindUniqueMatches(AStart, AEnd, BStart, BEnd: Integer): TPatienceMatchArray;
    function ComputeLIS(const Matches: array of TPatienceMatch): TPatienceMatchArray;
    procedure RecursiveDiff(AStart, AEnd, BStart, BEnd: Integer; var Output: TDiffLineArray; var OutCount: Integer);
  public
    constructor Create(const TextA, TextB: string); overload;
    constructor Create(const LinesA, LinesB: TStringArray); overload;
    function ComputeDiff: TDiffLineArray;
  end;

function PatienceDiffStrings(const TextA, TextB: string): TDiffLineArray;

implementation

constructor TPatienceDiff.Create(const TextA, TextB: string);
begin
  inherited Create;
  FLinesA := SplitStringByChar(TextA, #10);
  FLinesB := SplitStringByChar(TextB, #10);
end;

constructor TPatienceDiff.Create(const LinesA, LinesB: TStringArray);
begin
  inherited Create;
  FLinesA := LinesA;
  FLinesB := LinesB;
end;

function TPatienceDiff.FindUniqueMatches(AStart, AEnd, BStart, BEnd: Integer): TPatienceMatchArray;
var
  CountsA, CountsB: TStringList;
  I, IdxA, IdxB: Integer;
  Line: string;
  MatchList: array of TPatienceMatch;
  MatchCount: Integer;
begin
  Result := nil;
  CountsA := TStringList.Create;
  CountsB := TStringList.Create;
  CountsA.Sorted := True;
  CountsB.Sorted := True;
  try
    { Count frequencies in slice A }
    for I := AStart to AEnd - 1 do
    begin
      Line := FLinesA[I];
      if CountsA.Find(Line, IdxA) then
        CountsA.Objects[IdxA] := TObject(Pointer(PtrInt(CountsA.Objects[IdxA]) + 1))
      else
        CountsA.AddObject(Line, TObject(Pointer(PtrInt(1))));
    end;

    { Count frequencies in slice B }
    for I := BStart to BEnd - 1 do
    begin
      Line := FLinesB[I];
      if CountsB.Find(Line, IdxB) then
        CountsB.Objects[IdxB] := TObject(Pointer(PtrInt(CountsB.Objects[IdxB]) + 1))
      else
        CountsB.AddObject(Line, TObject(Pointer(PtrInt(1))));
    end;

    { Collect lines that appear exactly once in A and exactly once in B }
    SetLength(MatchList, AEnd - AStart);
    MatchCount := 0;

    for I := AStart to AEnd - 1 do
    begin
      Line := FLinesA[I];
      if CountsA.Find(Line, IdxA) and (PtrInt(CountsA.Objects[IdxA]) = 1) then
      begin
        if CountsB.Find(Line, IdxB) and (PtrInt(CountsB.Objects[IdxB]) = 1) then
        begin
          MatchList[MatchCount].LineA := I;
          MatchList[MatchCount].Text := Line;
          Inc(MatchCount);
        end;
      end;
    end;

    { Locate corresponding position in B }
    for I := 0 to MatchCount - 1 do
    begin
      Line := MatchList[I].Text;
      for IdxB := BStart to BEnd - 1 do
      begin
        if FLinesB[IdxB] = Line then
        begin
          MatchList[I].LineB := IdxB;
          Break;
        end;
      end;
    end;

    SetLength(Result, MatchCount);
    for I := 0 to MatchCount - 1 do
      Result[I] := MatchList[I];

  finally
    CountsA.Free;
    CountsB.Free;
  end;
end;

function TPatienceDiff.ComputeLIS(const Matches: array of TPatienceMatch): TPatienceMatchArray;
var
  N, I, LowIdx, HighIdx, Mid, PosIdx: Integer;
  Piles: array of Integer; { Value in B }
  PileIndices: array of Integer; { Index into Matches }
  Predecessors: array of Integer;
  PileCount: Integer;
  CurrIdx, OutIdx: Integer;
begin
  Result := nil;
  N := Length(Matches);
  if N = 0 then
    Exit;

  SetLength(Piles, N);
  SetLength(PileIndices, N);
  SetLength(Predecessors, N);
  for I := 0 to N - 1 do
    Predecessors[I] := -1;

  PileCount := 0;

  for I := 0 to N - 1 do
  begin
    { Binary search for leftmost pile with value >= Matches[I].LineB }
    LowIdx := 0;
    HighIdx := PileCount - 1;
    PosIdx := PileCount;

    while LowIdx <= HighIdx do
    begin
      Mid := LowIdx + (HighIdx - LowIdx) div 2;
      if Piles[Mid] >= Matches[I].LineB then
      begin
        PosIdx := Mid;
        HighIdx := Mid - 1;
      end
      else
        LowIdx := Mid + 1;
    end;

    Piles[PosIdx] := Matches[I].LineB;
    PileIndices[PosIdx] := I;

    if PosIdx > 0 then
      Predecessors[I] := PileIndices[PosIdx - 1];

    if PosIdx = PileCount then
      Inc(PileCount);
  end;

  { Reconstruct LIS sequence backward }
  SetLength(Result, PileCount);
  CurrIdx := PileIndices[PileCount - 1];
  OutIdx := PileCount - 1;

  while CurrIdx >= 0 do
  begin
    Result[OutIdx] := Matches[CurrIdx];
    Dec(OutIdx);
    CurrIdx := Predecessors[CurrIdx];
  end;
end;

procedure TPatienceDiff.RecursiveDiff(AStart, AEnd, BStart, BEnd: Integer;
                                      var Output: TDiffLineArray; var OutCount: Integer);
var
  Matches, Anchors: TPatienceMatchArray;
  PrevA, PrevB: Integer;
  I: Integer;
  SubMyers: TMyersDiff;
  SubDiff: TDiffLineArray;
  J: Integer;
begin
  if (AStart >= AEnd) and (BStart >= BEnd) then
    Exit;

  Matches := FindUniqueMatches(AStart, AEnd, BStart, BEnd);
  Anchors := ComputeLIS(Matches);

  if Length(Anchors) = 0 then
  begin
    { Fall back to Myers diff for regions without unique anchor lines }
    SubMyers := TMyersDiff.Create(Copy(FLinesA, AStart, AEnd - AStart),
                                  Copy(FLinesB, BStart, BEnd - BStart));
    try
      SubDiff := SubMyers.ComputeDiff;
      for J := 0 to High(SubDiff) do
      begin
        if OutCount >= Length(Output) then
          SetLength(Output, Length(Output) * 2 + 16);
        Output[OutCount] := SubDiff[J];
        if Output[OutCount].OldLineNo > 0 then
          Output[OutCount].OldLineNo := Output[OutCount].OldLineNo + AStart;
        if Output[OutCount].NewLineNo > 0 then
          Output[OutCount].NewLineNo := Output[OutCount].NewLineNo + BStart;
        Inc(OutCount);
      end;
    finally
      SubMyers.Free;
    end;
    Exit;
  end;

  PrevA := AStart;
  PrevB := BStart;

  for I := 0 to High(Anchors) do
  begin
    { Recursively diff region before this anchor }
    RecursiveDiff(PrevA, Anchors[I].LineA, PrevB, Anchors[I].LineB, Output, OutCount);

    { Emit anchor line as keep }
    if OutCount >= Length(Output) then
      SetLength(Output, Length(Output) * 2 + 16);
    Output[OutCount].Op := eoKeep;
    Output[OutCount].OldLineNo := Anchors[I].LineA + 1;
    Output[OutCount].NewLineNo := Anchors[I].LineB + 1;
    Output[OutCount].Text := Anchors[I].Text;
    Inc(OutCount);

    PrevA := Anchors[I].LineA + 1;
    PrevB := Anchors[I].LineB + 1;
  end;

  { Recursively diff trailing region after last anchor }
  RecursiveDiff(PrevA, AEnd, PrevB, BEnd, Output, OutCount);
end;

function TPatienceDiff.ComputeDiff: TDiffLineArray;
var
  OutCount: Integer;
begin
  Result := nil;
  SetLength(Result, Length(FLinesA) + Length(FLinesB) + 16);
  OutCount := 0;
  RecursiveDiff(0, Length(FLinesA), 0, Length(FLinesB), Result, OutCount);
  SetLength(Result, OutCount);
end;

function PatienceDiffStrings(const TextA, TextB: string): TDiffLineArray;
var
  DiffObj: TPatienceDiff;
begin
  DiffObj := TPatienceDiff.Create(TextA, TextB);
  try
    Result := DiffObj.ComputeDiff;
  finally
    DiffObj.Free;
  end;
end;

end.
