{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Three-way recursive tree merge engine.
  Traverses ancestor, local, and remote trees simultaneously, resolving clean
  file modifications, detecting delete/modify and type conflicts, performing
  3-way line merges, and staging conflicts into index stages 1, 2, and 3.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_merge_tree;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_index, anvil_index_entry, anvil_merge3, anvil_utils;

type
  { Summary report of tree merge execution }
  TMergeTreeSummary = record
    Success: Boolean;
    ConflictCount: Integer;
    CleanMergeCount: Integer;
    ConflictedPaths: TStringArray;
    CleanMergedPaths: TStringArray;
    ResultTreeId: TObjectId;
  end;

  { Three-way tree merger }
  TTreeMerger = class
  private
    FODB: TObjectDatabase;
    FIndex: TIndex;
    FBaseTreeId: TObjectId;
    FOursTreeId: TObjectId;
    FTheirsTreeId: TObjectId;
    FLabelOurs: string;
    FLabelTheirs: string;

    type
      TPathMap = class
      private
        FKeys: TStringArray;
        FBaseEntries: array of TTreeEntry;
        FOursEntries: array of TTreeEntry;
        FTheirsEntries: array of TTreeEntry;
        FHasBase: array of Boolean;
        FHasOurs: array of Boolean;
        FHasTheirs: array of Boolean;
      public
        constructor Create;
        destructor Destroy; override;
        procedure AddEntry(const FullPath: string; const Entry: TTreeEntry; Side: Integer);
        function Count: Integer;
        function GetPath(Idx: Integer): string;
        function HasBase(Idx: Integer): Boolean;
        function HasOurs(Idx: Integer): Boolean;
        function HasTheirs(Idx: Integer): Boolean;
        function GetBase(Idx: Integer): TTreeEntry;
        function GetOurs(Idx: Integer): TTreeEntry;
        function GetTheirs(Idx: Integer): TTreeEntry;
      end;

    function ReadBlobString(const Id: TObjectId): string;
    function WriteBlobString(const Content: string): TObjectId;
    procedure PopulateFlattenedMap(Map: TPathMap; const Prefix: string; const TreeId: TObjectId; Side: Integer);
  public
    constructor Create(AODB: TObjectDatabase; AIndex: TIndex;
                       const BaseTreeId, OursTreeId, TheirsTreeId: TObjectId;
                       const LabelOurs: string = 'ours';
                       const LabelTheirs: string = 'theirs');

    function Execute: TMergeTreeSummary;
  end;

function MergeTrees(AODB: TObjectDatabase; AIndex: TIndex;
                    const BaseTreeId, OursTreeId, TheirsTreeId: TObjectId;
                    const LabelOurs: string = 'ours';
                    const LabelTheirs: string = 'theirs'): TMergeTreeSummary;

implementation

{ TTreeMerger.TPathMap implementation }

constructor TTreeMerger.TPathMap.Create;
begin
  inherited Create;
  SetLength(FKeys, 0);
  SetLength(FBaseEntries, 0);
  SetLength(FOursEntries, 0);
  SetLength(FTheirsEntries, 0);
  SetLength(FHasBase, 0);
  SetLength(FHasOurs, 0);
  SetLength(FHasTheirs, 0);
end;

destructor TTreeMerger.TPathMap.Destroy;
begin
  inherited Destroy;
end;

function TTreeMerger.TPathMap.Count: Integer;
begin
  Result := Length(FKeys);
end;

function TTreeMerger.TPathMap.GetPath(Idx: Integer): string;
begin
  Result := FKeys[Idx];
end;

function TTreeMerger.TPathMap.HasBase(Idx: Integer): Boolean;
begin
  Result := FHasBase[Idx];
end;

function TTreeMerger.TPathMap.HasOurs(Idx: Integer): Boolean;
begin
  Result := FHasOurs[Idx];
end;

function TTreeMerger.TPathMap.HasTheirs(Idx: Integer): Boolean;
begin
  Result := FHasTheirs[Idx];
end;

function TTreeMerger.TPathMap.GetBase(Idx: Integer): TTreeEntry;
begin
  Result := FBaseEntries[Idx];
end;

function TTreeMerger.TPathMap.GetOurs(Idx: Integer): TTreeEntry;
begin
  Result := FOursEntries[Idx];
end;

function TTreeMerger.TPathMap.GetTheirs(Idx: Integer): TTreeEntry;
begin
  Result := FTheirsEntries[Idx];
end;

procedure TTreeMerger.TPathMap.AddEntry(const FullPath: string; const Entry: TTreeEntry; Side: Integer);
var
  J, FoundIdx: Integer;
begin
  FoundIdx := -1;
  for J := 0 to Length(FKeys) - 1 do
  begin
    if FKeys[J] = FullPath then
    begin
      FoundIdx := J;
      Break;
    end;
  end;

  if FoundIdx = -1 then
  begin
    FoundIdx := Length(FKeys);
    SetLength(FKeys, FoundIdx + 1);
    SetLength(FBaseEntries, FoundIdx + 1);
    SetLength(FOursEntries, FoundIdx + 1);
    SetLength(FTheirsEntries, FoundIdx + 1);
    SetLength(FHasBase, FoundIdx + 1);
    SetLength(FHasOurs, FoundIdx + 1);
    SetLength(FHasTheirs, FoundIdx + 1);

    FKeys[FoundIdx] := FullPath;
    FHasBase[FoundIdx] := False;
    FHasOurs[FoundIdx] := False;
    FHasTheirs[FoundIdx] := False;
  end;

  case Side of
    1: { Base }
    begin
      FBaseEntries[FoundIdx] := Entry;
      FHasBase[FoundIdx] := True;
    end;
    2: { Ours }
    begin
      FOursEntries[FoundIdx] := Entry;
      FHasOurs[FoundIdx] := True;
    end;
    3: { Theirs }
    begin
      FTheirsEntries[FoundIdx] := Entry;
      FHasTheirs[FoundIdx] := True;
    end;
  end;
end;

{ TTreeMerger implementation }

constructor TTreeMerger.Create(AODB: TObjectDatabase; AIndex: TIndex;
                               const BaseTreeId, OursTreeId, TheirsTreeId: TObjectId;
                               const LabelOurs, LabelTheirs: string);
begin
  inherited Create;
  FODB := AODB;
  FIndex := AIndex;
  FBaseTreeId := BaseTreeId;
  FOursTreeId := OursTreeId;
  FTheirsTreeId := TheirsTreeId;
  FLabelOurs := LabelOurs;
  FLabelTheirs := LabelTheirs;
end;

function TTreeMerger.ReadBlobString(const Id: TObjectId): string;
var
  Obj: TAnvilObject;
  Blob: TBlobObject;
begin
  Obj := FODB.ReadObject(Id);
  if not Assigned(Obj) then
    Exit('');
  if Obj is TBlobObject then
  begin
    Blob := TBlobObject(Obj);
    Result := Blob.AsString;
    Blob.Free;
  end
  else
  begin
    Obj.Free;
    Result := '';
  end;
end;

function TTreeMerger.WriteBlobString(const Content: string): TObjectId;
var
  Blob: TBlobObject;
begin
  Blob := TBlobObject.CreateWithString(Content);
  try
    Result := Blob.ObjectId;
    FODB.WriteObject(Blob);
  finally
    Blob.Free;
  end;
end;

procedure TTreeMerger.PopulateFlattenedMap(Map: TPathMap; const Prefix: string; const TreeId: TObjectId; Side: Integer);
var
  Obj: TAnvilObject;
  Tree: TTreeObject;
  I: Integer;
  Entry: TTreeEntry;
  ChildPrefix: string;
begin
  if IsNullObjectId(TreeId) then
    Exit;

  Obj := FODB.ReadObject(TreeId);
  if not Assigned(Obj) then
    Exit;
  if not (Obj is TTreeObject) then
  begin
    Obj.Free;
    Exit;
  end;

  Tree := TTreeObject(Obj);
  try
    for I := 0 to Tree.Count - 1 do
    begin
      Entry := Tree.GetEntry(I);
      if Prefix <> '' then
        ChildPrefix := Prefix + '/' + Entry.Name
      else
        ChildPrefix := Entry.Name;

      if Entry.Mode = fmDirectory then
      begin
        { Recursively flatten subdirectories }
        PopulateFlattenedMap(Map, ChildPrefix, Entry.Id, Side);
      end
      else
      begin
        { Add leaf entry }
        Map.AddEntry(ChildPrefix, Entry, Side);
      end;
    end;
  finally
    Tree.Free;
  end;
end;

function TTreeMerger.Execute: TMergeTreeSummary;
var
  Map: TPathMap;
  I: Integer;
  Path: string;
  HasB, HasO, HasT: Boolean;
  EntryB, EntryO, EntryT: TTreeEntry;
  IdxEntry: TIndexEntry;
  BaseContent, OursContent, TheirsContent: string;
  MergeRes: TMerge3Result;
  MergedBlobId: TObjectId;
begin
  Result.Success := True;
  Result.ConflictCount := 0;
  Result.CleanMergeCount := 0;
  SetLength(Result.ConflictedPaths, 0);
  SetLength(Result.CleanMergedPaths, 0);
  Result.ResultTreeId := NullObjectId;

  { Clear index to stage merge results }
  FIndex.Clear;

  Map := TPathMap.Create;
  try
    PopulateFlattenedMap(Map, '', FBaseTreeId, 1);
    PopulateFlattenedMap(Map, '', FOursTreeId, 2);
    PopulateFlattenedMap(Map, '', FTheirsTreeId, 3);

    for I := 0 to Map.Count - 1 do
    begin
      Path := Map.GetPath(I);
      HasB := Map.HasBase(I);
      HasO := Map.HasOurs(I);
      HasT := Map.HasTheirs(I);

      if HasB then EntryB := Map.GetBase(I);
      if HasO then EntryO := Map.GetOurs(I);
      if HasT then EntryT := Map.GetTheirs(I);

      { Case 1: Untouched on both sides }
      if HasB and HasO and HasT and
         ObjectIdEqual(EntryB.Id, EntryO.Id) and ObjectIdEqual(EntryB.Id, EntryT.Id) then
      begin
        IdxEntry := MakeIndexEntry(Path, EntryO.Id, EntryO.Mode, 0, 0);
        FIndex.Add(IdxEntry);
      end
      { Case 2: Untouched by ours, changed or deleted by theirs }
      else if HasB and HasO and ObjectIdEqual(EntryB.Id, EntryO.Id) then
      begin
        if HasT then
        begin
          { Take their modification }
          IdxEntry := MakeIndexEntry(Path, EntryT.Id, EntryT.Mode, 0, 0);
          FIndex.Add(IdxEntry);
          Inc(Result.CleanMergeCount);
          SetLength(Result.CleanMergedPaths, Length(Result.CleanMergedPaths) + 1);
          Result.CleanMergedPaths[Length(Result.CleanMergedPaths) - 1] := Path;
        end
        else
        begin
          { Take their deletion: do not add to index }
          Inc(Result.CleanMergeCount);
          SetLength(Result.CleanMergedPaths, Length(Result.CleanMergedPaths) + 1);
          Result.CleanMergedPaths[Length(Result.CleanMergedPaths) - 1] := Path;
        end;
      end
      { Case 3: Untouched by theirs, changed or deleted by ours }
      else if HasB and HasT and ObjectIdEqual(EntryB.Id, EntryT.Id) then
      begin
        if HasO then
        begin
          { Keep our modification }
          IdxEntry := MakeIndexEntry(Path, EntryO.Id, EntryO.Mode, 0, 0);
          FIndex.Add(IdxEntry);
          Inc(Result.CleanMergeCount);
          SetLength(Result.CleanMergedPaths, Length(Result.CleanMergedPaths) + 1);
          Result.CleanMergedPaths[Length(Result.CleanMergedPaths) - 1] := Path;
        end
        else
        begin
          { Keep our deletion: do not add to index }
          Inc(Result.CleanMergeCount);
          SetLength(Result.CleanMergedPaths, Length(Result.CleanMergedPaths) + 1);
          Result.CleanMergedPaths[Length(Result.CleanMergedPaths) - 1] := Path;
        end;
      end
      { Case 4: Added on one side only (no base) }
      else if (not HasB) and HasO and (not HasT) then
      begin
        { Added on ours: keep }
        IdxEntry := MakeIndexEntry(Path, EntryO.Id, EntryO.Mode, 0, 0);
        FIndex.Add(IdxEntry);
      end
      else if (not HasB) and (not HasO) and HasT then
      begin
        { Added on theirs: keep }
        IdxEntry := MakeIndexEntry(Path, EntryT.Id, EntryT.Mode, 0, 0);
        FIndex.Add(IdxEntry);
        Inc(Result.CleanMergeCount);
        SetLength(Result.CleanMergedPaths, Length(Result.CleanMergedPaths) + 1);
        Result.CleanMergedPaths[Length(Result.CleanMergedPaths) - 1] := Path;
      end
      { Case 5: Added on both sides identically (no base) }
      else if (not HasB) and HasO and HasT and ObjectIdEqual(EntryO.Id, EntryT.Id) then
      begin
        IdxEntry := MakeIndexEntry(Path, EntryO.Id, EntryO.Mode, 0, 0);
        FIndex.Add(IdxEntry);
      end
      { Case 6: Both sides modified or added differently }
      else
      begin
        { Check for delete vs modify conflict }
        if (HasO and (not HasT)) or ((not HasO) and HasT) then
        begin
          { Delete/Modify conflict! Stage conflict entries }
          Inc(Result.ConflictCount);
          Result.Success := False;
          SetLength(Result.ConflictedPaths, Length(Result.ConflictedPaths) + 1);
          Result.ConflictedPaths[Length(Result.ConflictedPaths) - 1] := Path;

          if HasB then
            FIndex.Add(MakeIndexEntry(Path, EntryB.Id, EntryB.Mode, 0, 1));
          if HasO then
            FIndex.Add(MakeIndexEntry(Path, EntryO.Id, EntryO.Mode, 0, 2));
          if HasT then
            FIndex.Add(MakeIndexEntry(Path, EntryT.Id, EntryT.Mode, 0, 3));
        end
        else if HasO and HasT then
        begin
          { Both modified or added as blobs: execute 3-way line merge }
          if HasB then
            BaseContent := ReadBlobString(EntryB.Id)
          else
            BaseContent := '';

          OursContent := ReadBlobString(EntryO.Id);
          TheirsContent := ReadBlobString(EntryT.Id);

          MergeRes := Merge3Strings(BaseContent, OursContent, TheirsContent, FLabelOurs, FLabelTheirs);

          if not MergeRes.HasConflict then
          begin
            { Clean 3-way line merge! Write new blob to ODB }
            MergedBlobId := WriteBlobString(MergeRes.MergedText);
            IdxEntry := MakeIndexEntry(Path, MergedBlobId, EntryO.Mode, Length(MergeRes.MergedText), 0);
            FIndex.Add(IdxEntry);

            Inc(Result.CleanMergeCount);
            SetLength(Result.CleanMergedPaths, Length(Result.CleanMergedPaths) + 1);
            Result.CleanMergedPaths[Length(Result.CleanMergedPaths) - 1] := Path;
          end
          else
          begin
            { Line conflict! Register conflict stages 1, 2, 3 in index }
            Inc(Result.ConflictCount);
            Result.Success := False;
            SetLength(Result.ConflictedPaths, Length(Result.ConflictedPaths) + 1);
            Result.ConflictedPaths[Length(Result.ConflictedPaths) - 1] := Path;

            if HasB then
              FIndex.Add(MakeIndexEntry(Path, EntryB.Id, EntryB.Mode, 0, 1));
            FIndex.Add(MakeIndexEntry(Path, EntryO.Id, EntryO.Mode, 0, 2));
            FIndex.Add(MakeIndexEntry(Path, EntryT.Id, EntryT.Mode, 0, 3));
          end;
        end;
      end;
    end;
  finally
    Map.Free;
  end;

  { If merge was completely clean, synthesize the result tree }
  if Result.Success then
    Result.ResultTreeId := FIndex.WriteTree(FODB);
end;

function MergeTrees(AODB: TObjectDatabase; AIndex: TIndex;
                    const BaseTreeId, OursTreeId, TheirsTreeId: TObjectId;
                    const LabelOurs, LabelTheirs: string): TMergeTreeSummary;
var
  Merger: TTreeMerger;
begin
  Merger := TTreeMerger.Create(AODB, AIndex, BaseTreeId, OursTreeId, TheirsTreeId, LabelOurs, LabelTheirs);
  try
    Result := Merger.Execute;
  finally
    Merger.Free;
  end;
end;

end.
