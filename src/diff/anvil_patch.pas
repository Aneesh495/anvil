{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Unified diff patch and statistical summary generator. Groups line-by-line
  edit operations into standard context hunks and formats diff --git headers.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_patch;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, anvil_types, anvil_utils, anvil_myers, anvil_diff_tree;

type
  { Single unified diff hunk }
  TDiffHunk = record
    OldStart: Integer;
    OldCount: Integer;
    NewStart: Integer;
    NewCount: Integer;
    Lines: TDiffLineArray;
  end;
  TDiffHunkArray = array of TDiffHunk;

  { Patch generator }
  TPatchGenerator = class
  private
    FContextLines: Integer;
    function GroupIntoHunks(const Lines: TDiffLineArray): TDiffHunkArray;
  public
    constructor Create(ContextLines: Integer = 3);
    function FormatFileDiff(const Delta: TTreeDelta; const Lines: TDiffLineArray): string;
    function FormatDiffStat(const Deltas: TTreeDeltaArray; const AllLines: array of TDiffLineArray): string;
    property ContextLines: Integer read FContextLines write FContextLines;
  end;

implementation

constructor TPatchGenerator.Create(ContextLines: Integer);
begin
  inherited Create;
  FContextLines := ContextLines;
end;

function TPatchGenerator.GroupIntoHunks(const Lines: TDiffLineArray): TDiffHunkArray;
var
  Hunks: array of TDiffHunk;
  HunkCount: Integer;
  I, J, K, EditIdx: Integer;
  HunkStart, HunkEnd: Integer;
  InHunk: Boolean;
  HunkLines: TDiffLineArray;
  OldStartVal, OldLinesVal, NewStartVal, NewLinesVal: Integer;
begin
  Result := nil;
  if Length(Lines) = 0 then
    Exit;

  SetLength(Hunks, 16);
  HunkCount := 0;

  I := 0;
  while I < Length(Lines) do
  begin
    { Skip leading identical keep lines }
    while (I < Length(Lines)) and (Lines[I].Op = eoKeep) do
      Inc(I);

    if I >= Length(Lines) then
      Break;

    { Determine hunk boundaries with context }
    HunkStart := I - FContextLines;
    if HunkStart < 0 then
      HunkStart := 0;

    { Find last edit in this hunk cluster }
    EditIdx := I;
    while EditIdx < Length(Lines) do
    begin
      if Lines[EditIdx].Op <> eoKeep then
        I := EditIdx
      else if EditIdx - I > FContextLines * 2 then
        Break;
      Inc(EditIdx);
    end;

    HunkEnd := I + FContextLines;
    if HunkEnd >= Length(Lines) then
      HunkEnd := Length(Lines) - 1;

    { Populate hunk lines }
    SetLength(HunkLines, HunkEnd - HunkStart + 1);
    OldStartVal := 0;
    OldLinesVal := 0;
    NewStartVal := 0;
    NewLinesVal := 0;

    for J := HunkStart to HunkEnd do
    begin
      HunkLines[J - HunkStart] := Lines[J];
      if Lines[J].Op in [eoKeep, eoDelete] then
      begin
        if OldStartVal = 0 then
          OldStartVal := Lines[J].OldLineNo;
        Inc(OldLinesVal);
      end;
      if Lines[J].Op in [eoKeep, eoInsert] then
      begin
        if NewStartVal = 0 then
          NewStartVal := Lines[J].NewLineNo;
        Inc(NewLinesVal);
      end;
    end;

    if HunkCount >= Length(Hunks) then
      SetLength(Hunks, Length(Hunks) * 2);

    Hunks[HunkCount].OldStart := OldStartVal;
    Hunks[HunkCount].OldCount := OldLinesVal;
    Hunks[HunkCount].NewStart := NewStartVal;
    Hunks[HunkCount].NewCount := NewLinesVal;
    Hunks[HunkCount].Lines := HunkLines;
    Inc(HunkCount);

    I := HunkEnd + 1;
  end;

  SetLength(Result, HunkCount);
  for I := 0 to HunkCount - 1 do
    Result[I] := Hunks[I];
end;

function TPatchGenerator.FormatFileDiff(const Delta: TTreeDelta; const Lines: TDiffLineArray): string;
var
  Hunks: TDiffHunkArray;
  S: string;
  I, J: Integer;
  OldHex, NewHex: string;
  PrefixChar: Char;
begin
  Hunks := GroupIntoHunks(Lines);
  if Length(Hunks) = 0 then
    Exit('');

  OldHex := Copy(ObjectIdToHex(Delta.OldId), 1, 7);
  NewHex := Copy(ObjectIdToHex(Delta.NewId), 1, 7);

  S := Format('diff --git a/%s b/%s'#10, [Delta.OldPath, Delta.NewPath]);
  S := S + Format('index %s..%s %s'#10, [OldHex, NewHex, FileModeToString(Delta.NewMode)]);
  S := S + Format('--- a/%s'#10, [Delta.OldPath]);
  S := S + Format('+++ b/%s'#10, [Delta.NewPath]);

  for I := 0 to High(Hunks) do
  begin
    S := S + Format('@@ -%d,%d +%d,%d @@'#10, [
      Hunks[I].OldStart, Hunks[I].OldCount,
      Hunks[I].NewStart, Hunks[I].NewCount
    ]);

    for J := 0 to High(Hunks[I].Lines) do
    begin
      case Hunks[I].Lines[J].Op of
        eoKeep:   PrefixChar := ' ';
        eoInsert: PrefixChar := '+';
        eoDelete: PrefixChar := '-';
      else
        PrefixChar := ' ';
      end;
      S := S + PrefixChar + Hunks[I].Lines[J].Text + #10;
    end;
  end;

  Result := S;
end;

function TPatchGenerator.FormatDiffStat(const Deltas: TTreeDeltaArray; const AllLines: array of TDiffLineArray): string;
var
  S, FilePath: string;
  I, J: Integer;
  AddCount, DelCount, MaxPathLen: Integer;
  PlusStr, MinusStr: string;
begin
  S := '';
  MaxPathLen := 0;
  for I := 0 to High(Deltas) do
  begin
    if Length(Deltas[I].NewPath) > MaxPathLen then
      MaxPathLen := Length(Deltas[I].NewPath);
  end;

  for I := 0 to High(Deltas) do
  begin
    FilePath := Deltas[I].NewPath;
    if FilePath = '' then
      FilePath := Deltas[I].OldPath;

    AddCount := 0;
    DelCount := 0;
    if I < Length(AllLines) then
    begin
      for J := 0 to High(AllLines[I]) do
      begin
        if AllLines[I][J].Op = eoInsert then Inc(AddCount)
        else if AllLines[I][J].Op = eoDelete then Inc(DelCount);
      end;
    end;

    PlusStr := StringOfChar('+', AddCount);
    MinusStr := StringOfChar('-', DelCount);
    S := S + Format(' %-*s | %3d %s%s'#10, [
      MaxPathLen, FilePath, AddCount + DelCount, PlusStr, MinusStr
    ]);
  end;

  Result := S;
end;

end.
