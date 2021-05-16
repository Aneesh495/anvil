{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Revision specification parser.
  Resolves short hex identifiers, branch/tag references, ancestor operators (^, ~N),
  reflog specifications (@[N]), and two-dot/three-dot revision ranges.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_revision;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_ref, anvil_reflog, anvil_utils;

type
  { Revision parser and range resolver }
  TRevisionParser = class
  private
    FRefMgr: TRefManager;
    FReflogMgr: TReflogManager;
    FODB: TObjectDatabase;
    FAlgo: THashAlgorithm;

    function ResolveSingleComponent(const Name: string; out ResolvedId: TObjectId): Boolean;
    function StepParent(const CommitId: TObjectId; ParentIndex: Integer; out ParentId: TObjectId): Boolean;
    function StepAncestor(const CommitId: TObjectId; Generations: Integer; out AncestorId: TObjectId): Boolean;
  public
    constructor Create(ARefMgr: TRefManager; AReflogMgr: TReflogManager;
                       AODB: TObjectDatabase; Algo: THashAlgorithm = haSHA1);

    { Resolve a single revision expression (e.g. "HEAD~2^", "main@[1]", "abcd123") }
    function Resolve(const RevExpr: string; out ResolvedId: TObjectId): Boolean;

    { Parse range expression (e.g. "main..feature" or "main...feature") }
    function ParseRange(const RangeExpr: string;
                        out IncludeIds, ExcludeIds: TObjectIdArray): Boolean;
  end;

implementation

constructor TRevisionParser.Create(ARefMgr: TRefManager; AReflogMgr: TReflogManager;
                                   AODB: TObjectDatabase; Algo: THashAlgorithm);
begin
  inherited Create;
  FRefMgr := ARefMgr;
  FReflogMgr := AReflogMgr;
  FODB := AODB;
  FAlgo := Algo;
end;

function TRevisionParser.StepParent(const CommitId: TObjectId; ParentIndex: Integer; out ParentId: TObjectId): Boolean;
var
  Obj: TAnvilObject;
  Commit: TCommitObject;
begin
  Result := False;
  ParentId := NullObjectId;

  Obj := FODB.ReadObject(CommitId);
  if not Assigned(Obj) then Exit;
  if not (Obj is TCommitObject) then
  begin
    Obj.Free;
    Exit;
  end;

  Commit := TCommitObject(Obj);
  try
    if (ParentIndex >= 1) and (ParentIndex <= Length(Commit.ParentIds)) then
    begin
      ParentId := Commit.ParentIds[ParentIndex - 1];
      Result := True;
    end;
  finally
    Commit.Free;
  end;
end;

function TRevisionParser.StepAncestor(const CommitId: TObjectId; Generations: Integer; out AncestorId: TObjectId): Boolean;
var
  CurrId, NextId: TObjectId;
  I: Integer;
begin
  CurrId := CommitId;
  for I := 1 to Generations do
  begin
    if not StepParent(CurrId, 1, NextId) then
    begin
      AncestorId := NullObjectId;
      Exit(False);
    end;
    CurrId := NextId;
  end;
  AncestorId := CurrId;
  Result := True;
end;

function TRevisionParser.ResolveSingleComponent(const Name: string; out ResolvedId: TObjectId): Boolean;
var
  HexId: TObjectId;
  FullId: TObjectId;
begin
  Result := False;
  ResolvedId := NullObjectId;
  if Name = '' then Exit;

  { 1. Direct or symbolic reference resolution via RefManager }
  if FRefMgr.Resolve(Name, ResolvedId) then
    Exit(True);

  { 2. Full hexadecimal object ID }
  if TryHexToObjectId(Name, HexId, FAlgo) then
  begin
    if FODB.Exists(HexId) then
    begin
      ResolvedId := HexId;
      Exit(True);
    end;
  end;

  { 3. Short prefix hexadecimal lookup in ODB (minimum 4 hex chars) }
  if Length(Name) >= 4 then
  begin
    if FODB.FindObjectByPrefix(Name, FullId) then
    begin
      ResolvedId := FullId;
      Exit(True);
    end;
  end;
end;

function TRevisionParser.Resolve(const RevExpr: string; out ResolvedId: TObjectId): Boolean;
var
  S: string;
  PosAt, PosTilde, PosCaret: Integer;
  BasePart, ModifierPart: string;
  CurrentId, NextId: TObjectId;
  I, Num: Integer;
  AtNum: Integer;
  ReflogEnt: TReflogEntry;
begin
  Result := False;
  ResolvedId := NullObjectId;
  S := Trim(RevExpr);
  if S = '' then Exit;

  { 1. Check reflog syntax: Name@[N] }
  PosAt := Pos('@{', S);
  if (PosAt > 0) and (S[Length(S)] = '}') then
  begin
    BasePart := Copy(S, 1, PosAt - 1);
    ModifierPart := Copy(S, PosAt + 2, Length(S) - PosAt - 2);
    if TryStrToInt(ModifierPart, AtNum) then
    begin
      if Assigned(FReflogMgr) then
      begin
        { Try exact name first, then refs/heads/ prefix }
        if FReflogMgr.ReadRelative(BasePart, AtNum, ReflogEnt) then
        begin
          ResolvedId := ReflogEnt.NewId;
          Exit(True);
        end;
        if (Pos('refs/', BasePart) = 0) and FReflogMgr.ReadRelative('refs/heads/' + BasePart, AtNum, ReflogEnt) then
        begin
          ResolvedId := ReflogEnt.NewId;
          Exit(True);
        end;
      end;
    end;
  end;

  { 2. Separate base symbol from ~ and ^ modifiers }
  I := 1;
  while (I <= Length(S)) and (S[I] <> '~') and (S[I] <> '^') do
    Inc(I);

  BasePart := Copy(S, 1, I - 1);
  if BasePart = '' then
    BasePart := 'HEAD'; { e.g. "~2" implies "HEAD~2" }

  if not ResolveSingleComponent(BasePart, CurrentId) then
    Exit(False);

  { Process sequential ~ and ^ modifiers }
  while I <= Length(S) do
  begin
    if S[I] = '~' then
    begin
      Inc(I);
      Num := 0;
      while (I <= Length(S)) and (S[I] >= '0') and (S[I] <= '9') do
      begin
        Num := Num * 10 + (Ord(S[I]) - Ord('0'));
        Inc(I);
      end;
      if Num = 0 then Num := 1;

      if not StepAncestor(CurrentId, Num, NextId) then
        Exit(False);
      CurrentId := NextId;
    end
    else if S[I] = '^' then
    begin
      Inc(I);
      Num := 0;
      while (I <= Length(S)) and (S[I] >= '0') and (S[I] <= '9') do
      begin
        Num := Num * 10 + (Ord(S[I]) - Ord('0'));
        Inc(I);
      end;
      if Num = 0 then Num := 1;

      if not StepParent(CurrentId, Num, NextId) then
        Exit(False);
      CurrentId := NextId;
    end
    else
      Exit(False);
  end;

  ResolvedId := CurrentId;
  Result := True;
end;

function TRevisionParser.ParseRange(const RangeExpr: string;
                                   out IncludeIds, ExcludeIds: TObjectIdArray): Boolean;
var
  TwoDotPos, ThreeDotPos: Integer;
  LeftStr, RightStr: string;
  LeftId, RightId: TObjectId;
begin
  SetLength(IncludeIds, 0);
  SetLength(ExcludeIds, 0);
  Result := False;

  ThreeDotPos := Pos('...', RangeExpr);
  if ThreeDotPos > 0 then
  begin
    { Symmetric difference: REV1...REV2 }
    LeftStr := Copy(RangeExpr, 1, ThreeDotPos - 1);
    RightStr := Copy(RangeExpr, ThreeDotPos + 3, Length(RangeExpr) - ThreeDotPos - 2);

    if LeftStr = '' then LeftStr := 'HEAD';
    if RightStr = '' then RightStr := 'HEAD';

    if not Resolve(LeftStr, LeftId) or not Resolve(RightStr, RightId) then
      Exit(False);

    SetLength(IncludeIds, 2);
    IncludeIds[0] := LeftId;
    IncludeIds[1] := RightId;
    Result := True;
    Exit;
  end;

  TwoDotPos := Pos('..', RangeExpr);
  if TwoDotPos > 0 then
  begin
    { Range: REV1..REV2 }
    LeftStr := Copy(RangeExpr, 1, TwoDotPos - 1);
    RightStr := Copy(RangeExpr, TwoDotPos + 2, Length(RangeExpr) - TwoDotPos - 1);

    if LeftStr = '' then LeftStr := 'HEAD';
    if RightStr = '' then RightStr := 'HEAD';

    if not Resolve(LeftStr, LeftId) or not Resolve(RightStr, RightId) then
      Exit(False);

    SetLength(ExcludeIds, 1);
    ExcludeIds[0] := LeftId;

    SetLength(IncludeIds, 1);
    IncludeIds[0] := RightId;
    Result := True;
    Exit;
  end;

  { Single revision }
  if Resolve(RangeExpr, RightId) then
  begin
    SetLength(IncludeIds, 1);
    IncludeIds[0] := RightId;
    Result := True;
  end;
end;

end.
