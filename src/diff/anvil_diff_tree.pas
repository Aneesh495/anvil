{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Tree-to-tree recursive difference engine. Traverses hierarchical
  directory trees, performing fast-path subtree hash comparison and
  generating comprehensive structural deltas (added, deleted, modified).
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_diff_tree;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, anvil_types, anvil_errors, anvil_utils, anvil_object, anvil_odb;

type
  { File change status }
  TDeltaStatus = (
    dsUnmodified,
    dsAdded,
    dsDeleted,
    dsModified,
    dsTypeChanged,
    dsRenamed,
    dsCopied
  );

  { Single file tree delta }
  TTreeDelta = record
    OldPath: string;
    NewPath: string;
    OldId: TObjectId;
    NewId: TObjectId;
    OldMode: TFileMode;
    NewMode: TFileMode;
    Status: TDeltaStatus;
    Similarity: Integer; { 0..100 }
  end;
  TTreeDeltaArray = array of TTreeDelta;

  { Tree difference engine }
  TTreeDiff = class
  private
    FOdb: TObjectDatabase;
    FDeltas: TTreeDeltaArray;
    FCount: Integer;
    procedure EnsureCapacity(MinCap: Integer);
    procedure AddDelta(const AOldPath, ANewPath: string; const AOldId, ANewId: TObjectId;
                       AOldMode, ANewMode: TFileMode; AStatus: TDeltaStatus);
    procedure DiffTreesRecursive(const OldTreeId, NewTreeId: TObjectId; const PathPrefix: string);
    procedure EmitEntireTree(const TreeId: TObjectId; const PathPrefix: string; AsAddition: Boolean);
  public
    constructor Create(Odb: TObjectDatabase);
    destructor Destroy; override;
    function Diff(const OldTreeId, NewTreeId: TObjectId): TTreeDeltaArray;
    property Deltas: TTreeDeltaArray read FDeltas;
    property Count: Integer read FCount;
  end;

function DeltaStatusToString(Status: TDeltaStatus): string;
function DeltaStatusToChar(Status: TDeltaStatus): Char;

implementation

function DeltaStatusToString(Status: TDeltaStatus): string;
begin
  case Status of
    dsAdded:       Result := 'added';
    dsDeleted:     Result := 'deleted';
    dsModified:    Result := 'modified';
    dsTypeChanged: Result := 'typechange';
    dsRenamed:     Result := 'renamed';
    dsCopied:      Result := 'copied';
  else
    Result := 'unmodified';
  end;
end;

function DeltaStatusToChar(Status: TDeltaStatus): Char;
begin
  case Status of
    dsAdded:       Result := 'A';
    dsDeleted:     Result := 'D';
    dsModified:    Result := 'M';
    dsTypeChanged: Result := 'T';
    dsRenamed:     Result := 'R';
    dsCopied:      Result := 'C';
  else
    Result := ' ';
  end;
end;

constructor TTreeDiff.Create(Odb: TObjectDatabase);
begin
  inherited Create;
  FOdb := Odb;
  FCount := 0;
  SetLength(FDeltas, 0);
end;

destructor TTreeDiff.Destroy;
begin
  SetLength(FDeltas, 0);
  inherited Destroy;
end;

procedure TTreeDiff.EnsureCapacity(MinCap: Integer);
var
  NewCap: Integer;
begin
  if Length(FDeltas) >= MinCap then
    Exit;
  NewCap := Length(FDeltas) * 2;
  if NewCap < MinCap then
    NewCap := MinCap;
  if NewCap < 16 then
    NewCap := 16;
  SetLength(FDeltas, NewCap);
end;

procedure TTreeDiff.AddDelta(const AOldPath, ANewPath: string; const AOldId, ANewId: TObjectId;
                             AOldMode, ANewMode: TFileMode; AStatus: TDeltaStatus);
begin
  EnsureCapacity(FCount + 1);
  FDeltas[FCount].OldPath := AOldPath;
  FDeltas[FCount].NewPath := ANewPath;
  FDeltas[FCount].OldId := AOldId;
  FDeltas[FCount].NewId := ANewId;
  FDeltas[FCount].OldMode := AOldMode;
  FDeltas[FCount].NewMode := ANewMode;
  FDeltas[FCount].Status := AStatus;
  FDeltas[FCount].Similarity := 0;
  Inc(FCount);
end;

procedure TTreeDiff.EmitEntireTree(const TreeId: TObjectId; const PathPrefix: string; AsAddition: Boolean);
var
  Tree: TTreeObject;
  Entry: TTreeEntry;
  I: Integer;
  FullPath: string;
begin
  if IsNullObjectId(TreeId) then
    Exit;

  Tree := TTreeObject(FOdb.ReadObject(TreeId));
  try
    for I := 0 to Tree.Count - 1 do
    begin
      Entry := Tree.GetEntry(I);
      FullPath := PathPrefix + Entry.Name;

      if Entry.Mode = fmDirectory then
        EmitEntireTree(Entry.Id, FullPath + '/', AsAddition)
      else if AsAddition then
        AddDelta('', FullPath, NullObjectId, Entry.Id, fmNone, Entry.Mode, dsAdded)
      else
        AddDelta(FullPath, '', Entry.Id, NullObjectId, Entry.Mode, fmNone, dsDeleted);
    end;
  finally
    Tree.Free;
  end;
end;

procedure TTreeDiff.DiffTreesRecursive(const OldTreeId, NewTreeId: TObjectId; const PathPrefix: string);
var
  OldTree, NewTree: TTreeObject;
  OldIdx, NewIdx: Integer;
  OldEntry, NewEntry: TTreeEntry;
  Cmp: Integer;
  FullPath: string;
begin
  { Fast path: identical subtree hashes indicate no modifications }
  if ObjectIdEqual(OldTreeId, NewTreeId) then
    Exit;

  if IsNullObjectId(OldTreeId) then
  begin
    EmitEntireTree(NewTreeId, PathPrefix, True);
    Exit;
  end;

  if IsNullObjectId(NewTreeId) then
  begin
    EmitEntireTree(OldTreeId, PathPrefix, False);
    Exit;
  end;

  OldTree := TTreeObject(FOdb.ReadObject(OldTreeId));
  NewTree := TTreeObject(FOdb.ReadObject(NewTreeId));
  try
    OldIdx := 0;
    NewIdx := 0;

    while (OldIdx < OldTree.Count) and (NewIdx < NewTree.Count) do
    begin
      OldEntry := OldTree.GetEntry(OldIdx);
      NewEntry := NewTree.GetEntry(NewIdx);

      Cmp := CompareStr(OldEntry.Name, NewEntry.Name);

      if Cmp = 0 then
      begin
        FullPath := PathPrefix + OldEntry.Name;

        if (OldEntry.Mode = fmDirectory) and (NewEntry.Mode = fmDirectory) then
        begin
          { Recurse into both subdirectories }
          DiffTreesRecursive(OldEntry.Id, NewEntry.Id, FullPath + '/');
        end
        else if (OldEntry.Mode = fmDirectory) <> (NewEntry.Mode = fmDirectory) then
        begin
          { Type changed: directory replaced with file or vice versa }
          if OldEntry.Mode = fmDirectory then
            EmitEntireTree(OldEntry.Id, FullPath + '/', False)
          else
            AddDelta(FullPath, '', OldEntry.Id, NullObjectId, OldEntry.Mode, fmNone, dsDeleted);

          if NewEntry.Mode = fmDirectory then
            EmitEntireTree(NewEntry.Id, FullPath + '/', True)
          else
            AddDelta('', FullPath, NullObjectId, NewEntry.Id, fmNone, NewEntry.Mode, dsAdded);
        end
        else if (not ObjectIdEqual(OldEntry.Id, NewEntry.Id)) or (OldEntry.Mode <> NewEntry.Mode) then
        begin
          { Modified file content or permissions }
          AddDelta(FullPath, FullPath, OldEntry.Id, NewEntry.Id, OldEntry.Mode, NewEntry.Mode, dsModified);
        end;

        Inc(OldIdx);
        Inc(NewIdx);
      end
      else if Cmp < 0 then
      begin
        { OldEntry deleted in NewTree }
        FullPath := PathPrefix + OldEntry.Name;
        if OldEntry.Mode = fmDirectory then
          EmitEntireTree(OldEntry.Id, FullPath + '/', False)
        else
          AddDelta(FullPath, '', OldEntry.Id, NullObjectId, OldEntry.Mode, fmNone, dsDeleted);
        Inc(OldIdx);
      end
      else
      begin
        { NewEntry added in NewTree }
        FullPath := PathPrefix + NewEntry.Name;
        if NewEntry.Mode = fmDirectory then
          EmitEntireTree(NewEntry.Id, FullPath + '/', True)
        else
          AddDelta('', FullPath, NullObjectId, NewEntry.Id, fmNone, NewEntry.Mode, dsAdded);
        Inc(NewIdx);
      end;
    end;

    { Drain remaining deleted entries }
    while OldIdx < OldTree.Count do
    begin
      OldEntry := OldTree.GetEntry(OldIdx);
      FullPath := PathPrefix + OldEntry.Name;
      if OldEntry.Mode = fmDirectory then
        EmitEntireTree(OldEntry.Id, FullPath + '/', False)
      else
        AddDelta(FullPath, '', OldEntry.Id, NullObjectId, OldEntry.Mode, fmNone, dsDeleted);
      Inc(OldIdx);
    end;

    { Drain remaining added entries }
    while NewIdx < NewTree.Count do
    begin
      NewEntry := NewTree.GetEntry(NewIdx);
      FullPath := PathPrefix + NewEntry.Name;
      if NewEntry.Mode = fmDirectory then
        EmitEntireTree(NewEntry.Id, FullPath + '/', True)
      else
        AddDelta('', FullPath, NullObjectId, NewEntry.Id, fmNone, NewEntry.Mode, dsAdded);
      Inc(NewIdx);
    end;

  finally
    OldTree.Free;
    NewTree.Free;
  end;
end;

function TTreeDiff.Diff(const OldTreeId, NewTreeId: TObjectId): TTreeDeltaArray;
begin
  FCount := 0;
  SetLength(FDeltas, 0);
  DiffTreesRecursive(OldTreeId, NewTreeId, '');
  SetLength(FDeltas, FCount);
  Result := FDeltas;
end;

end.
