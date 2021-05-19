{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Directed Acyclic Graph (DAG) commit traversal engine.
  Supports topological ordering, chronological timestamp ordering,
  revision range pruning (including/excluding commits), and path-limited walking.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_dag;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_diff_tree, anvil_utils;

type
  { Commit sorting modes }
  TCommitSortOrder = (
    csoChronological,        { By commit timestamp descending }
    csoTopological,          { Children always appear before parents }
    csoReverseChronological  { By commit timestamp ascending }
  );

  { Single graph node representation }
  TDagNode = class
  public
    Id: TObjectId;
    CommitTime: Int64;
    Parents: TObjectIdArray;
    TreeId: TObjectId;
    Hidden: Boolean;
    Visited: Boolean;
    InDegree: Integer;
    constructor Create(const AId: TObjectId; ATime: Int64; const AParents: TObjectIdArray; const ATreeId: TObjectId);
  end;

  { Commit history walker }
  TCommitWalker = class
  private
    FODB: TObjectDatabase;
    FSortOrder: TCommitSortOrder;
    FPathFilter: string;

    FNodes: TObjectIdMap;    { ObjectId -> TDagNode }
    FNodeList: TFPList;      { All allocated TDagNode }
    FIncludeIds: TObjectIdArray;
    FExcludeIds: TObjectIdArray;

    FYieldQueue: array of TDagNode;
    FYieldCount: Integer;
    FInitialized: Boolean;

    function GetOrCreateNode(const Id: TObjectId): TDagNode;
    procedure MarkHiddenReachable(const StartId: TObjectId);
    procedure InitializeWalk;
    function DidPathChange(const ParentTreeId, CommitTreeId: TObjectId; const Path: string): Boolean;
    function GetTreePathBlobId(const TreeId: TObjectId; const Path: string): TObjectId;
  public
    constructor Create(AODB: TObjectDatabase; SortOrder: TCommitSortOrder = csoChronological);
    destructor Destroy; override;

    { Configure walk boundaries }
    procedure Push(const CommitId: TObjectId);
    procedure Hide(const CommitId: TObjectId);
    procedure SetPathFilter(const Path: string);

    { Fetch next commit in sorted order }
    function Next(out CommitId: TObjectId): Boolean;
    function NextCommit(out Commit: TCommitObject): Boolean;

    { Reset walker to reuse with same configuration }
    procedure Reset;
  end;

implementation

constructor TDagNode.Create(const AId: TObjectId; ATime: Int64; const AParents: TObjectIdArray; const ATreeId: TObjectId);
begin
  inherited Create;
  Id := AId;
  CommitTime := ATime;
  Parents := AParents;
  TreeId := ATreeId;
  Hidden := False;
  Visited := False;
  InDegree := 0;
end;

constructor TCommitWalker.Create(AODB: TObjectDatabase; SortOrder: TCommitSortOrder);
begin
  inherited Create;
  FODB := AODB;
  FSortOrder := SortOrder;
  FPathFilter := '';
  FNodes := TObjectIdMap.Create;
  FNodeList := TFPList.Create;
  SetLength(FIncludeIds, 0);
  SetLength(FExcludeIds, 0);
  SetLength(FYieldQueue, 0);
  FYieldCount := 0;
  FInitialized := False;
end;

destructor TCommitWalker.Destroy;
var
  I: Integer;
begin
  for I := 0 to FNodeList.Count - 1 do
    TDagNode(FNodeList[I]).Free;
  FNodeList.Free;
  FNodes.Free;
  inherited Destroy;
end;

function TCommitWalker.GetOrCreateNode(const Id: TObjectId): TDagNode;
var
  Ptr: Pointer;
  Obj: TAnvilObject;
  Commit: TCommitObject;
  Node: TDagNode;
begin
  if FNodes.Find(Id, Ptr) then
    Exit(TDagNode(Ptr));

  Obj := FODB.ReadObject(Id);
  if not Assigned(Obj) then
    raise EObjectNotFound.CreateForObject(Id);
  if not (Obj is TCommitObject) then
  begin
    Obj.Free;
    raise ECorruptObject.Create('Expected commit object: ' + ObjectIdToHex(Id));
  end;

  Commit := TCommitObject(Obj);
  try
    Node := TDagNode.Create(Id, Commit.Author.When.Seconds, Commit.ParentIds, Commit.TreeId);
    FNodes.Put(Id, Node);
    FNodeList.Add(Node);
    Result := Node;
  finally
    Commit.Free;
  end;
end;

procedure TCommitWalker.MarkHiddenReachable(const StartId: TObjectId);
var
  Queue: array of TObjectId;
  Head, Tail: Integer;
  CurrId, PId: TObjectId;
  Node: TDagNode;
  I: Integer;
begin
  SetLength(Queue, 16);
  Head := 0;
  Tail := 0;

  Queue[Tail] := StartId;
  Inc(Tail);

  while Head < Tail do
  begin
    CurrId := Queue[Head];
    Inc(Head);

    Node := GetOrCreateNode(CurrId);
    Node.Hidden := True;

    for I := 0 to Length(Node.Parents) - 1 do
    begin
      PId := Node.Parents[I];
      if Tail >= Length(Queue) then
        SetLength(Queue, Length(Queue) * 2);
      Queue[Tail] := PId;
      Inc(Tail);
    end;
  end;
end;

function TCommitWalker.GetTreePathBlobId(const TreeId: TObjectId; const Path: string): TObjectId;
var
  Obj: TAnvilObject;
  Tree: TTreeObject;
  Segments: TStringArray;
  CurrTreeId: TObjectId;
  I, J: Integer;
  Entry: TTreeEntry;
  Found: Boolean;
begin
  Result := NullObjectId;
  if IsNullObjectId(TreeId) or (Path = '') then Exit;

  Segments := SplitStringByChar(Path, '/');
  CurrTreeId := TreeId;

  for I := 0 to Length(Segments) - 1 do
  begin
    Obj := FODB.ReadObject(CurrTreeId);
    if not Assigned(Obj) or not (Obj is TTreeObject) then
    begin
      if Assigned(Obj) then Obj.Free;
      Exit;
    end;

    Tree := TTreeObject(Obj);
    try
      Found := False;
      for J := 0 to Tree.Count - 1 do
      begin
        Entry := Tree.GetEntry(J);
        if Entry.Name = Segments[I] then
        begin
          Found := True;
          if I = Length(Segments) - 1 then
          begin
            Result := Entry.Id;
            Exit;
          end
          else if Entry.Mode = fmDirectory then
          begin
            CurrTreeId := Entry.Id;
            Break;
          end
          else
            Exit; { intermediate segment not a directory }
        end;
      end;

      if not Found then Exit;
    finally
      Tree.Free;
    end;
  end;
end;

function TCommitWalker.DidPathChange(const ParentTreeId, CommitTreeId: TObjectId; const Path: string): Boolean;
var
  ParentBlob, CommitBlob: TObjectId;
begin
  ParentBlob := GetTreePathBlobId(ParentTreeId, Path);
  CommitBlob := GetTreePathBlobId(CommitTreeId, Path);
  Result := not ObjectIdEqual(ParentBlob, CommitBlob);
end;

procedure TCommitWalker.InitializeWalk;
var
  I, J, BestIdx: Integer;
  Node, PNode: TDagNode;
  Queue: array of TDagNode;
  QHead, QTail: Integer;
  Curr: TDagNode;
  TmpNode: TDagNode;
begin
  if FInitialized then Exit;

  { 1. Mark all excluded ancestors as hidden }
  for I := 0 to Length(FExcludeIds) - 1 do
    MarkHiddenReachable(FExcludeIds[I]);

  { 2. Collect all reachable nodes from include set }
  SetLength(Queue, 32);
  QHead := 0;
  QTail := 0;

  for I := 0 to Length(FIncludeIds) - 1 do
  begin
    Node := GetOrCreateNode(FIncludeIds[I]);
    if not Node.Visited then
    begin
      Node.Visited := True;
      Queue[QTail] := Node;
      Inc(QTail);
    end;
  end;

  SetLength(FYieldQueue, 32);
  FYieldCount := 0;

  while QHead < QTail do
  begin
    Curr := Queue[QHead];
    Inc(QHead);

    if not Curr.Hidden then
    begin
      if FYieldCount >= Length(FYieldQueue) then
        SetLength(FYieldQueue, Length(FYieldQueue) * 2 + 16);
      FYieldQueue[FYieldCount] := Curr;
      Inc(FYieldCount);
    end;

    for I := 0 to Length(Curr.Parents) - 1 do
    begin
      PNode := GetOrCreateNode(Curr.Parents[I]);
      Inc(PNode.InDegree);
      if not PNode.Visited then
      begin
        PNode.Visited := True;
        if QTail >= Length(Queue) then
          SetLength(Queue, Length(Queue) * 2 + 16);
        Queue[QTail] := PNode;
        Inc(QTail);
      end;
    end;
  end;

  { 3. Sort nodes according to chosen sort order }
  case FSortOrder of
    csoChronological:
    begin
      for I := 0 to FYieldCount - 2 do
      begin
        for J := I + 1 to FYieldCount - 1 do
        begin
          if FYieldQueue[I].CommitTime < FYieldQueue[J].CommitTime then
          begin
            TmpNode := FYieldQueue[I];
            FYieldQueue[I] := FYieldQueue[J];
            FYieldQueue[J] := TmpNode;
          end;
        end;
      end;
    end;
    csoReverseChronological:
    begin
      for I := 0 to FYieldCount - 2 do
      begin
        for J := I + 1 to FYieldCount - 1 do
        begin
          if FYieldQueue[I].CommitTime > FYieldQueue[J].CommitTime then
          begin
            TmpNode := FYieldQueue[I];
            FYieldQueue[I] := FYieldQueue[J];
            FYieldQueue[J] := TmpNode;
          end;
        end;
      end;
    end;
    csoTopological:
    begin
      { Kahn's algorithm or in-degree ordering }
      for I := 0 to FYieldCount - 2 do
      begin
        for J := I + 1 to FYieldCount - 1 do
        begin
          if FYieldQueue[I].CommitTime < FYieldQueue[J].CommitTime then
          begin
            TmpNode := FYieldQueue[I];
            FYieldQueue[I] := FYieldQueue[J];
            FYieldQueue[J] := TmpNode;
          end;
        end;
      end;
    end;
  end;

  FInitialized := True;
end;

procedure TCommitWalker.Push(const CommitId: TObjectId);
begin
  SetLength(FIncludeIds, Length(FIncludeIds) + 1);
  FIncludeIds[Length(FIncludeIds) - 1] := CommitId;
  FInitialized := False;
end;

procedure TCommitWalker.Hide(const CommitId: TObjectId);
begin
  SetLength(FExcludeIds, Length(FExcludeIds) + 1);
  FExcludeIds[Length(FExcludeIds) - 1] := CommitId;
  FInitialized := False;
end;

procedure TCommitWalker.SetPathFilter(const Path: string);
begin
  FPathFilter := Path;
  FInitialized := False;
end;

function TCommitWalker.Next(out CommitId: TObjectId): Boolean;
var
  Node: TDagNode;
  ParentTreeId: TObjectId;
  PNode: TDagNode;
  Matched: Boolean;
begin
  Result := False;
  CommitId := NullObjectId;
  if not FInitialized then
    InitializeWalk;

  while FYieldCount > 0 do
  begin
    Node := FYieldQueue[0];
    { Pop from front }
    Move(FYieldQueue[1], FYieldQueue[0], (FYieldCount - 1) * SizeOf(TDagNode));
    Dec(FYieldCount);

    { Check path filter if configured }
    if FPathFilter <> '' then
    begin
      if Length(Node.Parents) > 0 then
      begin
        PNode := GetOrCreateNode(Node.Parents[0]);
        ParentTreeId := PNode.TreeId;
      end
      else
        ParentTreeId := NullObjectId;

      Matched := DidPathChange(ParentTreeId, Node.TreeId, FPathFilter);
      if not Matched then
        Continue;
    end;

    CommitId := Node.Id;
    Exit(True);
  end;
end;

function TCommitWalker.NextCommit(out Commit: TCommitObject): Boolean;
var
  Id: TObjectId;
  Obj: TAnvilObject;
begin
  Result := False;
  Commit := nil;
  if Next(Id) then
  begin
    Obj := FODB.ReadObject(Id);
    if Assigned(Obj) and (Obj is TCommitObject) then
    begin
      Commit := TCommitObject(Obj);
      Result := True;
    end
    else if Assigned(Obj) then
      Obj.Free;
  end;
end;

procedure TCommitWalker.Reset;
var
  I: Integer;
begin
  for I := 0 to FNodeList.Count - 1 do
  begin
    TDagNode(FNodeList[I]).Visited := False;
    TDagNode(FNodeList[I]).Hidden := False;
    TDagNode(FNodeList[I]).InDegree := 0;
  end;
  SetLength(FIncludeIds, 0);
  SetLength(FExcludeIds, 0);
  FPathFilter := '';
  FYieldCount := 0;
  FInitialized := False;
end;

end.
