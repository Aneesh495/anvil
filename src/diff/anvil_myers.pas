{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Eugene Myers O(ND) difference algorithm implementation.
  Finds the Shortest Edit Script (SES) / Longest Common Subsequence (LCS)
  using diagonal greedy snake traversal and trace-matrix backtracking.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_myers;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, anvil_types, anvil_utils;

type
  { Edit operation type }
  TEditOp = (
    eoKeep,
    eoInsert,
    eoDelete
  );

  { Single line difference instruction }
  TDiffLine = record
    Op: TEditOp;
    OldLineNo: Integer; { 1-based, 0 if insert }
    NewLineNo: Integer; { 1-based, 0 if delete }
    Text: string;
  end;
  TDiffLineArray = array of TDiffLine;

  { Myers diff engine }
  TMyersDiff = class
  private
    FLinesA: TStringArray;
    FLinesB: TStringArray;
    function ComputeSliceDiff(const SliceA, SliceB: TStringArray;
                              OldOffset, NewOffset: Integer): TDiffLineArray;
  public
    constructor Create(const TextA, TextB: string); overload;
    constructor Create(const LinesA, LinesB: TStringArray); overload;
    function ComputeDiff: TDiffLineArray;
  end;

function MyersDiffStrings(const TextA, TextB: string): TDiffLineArray;

implementation

constructor TMyersDiff.Create(const TextA, TextB: string);
begin
  inherited Create;
  FLinesA := SplitStringByChar(TextA, #10);
  FLinesB := SplitStringByChar(TextB, #10);
end;

constructor TMyersDiff.Create(const LinesA, LinesB: TStringArray);
begin
  inherited Create;
  FLinesA := LinesA;
  FLinesB := LinesB;
end;

function TMyersDiff.ComputeSliceDiff(const SliceA, SliceB: TStringArray;
                                     OldOffset, NewOffset: Integer): TDiffLineArray;
type
  TIntArray = array of Integer;
var
  N, M, MaxD, Offset, D, K: Integer;
  V: TIntArray;
  Trace: array of TIntArray;
  X, Y: Integer;
  Found: Boolean;
  PrevV: TIntArray;
  PrevK, PrevX, PrevY: Integer;
  RevScript: TDiffLineArray;
  ScriptCount: Integer;
  I, J: Integer;
begin
  N := Length(SliceA);
  M := Length(SliceB);

  { Fast path: both empty }
  if (N = 0) and (M = 0) then
  begin
    SetLength(Result, 0);
    Exit;
  end;

  { Fast path: old empty -> all insertions }
  if N = 0 then
  begin
    SetLength(Result, M);
    for I := 0 to M - 1 do
    begin
      Result[I].Op := eoInsert;
      Result[I].OldLineNo := 0;
      Result[I].NewLineNo := NewOffset + I + 1;
      Result[I].Text := SliceB[I];
    end;
    Exit;
  end;

  { Fast path: new empty -> all deletions }
  if M = 0 then
  begin
    SetLength(Result, N);
    for I := 0 to N - 1 do
    begin
      Result[I].Op := eoDelete;
      Result[I].OldLineNo := OldOffset + I + 1;
      Result[I].NewLineNo := 0;
      Result[I].Text := SliceA[I];
    end;
    Exit;
  end;

  MaxD := N + M;
  Offset := MaxD;
  SetLength(V, 2 * MaxD + 1);
  for I := 0 to 2 * MaxD do
    V[I] := 0;

  SetLength(Trace, 0);
  Found := False;

  for D := 0 to MaxD do
  begin
    { Save trace state before this step }
    SetLength(Trace, D + 1);
    SetLength(Trace[D], 2 * MaxD + 1);
    for I := 0 to 2 * MaxD do
      Trace[D][I] := V[I];

    K := -D;
    while K <= D do
    begin
      if (K = -D) or ((K <> D) and (V[Offset + K - 1] < V[Offset + K + 1])) then
        X := V[Offset + K + 1]
      else
        X := V[Offset + K - 1] + 1;

      Y := X - K;

      while (X < N) and (Y < M) and (SliceA[X] = SliceB[Y]) do
      begin
        Inc(X);
        Inc(Y);
      end;

      V[Offset + K] := X;

      if (X >= N) and (Y >= M) then
      begin
        Found := True;
        Break;
      end;

      Inc(K, 2);
    end;

    if Found then
      Break;
  end;

  { Backtrack from (N, M) to (0, 0) }
  X := N;
  Y := M;
  SetLength(RevScript, MaxD + N + M + 16);
  ScriptCount := 0;

  for D := Length(Trace) - 1 downto 1 do
  begin
    K := X - Y;
    PrevV := Trace[D];

    if (K = -D) or ((K <> D) and (PrevV[Offset + K - 1] < PrevV[Offset + K + 1])) then
      PrevK := K + 1
    else
      PrevK := K - 1;

    PrevX := PrevV[Offset + PrevK];
    PrevY := PrevX - PrevK;

    { Diagonal snake steps (keeps) }
    while (X > PrevX) and (Y > PrevY) do
    begin
      RevScript[ScriptCount].Op := eoKeep;
      RevScript[ScriptCount].OldLineNo := OldOffset + X;
      RevScript[ScriptCount].NewLineNo := NewOffset + Y;
      RevScript[ScriptCount].Text := SliceA[X - 1];
      Inc(ScriptCount);
      Dec(X);
      Dec(Y);
    end;

    { Edit step }
    if D > 0 then
    begin
      if X = PrevX then
      begin
        { Insert }
        RevScript[ScriptCount].Op := eoInsert;
        RevScript[ScriptCount].OldLineNo := 0;
        RevScript[ScriptCount].NewLineNo := NewOffset + Y;
        RevScript[ScriptCount].Text := SliceB[Y - 1];
        Inc(ScriptCount);
        Dec(Y);
      end
      else
      begin
        { Delete }
        RevScript[ScriptCount].Op := eoDelete;
        RevScript[ScriptCount].OldLineNo := OldOffset + X;
        RevScript[ScriptCount].NewLineNo := 0;
        RevScript[ScriptCount].Text := SliceA[X - 1];
        Inc(ScriptCount);
        Dec(X);
      end;
    end;
  end;

  { Remaining snake steps before D=0 }
  while (X > 0) and (Y > 0) do
  begin
    RevScript[ScriptCount].Op := eoKeep;
    RevScript[ScriptCount].OldLineNo := OldOffset + X;
    RevScript[ScriptCount].NewLineNo := NewOffset + Y;
    RevScript[ScriptCount].Text := SliceA[X - 1];
    Inc(ScriptCount);
    Dec(X);
    Dec(Y);
  end;

  { Reverse the script to forward order }
  SetLength(Result, ScriptCount);
  for J := 0 to ScriptCount - 1 do
    Result[J] := RevScript[ScriptCount - 1 - J];
end;

function TMyersDiff.ComputeDiff: TDiffLineArray;
var
  LenA, LenB: Integer;
  CommonPrefix, CommonSuffix: Integer;
  I, OutCount: Integer;
  SliceA, SliceB: TStringArray;
  MiddleDiff: TDiffLineArray;
begin
  LenA := Length(FLinesA);
  LenB := Length(FLinesB);

  { Trim identical prefix }
  CommonPrefix := 0;
  while (CommonPrefix < LenA) and (CommonPrefix < LenB) and
        (FLinesA[CommonPrefix] = FLinesB[CommonPrefix]) do
  begin
    Inc(CommonPrefix);
  end;

  { Trim identical suffix }
  CommonSuffix := 0;
  while (CommonSuffix < LenA - CommonPrefix) and (CommonSuffix < LenB - CommonPrefix) and
        (FLinesA[LenA - 1 - CommonSuffix] = FLinesB[LenB - 1 - CommonSuffix]) do
  begin
    Inc(CommonSuffix);
  end;

  SetLength(Result, CommonPrefix + CommonSuffix + 16);
  OutCount := 0;

  { Emit common prefix }
  for I := 0 to CommonPrefix - 1 do
  begin
    Result[OutCount].Op := eoKeep;
    Result[OutCount].OldLineNo := I + 1;
    Result[OutCount].NewLineNo := I + 1;
    Result[OutCount].Text := FLinesA[I];
    Inc(OutCount);
  end;

  { Extract differing middle slice }
  SetLength(SliceA, LenA - CommonPrefix - CommonSuffix);
  for I := 0 to Length(SliceA) - 1 do
    SliceA[I] := FLinesA[CommonPrefix + I];

  SetLength(SliceB, LenB - CommonPrefix - CommonSuffix);
  for I := 0 to Length(SliceB) - 1 do
    SliceB[I] := FLinesB[CommonPrefix + I];

  MiddleDiff := ComputeSliceDiff(SliceA, SliceB, CommonPrefix, CommonPrefix);
  for I := 0 to Length(MiddleDiff) - 1 do
  begin
    if OutCount >= Length(Result) then
      SetLength(Result, Length(Result) * 2 + 16);
    Result[OutCount] := MiddleDiff[I];
    Inc(OutCount);
  end;

  { Emit common suffix }
  for I := 0 to CommonSuffix - 1 do
  begin
    if OutCount >= Length(Result) then
      SetLength(Result, Length(Result) * 2 + 16);
    Result[OutCount].Op := eoKeep;
    Result[OutCount].OldLineNo := (LenA - CommonSuffix) + I + 1;
    Result[OutCount].NewLineNo := (LenB - CommonSuffix) + I + 1;
    Result[OutCount].Text := FLinesA[(LenA - CommonSuffix) + I];
    Inc(OutCount);
  end;

  SetLength(Result, OutCount);
end;

function MyersDiffStrings(const TextA, TextB: string): TDiffLineArray;
var
  DiffObj: TMyersDiff;
begin
  DiffObj := TMyersDiff.Create(TextA, TextB);
  try
    Result := DiffObj.ComputeDiff;
  finally
    DiffObj.Free;
  end;
end;

end.
