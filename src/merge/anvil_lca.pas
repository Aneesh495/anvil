{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Lowest Common Ancestor (LCA) and Merge Base resolution algorithm.
  Traverses the commit Directed Acyclic Graph (DAG) using topological
  generation numbering to locate common ancestors and handle criss-cross merges.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_lca;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb;

type
  { Flags for DAG reachability coloring }
  TAncestorFlag = (
    afNone      = 0,
    afParentOne = 1, { Reachable from Commit A }
    afParentTwo = 2, { Reachable from Commit B }
    afCommon    = 3  { Reachable from both A and B }
  );

  { Graph node representation during LCA traversal }
  TLcaNode = class
  public
    Id: TObjectId;
    CommitTime: Int64;
    Parents: TObjectIdArray;
    Flags: Byte;
    constructor Create(const AId: TObjectId; ATime: Int64; const AParents: TObjectIdArray);
  end;

  { Commit LCA finder }
  TLcaFinder = class
  private
    FODB: TObjectDatabase;
    FNodes: TObjectIdMap; { ObjectId -> TLcaNode }
    FNodeList: TFPList;
    function GetOrCreateNode(const Id: TObjectId): TLcaNode;
    function IsDescendantOf(const CandidateId, AncestorId: TObjectId): Boolean;
  public
    constructor Create(AODB: TObjectDatabase);
    destructor Destroy; override;

    { Find all lowest common ancestors (merge bases) }
    function FindMergeBases(const CommitA, CommitB: TObjectId): TObjectIdArray;
    { Find single best merge base (first lowest ancestor) }
    function FindBestMergeBase(const CommitA, CommitB: TObjectId; out BaseId: TObjectId): Boolean;
  end;

implementation

constructor TLcaNode.Create(const AId: TObjectId; ATime: Int64; const AParents: TObjectIdArray);
begin
  inherited Create;
  Id := AId;
  CommitTime := ATime;
  Parents := AParents;
  Flags := Byte(afNone);
end;

constructor TLcaFinder.Create(AODB: TObjectDatabase);
begin
  inherited Create;
  FODB := AODB;
  FNodes := TObjectIdMap.Create;
  FNodeList := TFPList.Create;
end;

destructor TLcaFinder.Destroy;
var
  I: Integer;
begin
  for I := 0 to FNodeList.Count - 1 do
    TLcaNode(FNodeList[I]).Free;
  FNodeList.Free;
  FNodes.Free;
  inherited Destroy;
end;

function TLcaFinder.GetOrCreateNode(const Id: TObjectId): TLcaNode;
var
  Ptr: Pointer;
  Obj: TAnvilObject;
  Commit: TCommitObject;
  Node: TLcaNode;
begin
  if FNodes.Find(Id, Ptr) then
    Exit(TLcaNode(Ptr));

  Obj := FODB.ReadObject(Id);
  if not Assigned(Obj) then
    raise EObjectNotFound.CreateForObject(Id);

  if not (Obj is TCommitObject) then
  begin
    Obj.Free;
    raise ECorruptObject.Create('Object is not a commit: ' + ObjectIdToHex(Id));
  end;

  Commit := TCommitObject(Obj);
  try
    Node := TLcaNode.Create(Id, Commit.Author.When.Seconds, Commit.ParentIds);
    FNodes.Put(Id, Node);
    FNodeList.Add(Node);
    Result := Node;
  finally
    Commit.Free;
  end;
end;

function TLcaFinder.IsDescendantOf(const CandidateId, AncestorId: TObjectId): Boolean;
var
  Queue: array of TObjectId;
  Head, Tail: Integer;
  Visited: TObjectIdSet;
  CurrId, PId: TObjectId;
  Node: TLcaNode;
  I: Integer;
begin
  Result := False;
  if ObjectIdEqual(CandidateId, AncestorId) then
    Exit(True);

  Visited := TObjectIdSet.Create;
  try
    SetLength(Queue, 16);
    Head := 0;
    Tail := 0;

    Queue[Tail] := CandidateId;
    Inc(Tail);
    Visited.Add(CandidateId);

    while Head < Tail do
    begin
      CurrId := Queue[Head];
      Inc(Head);

      Node := GetOrCreateNode(CurrId);
      for I := 0 to Length(Node.Parents) - 1 do
      begin
        PId := Node.Parents[I];
        if ObjectIdEqual(PId, AncestorId) then
          Exit(True);

        if not Visited.Contains(PId) then
        begin
          Visited.Add(PId);
          if Tail >= Length(Queue) then
            SetLength(Queue, Length(Queue) * 2);
          Queue[Tail] := PId;
          Inc(Tail);
        end;
      end;
    end;
  finally
    Visited.Free;
  end;
end;

function TLcaFinder.FindMergeBases(const CommitA, CommitB: TObjectId): TObjectIdArray;
var
  NodeA, NodeB: TLcaNode;
  Queue: array of TLcaNode;
  QCount: Integer;
  Curr, NextNode: TLcaNode;
  I, J, BestIdx: Integer;
  PId: TObjectId;
  Candidates: array of TLcaNode;
  CandCount: Integer;
  IsRedundant: Boolean;
begin
  SetLength(Result, 0);

  if ObjectIdEqual(CommitA, CommitB) then
  begin
    SetLength(Result, 1);
    Result[0] := CommitA;
    Exit;
  end;

  { Reset reachability flags from any previous searches }
  for I := 0 to FNodeList.Count - 1 do
    TLcaNode(FNodeList[I]).Flags := Byte(afNone);

  NodeA := GetOrCreateNode(CommitA);
  NodeB := GetOrCreateNode(CommitB);

  NodeA.Flags := NodeA.Flags or Byte(afParentOne);
  NodeB.Flags := NodeB.Flags or Byte(afParentTwo);

  SetLength(Queue, 2);
  Queue[0] := NodeA;
  Queue[1] := NodeB;
  QCount := 2;

  SetLength(Candidates, 0);
  CandCount := 0;

  { Priority queue search ordered by CommitTime descending }
  while QCount > 0 do
  begin
    BestIdx := 0;
    for I := 1 to QCount - 1 do
    begin
      if Queue[I].CommitTime > Queue[BestIdx].CommitTime then
        BestIdx := I;
    end;

    Curr := Queue[BestIdx];
    Queue[BestIdx] := Queue[QCount - 1];
    Dec(QCount);

    if (Curr.Flags and Byte(afCommon)) = Byte(afCommon) then
    begin
      SetLength(Candidates, CandCount + 1);
      Candidates[CandCount] := Curr;
      Inc(CandCount);
    end;

    for I := 0 to Length(Curr.Parents) - 1 do
    begin
      PId := Curr.Parents[I];
      NextNode := GetOrCreateNode(PId);

      if (NextNode.Flags or Curr.Flags) <> NextNode.Flags then
      begin
        NextNode.Flags := NextNode.Flags or Curr.Flags;

        IsRedundant := False;
        for J := 0 to QCount - 1 do
        begin
          if ObjectIdEqual(Queue[J].Id, NextNode.Id) then
          begin
            IsRedundant := True;
            Break;
          end;
        end;

        if not IsRedundant then
        begin
          if QCount >= Length(Queue) then
            SetLength(Queue, Length(Queue) * 2 + 4);
          Queue[QCount] := NextNode;
          Inc(QCount);
        end;
      end;
    end;
  end;

  { Filter out common ancestors that are ancestors of another candidate }
  for I := 0 to CandCount - 1 do
  begin
    IsRedundant := False;
    for J := 0 to CandCount - 1 do
    begin
      if (I <> J) and IsDescendantOf(Candidates[J].Id, Candidates[I].Id) then
      begin
        IsRedundant := True;
        Break;
      end;
    end;

    if not IsRedundant then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[Length(Result) - 1] := Candidates[I].Id;
    end;
  end;
end;

function TLcaFinder.FindBestMergeBase(const CommitA, CommitB: TObjectId; out BaseId: TObjectId): Boolean;
var
  Bases: TObjectIdArray;
begin
  Bases := FindMergeBases(CommitA, CommitB);
  if Length(Bases) > 0 then
  begin
    BaseId := Bases[0];
    Result := True;
  end
  else
  begin
    BaseId := NullObjectId;
    Result := False;
  end;
end;

end.
