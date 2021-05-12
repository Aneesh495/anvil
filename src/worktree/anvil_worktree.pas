{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Working tree status scanner and change detector.
  Computes differences between HEAD commit, staging index, and working tree
  using accelerated file stat-cache comparisons and .gitignore exclusion filters.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_worktree;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_index, anvil_index_entry, anvil_ignore, anvil_utils;

type
  { Detailed working tree status report }
  TWorktreeStatus = record
    { Changes staged for commit (Index vs HEAD) }
    StagedNew: TStringArray;
    StagedModified: TStringArray;
    StagedDeleted: TStringArray;

    { Changes not staged for commit (Worktree vs Index) }
    UnstagedModified: TStringArray;
    UnstagedDeleted: TStringArray;

    { Untracked files }
    Untracked: TStringArray;

    { Merge conflicts }
    HasConflicts: Boolean;
    ConflictedFiles: TStringArray;

    IsClean: Boolean;
  end;

  { Working tree status scanner }
  TWorktreeScanner = class
  private
    FWorkingDir: string;
    FGitDir: string;
    FODB: TObjectDatabase;
    FIndex: TIndex;
    FIgnore: TIgnoreMatcher;
    FOwnsIgnore: Boolean;

    procedure RefreshIgnore;
    procedure ScanDirectory(const DirPath, RelPrefix: string; var Files: TStringArray);
    function HashFileBlob(const FullPath: string): TObjectId;
  public
    constructor Create(const AWorkingDir, AGitDir: string;
                       AODB: TObjectDatabase; AIndex: TIndex;
                       AIgnore: TIgnoreMatcher = nil);
    destructor Destroy; override;

    { Scan and compute complete status against HEAD tree }
    function ComputeStatus(const HeadTreeId: TObjectId): TWorktreeStatus;
  end;

function GetWorkingTreeStatus(const AWorkingDir, AGitDir: string;
                              AODB: TObjectDatabase; AIndex: TIndex;
                              const HeadTreeId: TObjectId): TWorktreeStatus;

implementation

constructor TWorktreeScanner.Create(const AWorkingDir, AGitDir: string;
                                    AODB: TObjectDatabase; AIndex: TIndex;
                                    AIgnore: TIgnoreMatcher);
begin
  inherited Create;
  FWorkingDir := AWorkingDir;
  FGitDir := AGitDir;
  FODB := AODB;
  FIndex := AIndex;

  if Assigned(AIgnore) then
  begin
    FIgnore := AIgnore;
    FOwnsIgnore := False;
  end
  else
  begin
    FIgnore := nil;
    FOwnsIgnore := True;
    RefreshIgnore;
  end;
end;

destructor TWorktreeScanner.Destroy;
begin
  if FOwnsIgnore and Assigned(FIgnore) then
    FIgnore.Free;
  inherited Destroy;
end;

procedure TWorktreeScanner.RefreshIgnore;
var
  IgnorePath: string;
begin
  if not FOwnsIgnore then Exit;
  if Assigned(FIgnore) then
    FIgnore.Free;
  FIgnore := TIgnoreMatcher.Create(FWorkingDir);
  IgnorePath := JoinPaths(FWorkingDir, '.gitignore');
  if FileExists(IgnorePath) then
    FIgnore.LoadFile(IgnorePath);
  IgnorePath := JoinPaths(FWorkingDir, '.anvilignore');
  if FileExists(IgnorePath) then
    FIgnore.LoadFile(IgnorePath);
end;

function TWorktreeScanner.HashFileBlob(const FullPath: string): TObjectId;
var
  Data: TByteArray;
begin
  Data := ReadEntireFile(FullPath);
  if Length(Data) = 0 then
    Result := HashGitObject(otBlob, nil, 0, haSHA1)
  else
    Result := HashGitObject(otBlob, @Data[0], Length(Data), haSHA1);
end;

procedure TWorktreeScanner.ScanDirectory(const DirPath, RelPrefix: string; var Files: TStringArray);
var
  SR: TSearchRec;
  ItemRel, ItemFull: string;
  IsDir: Boolean;
begin
  if FindFirst(JoinPaths(DirPath, '*'), faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') and (SR.Name <> '.anvil') and (SR.Name <> '.git') then
      begin
        if RelPrefix <> '' then
          ItemRel := RelPrefix + '/' + SR.Name
        else
          ItemRel := SR.Name;

        ItemFull := JoinPaths(DirPath, SR.Name);
        IsDir := (SR.Attr and faDirectory) <> 0;

        { Check ignore patterns }
        if FIgnore.IsIgnored(ItemRel, IsDir) then
          Continue;

        if IsDir then
          ScanDirectory(ItemFull, ItemRel, Files)
        else
        begin
          SetLength(Files, Length(Files) + 1);
          Files[Length(Files) - 1] := ItemRel;
        end;
      end;
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

function TWorktreeScanner.ComputeStatus(const HeadTreeId: TObjectId): TWorktreeStatus;
var
  DiskFiles: TStringArray;
  I, J: Integer;
  Path: string;
  FullPath: string;
  Entry: TIndexEntry;
  SR: TSearchRec;
  FileBlobId: TObjectId;

  { Head tree map }
  HeadEntries: array of record
    Path: string;
    Id: TObjectId;
  end;
  HeadCount: Integer;

  procedure FlattenTree(const Prefix: string; const TreeId: TObjectId);
  var
    Obj: TAnvilObject;
    Tree: TTreeObject;
    K: Integer;
    TreeEnt: TTreeEntry;
    SubPrefix: string;
  begin
    if IsNullObjectId(TreeId) then Exit;
    Obj := FODB.ReadObject(TreeId);
    if not Assigned(Obj) then Exit;
    if not (Obj is TTreeObject) then
    begin
      Obj.Free;
      Exit;
    end;

    Tree := TTreeObject(Obj);
    try
      for K := 0 to Tree.Count - 1 do
      begin
        TreeEnt := Tree.GetEntry(K);
        if Prefix <> '' then
          SubPrefix := Prefix + '/' + TreeEnt.Name
        else
          SubPrefix := TreeEnt.Name;

        if TreeEnt.Mode = fmDirectory then
          FlattenTree(SubPrefix, TreeEnt.Id)
        else
        begin
          if HeadCount >= Length(HeadEntries) then
            SetLength(HeadEntries, Length(HeadEntries) * 2 + 16);
          HeadEntries[HeadCount].Path := SubPrefix;
          HeadEntries[HeadCount].Id := TreeEnt.Id;
          Inc(HeadCount);
        end;
      end;
    finally
      Tree.Free;
    end;
  end;

  function FindHeadEntry(const APath: string; out AId: TObjectId): Boolean;
  var
    K: Integer;
  begin
    for K := 0 to HeadCount - 1 do
    begin
      if HeadEntries[K].Path = APath then
      begin
        AId := HeadEntries[K].Id;
        Exit(True);
      end;
    end;
    Result := False;
  end;

var
  HeadId: TObjectId;
  HeadSeen: array of Boolean;
  FoundHead: Boolean;
begin
  SetLength(Result.StagedNew, 0);
  SetLength(Result.StagedModified, 0);
  SetLength(Result.StagedDeleted, 0);
  SetLength(Result.UnstagedModified, 0);
  SetLength(Result.UnstagedDeleted, 0);
  SetLength(Result.Untracked, 0);
  SetLength(Result.ConflictedFiles, 0);
  Result.HasConflicts := FIndex.HasConflicts;

  RefreshIgnore;

  { Check merge conflicts }
  if Result.HasConflicts then
    Result.ConflictedFiles := FIndex.GetConflictPaths;

  { 1. Flatten HEAD tree for Index vs HEAD comparison }
  SetLength(HeadEntries, 32);
  HeadCount := 0;
  FlattenTree('', HeadTreeId);
  SetLength(HeadSeen, HeadCount);
  for I := 0 to HeadCount - 1 do
    HeadSeen[I] := False;

  { 2. Compare Index entries against HEAD }
  for I := 0 to FIndex.Count - 1 do
  begin
    Entry := FIndex.GetEntry(I);
    if Entry.Stage <> 0 then
      Continue; { Skip conflict stages in regular status }

    FoundHead := False;
    for J := 0 to HeadCount - 1 do
    begin
      if HeadEntries[J].Path = Entry.Path then
      begin
        FoundHead := True;
        HeadSeen[J] := True;
        if not ObjectIdEqual(HeadEntries[J].Id, Entry.Id) then
        begin
          SetLength(Result.StagedModified, Length(Result.StagedModified) + 1);
          Result.StagedModified[Length(Result.StagedModified) - 1] := Entry.Path;
        end;
        Break;
      end;
    end;

    if not FoundHead then
    begin
      SetLength(Result.StagedNew, Length(Result.StagedNew) + 1);
      Result.StagedNew[Length(Result.StagedNew) - 1] := Entry.Path;
    end;
  end;

  { Check staged deletions (in HEAD but not in Index) }
  for I := 0 to HeadCount - 1 do
  begin
    if not HeadSeen[I] then
    begin
      SetLength(Result.StagedDeleted, Length(Result.StagedDeleted) + 1);
      Result.StagedDeleted[Length(Result.StagedDeleted) - 1] := HeadEntries[I].Path;
    end;
  end;

  { 3. Compare Working Tree files against Index }
  SetLength(DiskFiles, 0);
  ScanDirectory(FWorkingDir, '', DiskFiles);

  { Check untracked files }
  for I := 0 to Length(DiskFiles) - 1 do
  begin
    Path := DiskFiles[I];
    if not FIndex.FindAny(Path, Entry) then
    begin
      SetLength(Result.Untracked, Length(Result.Untracked) + 1);
      Result.Untracked[Length(Result.Untracked) - 1] := Path;
    end;
  end;

  { Check unstaged modifications and unstaged deletions }
  for I := 0 to FIndex.Count - 1 do
  begin
    Entry := FIndex.GetEntry(I);
    if Entry.Stage <> 0 then
      Continue;

    FullPath := JoinPaths(FWorkingDir, Entry.Path);
    if not FileExists(FullPath) then
    begin
      SetLength(Result.UnstagedDeleted, Length(Result.UnstagedDeleted) + 1);
      Result.UnstagedDeleted[Length(Result.UnstagedDeleted) - 1] := Entry.Path;
    end
    else
    begin
      { File stat cache check: if size differs, definitely modified }
      if (FindFirst(FullPath, faAnyFile, SR) = 0) then
      begin
        try
          if (Entry.Stat.FileSize > 0) and (SR.Size <> Int64(Entry.Stat.FileSize)) then
          begin
            SetLength(Result.UnstagedModified, Length(Result.UnstagedModified) + 1);
            Result.UnstagedModified[Length(Result.UnstagedModified) - 1] := Entry.Path;
          end
          else
          begin
            { Hash file content to confirm exact match }
            FileBlobId := HashFileBlob(FullPath);
            if not ObjectIdEqual(FileBlobId, Entry.Id) then
            begin
              SetLength(Result.UnstagedModified, Length(Result.UnstagedModified) + 1);
              Result.UnstagedModified[Length(Result.UnstagedModified) - 1] := Entry.Path;
            end;
          end;
        finally
          FindClose(SR);
        end;
      end;
    end;
  end;

  Result.IsClean := (Length(Result.StagedNew) = 0) and
                    (Length(Result.StagedModified) = 0) and
                    (Length(Result.StagedDeleted) = 0) and
                    (Length(Result.UnstagedModified) = 0) and
                    (Length(Result.UnstagedDeleted) = 0) and
                    (Length(Result.Untracked) = 0) and
                    (not Result.HasConflicts);
end;

function GetWorkingTreeStatus(const AWorkingDir, AGitDir: string;
                              AODB: TObjectDatabase; AIndex: TIndex;
                              const HeadTreeId: TObjectId): TWorktreeStatus;
var
  Scanner: TWorktreeScanner;
begin
  Scanner := TWorktreeScanner.Create(AWorkingDir, AGitDir, AODB, AIndex);
  try
    Result := Scanner.ComputeStatus(HeadTreeId);
  finally
    Scanner.Free;
  end;
end;

end.
