{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Three-way file-level merge engine.
  Reconciles simultaneous edits from two diverged branches relative to their
  common ancestor, emitting standard Git conflict markers for conflicting regions.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_merge3;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_utils, anvil_myers;

type
  { Merge hunk category }
  THunkSource = (
    hsCleanBase,
    hsCleanOurs,
    hsCleanTheirs,
    hsCleanBothSame,
    hsConflict
  );

  { Result of 3-way merge }
  TMerge3Result = record
    HasConflict: Boolean;
    ConflictCount: Integer;
    MergedText: string;
    MergedLines: TStringArray;
  end;

  { Three-way merge engine }
  TMerge3 = class
  private
    FBaseText: string;
    FOursText: string;
    FTheirsText: string;
    FLabelOurs: string;
    FLabelTheirs: string;
    FIncludeDiff3Base: Boolean;
  public
    constructor Create(const BaseText, OursText, TheirsText: string;
                       const LabelOurs: string = 'ours';
                       const LabelTheirs: string = 'theirs';
                       IncludeDiff3Base: Boolean = False);

    function Execute: TMerge3Result;
  end;

function Merge3Strings(const BaseText, OursText, TheirsText: string;
                       const LabelOurs: string = 'ours';
                       const LabelTheirs: string = 'theirs';
                       IncludeDiff3Base: Boolean = False): TMerge3Result;

implementation

constructor TMerge3.Create(const BaseText, OursText, TheirsText: string;
                           const LabelOurs, LabelTheirs: string;
                           IncludeDiff3Base: Boolean);
begin
  inherited Create;
  FBaseText := BaseText;
  FOursText := OursText;
  FTheirsText := TheirsText;
  FLabelOurs := LabelOurs;
  FLabelTheirs := LabelTheirs;
  FIncludeDiff3Base := IncludeDiff3Base;
end;

type
  TBaseSegment = record
    BaseStart: Integer; { 1-based, 0 if purely inserted before line 1 }
    BaseCount: Integer;
    OursLines: TStringArray;
    TheirsLines: TStringArray;
    BaseLines: TStringArray;
    OursModified: Boolean;
    TheirsModified: Boolean;
  end;

function TMerge3.Execute: TMerge3Result;
var
  DiffOurs, DiffTheirs: TDiffLineArray;
  BaseLines, OursLines, TheirsLines: TStringArray;
  OutLines: TStringArray;
  OutCount: Integer;
  Conflicts: Integer;
  I, J, K: Integer;

  procedure AppendLine(const S: string);
  begin
    if OutCount >= Length(OutLines) then
      SetLength(OutLines, Length(OutLines) * 2 + 16);
    OutLines[OutCount] := S;
    Inc(OutCount);
  end;

  function AreLineArraysEqual(const A, B: TStringArray): Boolean;
  var
    Idx: Integer;
  begin
    if Length(A) <> Length(B) then
      Exit(False);
    for Idx := 0 to Length(A) - 1 do
    begin
      if A[Idx] <> B[Idx] then
        Exit(False);
    end;
    Result := True;
  end;

var
  BaseLen: Integer;
  OursChanges, TheirsChanges: array of TStringArray;
  OursDeleted, TheirsDeleted: array of Boolean;
  Idx: Integer;
  OldNo: Integer;
  CurrBaseLine: Integer;
begin
  BaseLines := SplitStringByChar(FBaseText, #10);
  OursLines := SplitStringByChar(FOursText, #10);
  TheirsLines := SplitStringByChar(FTheirsText, #10);

  BaseLen := Length(BaseLines);

  { Trivial fast paths }
  if FOursText = FTheirsText then
  begin
    Result.HasConflict := False;
    Result.ConflictCount := 0;
    Result.MergedText := FOursText;
    Result.MergedLines := OursLines;
    Exit;
  end;

  if FBaseText = FOursText then
  begin
    Result.HasConflict := False;
    Result.ConflictCount := 0;
    Result.MergedText := FTheirsText;
    Result.MergedLines := TheirsLines;
    Exit;
  end;

  if FBaseText = FTheirsText then
  begin
    Result.HasConflict := False;
    Result.ConflictCount := 0;
    Result.MergedText := FOursText;
    Result.MergedLines := OursLines;
    Exit;
  end;

  { Compute Myers diff from Base to Ours and from Base to Theirs }
  DiffOurs := MyersDiffStrings(FBaseText, FOursText);
  DiffTheirs := MyersDiffStrings(FBaseText, FTheirsText);

  { Slot 0 represents insertions before Base line 1.
    Slots 1..BaseLen represent replacements/insertions after Base line I }
  SetLength(OursChanges, BaseLen + 1);
  SetLength(TheirsChanges, BaseLen + 1);
  SetLength(OursDeleted, BaseLen + 1);
  SetLength(TheirsDeleted, BaseLen + 1);

  for I := 0 to BaseLen do
  begin
    SetLength(OursChanges[I], 0);
    SetLength(TheirsChanges[I], 0);
    OursDeleted[I] := False;
    TheirsDeleted[I] := False;
  end;

  { Map DiffOurs to base line slots }
  CurrBaseLine := 0;
  for I := 0 to Length(DiffOurs) - 1 do
  begin
    case DiffOurs[I].Op of
      eoKeep:
        CurrBaseLine := DiffOurs[I].OldLineNo;
      eoDelete:
      begin
        OldNo := DiffOurs[I].OldLineNo;
        OursDeleted[OldNo] := True;
        CurrBaseLine := OldNo;
      end;
      eoInsert:
      begin
        SetLength(OursChanges[CurrBaseLine], Length(OursChanges[CurrBaseLine]) + 1);
        OursChanges[CurrBaseLine][Length(OursChanges[CurrBaseLine]) - 1] := DiffOurs[I].Text;
      end;
    end;
  end;

  { Map DiffTheirs to base line slots }
  CurrBaseLine := 0;
  for I := 0 to Length(DiffTheirs) - 1 do
  begin
    case DiffTheirs[I].Op of
      eoKeep:
        CurrBaseLine := DiffTheirs[I].OldLineNo;
      eoDelete:
      begin
        OldNo := DiffTheirs[I].OldLineNo;
        TheirsDeleted[OldNo] := True;
        CurrBaseLine := OldNo;
      end;
      eoInsert:
      begin
        SetLength(TheirsChanges[CurrBaseLine], Length(TheirsChanges[CurrBaseLine]) + 1);
        TheirsChanges[CurrBaseLine][Length(TheirsChanges[CurrBaseLine]) - 1] := DiffTheirs[I].Text;
      end;
    end;
  end;

  SetLength(OutLines, BaseLen + Length(OursLines) + Length(TheirsLines) + 32);
  OutCount := 0;
  Conflicts := 0;

  { Process preamble slot 0 (insertions before first base line) }
  if (Length(OursChanges[0]) > 0) or (Length(TheirsChanges[0]) > 0) then
  begin
    if AreLineArraysEqual(OursChanges[0], TheirsChanges[0]) then
    begin
      for K := 0 to Length(OursChanges[0]) - 1 do
        AppendLine(OursChanges[0][K]);
    end
    else if Length(OursChanges[0]) = 0 then
    begin
      for K := 0 to Length(TheirsChanges[0]) - 1 do
        AppendLine(TheirsChanges[0][K]);
    end
    else if Length(TheirsChanges[0]) = 0 then
    begin
      for K := 0 to Length(OursChanges[0]) - 1 do
        AppendLine(OursChanges[0][K]);
    end
    else
    begin
      { Conflict in slot 0 }
      Inc(Conflicts);
      AppendLine('<<<<<<< ' + FLabelOurs);
      for K := 0 to Length(OursChanges[0]) - 1 do
        AppendLine(OursChanges[0][K]);
      if FIncludeDiff3Base then
        AppendLine('||||||| base');
      AppendLine('=======');
      for K := 0 to Length(TheirsChanges[0]) - 1 do
        AppendLine(TheirsChanges[0][K]);
      AppendLine('>>>>>>> ' + FLabelTheirs);
    end;
  end;

  { Process base lines 1..BaseLen }
  for I := 1 to BaseLen do
  begin
    { Check if both sides modified or deleted line I }
    if OursDeleted[I] and TheirsDeleted[I] then
    begin
      { Both deleted this base line: clean deletion, output nothing for base line }
      { But check if either side inserted text here }
      if AreLineArraysEqual(OursChanges[I], TheirsChanges[I]) then
      begin
        for K := 0 to Length(OursChanges[I]) - 1 do
          AppendLine(OursChanges[I][K]);
      end
      else
      begin
        Inc(Conflicts);
        AppendLine('<<<<<<< ' + FLabelOurs);
        for K := 0 to Length(OursChanges[I]) - 1 do
          AppendLine(OursChanges[I][K]);
        if FIncludeDiff3Base then
        begin
          AppendLine('||||||| base');
          AppendLine(BaseLines[I - 1]);
        end;
        AppendLine('=======');
        for K := 0 to Length(TheirsChanges[I]) - 1 do
          AppendLine(TheirsChanges[I][K]);
        AppendLine('>>>>>>> ' + FLabelTheirs);
      end;
    end
    else if OursDeleted[I] and (not TheirsDeleted[I]) then
    begin
      { Ours deleted, theirs kept or modified }
      if Length(TheirsChanges[I]) = 0 then
      begin
        { Clean edit/delete by ours: emit our replacement lines (if any) }
        for K := 0 to Length(OursChanges[I]) - 1 do
          AppendLine(OursChanges[I][K]);
      end
      else
      begin
        { Conflict: delete/replace by ours vs insertions by theirs }
        Inc(Conflicts);
        AppendLine('<<<<<<< ' + FLabelOurs);
        for K := 0 to Length(OursChanges[I]) - 1 do
          AppendLine(OursChanges[I][K]);
        if FIncludeDiff3Base then
        begin
          AppendLine('||||||| base');
          AppendLine(BaseLines[I - 1]);
        end;
        AppendLine('=======');
        AppendLine(BaseLines[I - 1]);
        for K := 0 to Length(TheirsChanges[I]) - 1 do
          AppendLine(TheirsChanges[I][K]);
        AppendLine('>>>>>>> ' + FLabelTheirs);
      end;
    end
    else if (not OursDeleted[I]) and TheirsDeleted[I] then
    begin
      { Theirs deleted, ours kept or modified }
      if Length(OursChanges[I]) = 0 then
      begin
        { Clean edit/delete by theirs: emit their replacement lines (if any) }
        for K := 0 to Length(TheirsChanges[I]) - 1 do
          AppendLine(TheirsChanges[I][K]);
      end
      else
      begin
        { Conflict: insertions by ours vs delete/replace by theirs }
        Inc(Conflicts);
        AppendLine('<<<<<<< ' + FLabelOurs);
        AppendLine(BaseLines[I - 1]);
        for K := 0 to Length(OursChanges[I]) - 1 do
          AppendLine(OursChanges[I][K]);
        if FIncludeDiff3Base then
        begin
          AppendLine('||||||| base');
          AppendLine(BaseLines[I - 1]);
        end;
        AppendLine('=======');
        for K := 0 to Length(TheirsChanges[I]) - 1 do
          AppendLine(TheirsChanges[I][K]);
        AppendLine('>>>>>>> ' + FLabelTheirs);
      end;
    end
    else
    begin
      { Neither side deleted base line I }
      AppendLine(BaseLines[I - 1]);

      { Check insertions following this base line }
      if (Length(OursChanges[I]) > 0) or (Length(TheirsChanges[I]) > 0) then
      begin
        if AreLineArraysEqual(OursChanges[I], TheirsChanges[I]) then
        begin
          for K := 0 to Length(OursChanges[I]) - 1 do
            AppendLine(OursChanges[I][K]);
        end
        else if Length(OursChanges[I]) = 0 then
        begin
          for K := 0 to Length(TheirsChanges[I]) - 1 do
            AppendLine(TheirsChanges[I][K]);
        end
        else if Length(TheirsChanges[I]) = 0 then
        begin
          for K := 0 to Length(OursChanges[I]) - 1 do
            AppendLine(OursChanges[I][K]);
        end
        else
        begin
          { Conflict in post-line insertions }
          Inc(Conflicts);
          AppendLine('<<<<<<< ' + FLabelOurs);
          for K := 0 to Length(OursChanges[I]) - 1 do
            AppendLine(OursChanges[I][K]);
          if FIncludeDiff3Base then
            AppendLine('||||||| base');
          AppendLine('=======');
          for K := 0 to Length(TheirsChanges[I]) - 1 do
            AppendLine(TheirsChanges[I][K]);
          AppendLine('>>>>>>> ' + FLabelTheirs);
        end;
      end;
    end;
  end;

  SetLength(OutLines, OutCount);
  Result.HasConflict := Conflicts > 0;
  Result.ConflictCount := Conflicts;
  Result.MergedLines := OutLines;
  Result.MergedText := string.Join(#10, OutLines);
end;

function Merge3Strings(const BaseText, OursText, TheirsText: string;
                       const LabelOurs: string;
                       const LabelTheirs: string;
                       IncludeDiff3Base: Boolean): TMerge3Result;
var
  M: TMerge3;
begin
  M := TMerge3.Create(BaseText, OursText, TheirsText, LabelOurs, LabelTheirs, IncludeDiff3Base);
  try
    Result := M.Execute;
  finally
    M.Free;
  end;
end;

end.
