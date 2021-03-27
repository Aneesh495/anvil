{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Central staging area (Index / Cache) management engine.
  Supports atomic lockfile writes, binary search entry lookup,
  conflict stage tracking (stages 0..3), and tree synthesis (write-tree).
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_index;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, anvil_types, anvil_errors, anvil_utils,
  anvil_sha1, anvil_hash, anvil_object, anvil_odb, anvil_index_entry, anvil_index_tree;

type
  { Staging area index }
  TIndex = class
  private
    FFilePath: string;
    FVersion: LongWord;
    FAlgo: THashAlgorithm;
    FEntries: array of TIndexEntry;
    FCount: Integer;
    FCacheTree: TIndexTreeNode;
    procedure EnsureCapacity(MinCap: Integer);
    procedure SortEntries;
    function FindInsertIndex(const Path: string; Stage: TStageNumber): Integer;
    function WriteSubtree(Odb: TObjectDatabase; const Prefix: string; StartIdx, EndIdx: Integer): TObjectId;
    procedure ReadSubtree(Odb: TObjectDatabase; const TreeId: TObjectId; const PathPrefix: string);
  public
    constructor Create(const AFilePath: string = ''; Algo: THashAlgorithm = haSHA1);
    destructor Destroy; override;

    procedure Clear;
    procedure LoadFromFile(const AFilePath: string = '');
    procedure WriteToFile(const AFilePath: string = '');

    function Add(const Entry: TIndexEntry): Integer;
    function AddFile(const Path: string; const Id: TObjectId; Mode: TFileMode; FileSize: LongWord = 0; Stage: TStageNumber = 0): Integer;
    function Remove(const Path: string; Stage: TStageNumber = 0): Boolean;
    function RemoveAllStages(const Path: string): Boolean;

    function Find(const Path: string; Stage: TStageNumber; out Entry: TIndexEntry): Boolean;
    function FindAny(const Path: string; out Entry: TIndexEntry): Boolean;
    function HasConflicts: Boolean;
    function GetEntry(Index: Integer): TIndexEntry;

    function WriteTree(Odb: TObjectDatabase): TObjectId;
    procedure ReadTree(Odb: TObjectDatabase; const RootTreeId: TObjectId);

    property FilePath: string read FFilePath write FFilePath;
    property Version: LongWord read FVersion write FVersion;
    property Count: Integer read FCount;
    property CacheTree: TIndexTreeNode read FCacheTree;
  end;

implementation

constructor TIndex.Create(const AFilePath: string; Algo: THashAlgorithm);
begin
  inherited Create;
  FFilePath := AFilePath;
  FVersion := 2;
  FAlgo := Algo;
  FCount := 0;
  SetLength(FEntries, 0);
  FCacheTree := TIndexTreeNode.Create('');
  if (FFilePath <> '') and FileExists(FFilePath) then
    LoadFromFile(FFilePath);
end;

destructor TIndex.Destroy;
begin
  Clear;
  FCacheTree.Free;
  inherited Destroy;
end;

procedure TIndex.Clear;
begin
  SetLength(FEntries, 0);
  FCount := 0;
  FCacheTree.Invalidate;
end;

procedure TIndex.EnsureCapacity(MinCap: Integer);
var
  NewCap: Integer;
begin
  if Length(FEntries) >= MinCap then
    Exit;
  NewCap := Length(FEntries) * 2;
  if NewCap < MinCap then
    NewCap := MinCap;
  if NewCap < 16 then
    NewCap := 16;
  SetLength(FEntries, NewCap);
end;

procedure TIndex.SortEntries;
var
  I, J: Integer;
  Temp: TIndexEntry;
begin
  for I := 0 to FCount - 2 do
  begin
    for J := I + 1 to FCount - 1 do
    begin
      if CompareIndexEntries(FEntries[I], FEntries[J]) > 0 then
      begin
        Temp := FEntries[I];
        FEntries[I] := FEntries[J];
        FEntries[J] := Temp;
      end;
    end;
  end;
end;

function TIndex.FindInsertIndex(const Path: string; Stage: TStageNumber): Integer;
var
  LowIdx, HighIdx, Mid: Integer;
  Cmp: Integer;
  TargetEntry: TIndexEntry;
begin
  TargetEntry.Path := Path;
  TargetEntry.Stage := Stage;

  LowIdx := 0;
  HighIdx := FCount - 1;

  while LowIdx <= HighIdx do
  begin
    Mid := LowIdx + (HighIdx - LowIdx) div 2;
    Cmp := CompareIndexEntries(FEntries[Mid], TargetEntry);
    if Cmp = 0 then
      Exit(Mid)
    else if Cmp < 0 then
      LowIdx := Mid + 1
    else
      HighIdx := Mid - 1;
  end;

  Result := -1 - LowIdx; { Negative insertion position }
end;

procedure TIndex.LoadFromFile(const AFilePath: string);
var
  TargetFile: string;
  FS: TFileStream;
  Magic, Ver, EntryCountVal: LongWord;
  SHA1Ctx: TSHA1Context;
  I: Integer;
  Entry: TIndexEntry;
  RawDigest, FileDigest: TSHA1Digest;
  StreamPos: Int64;
  ExtSig: LongWord;
  ExtSize: LongWord;
  ExtBytes: array of Byte;
begin
  if AFilePath <> '' then
    FFilePath := AFilePath;
  TargetFile := FFilePath;

  if not FileExists(TargetFile) then
    Exit;

  Clear;
  SHA1Init(SHA1Ctx);

  FS := TFileStream.Create(TargetFile, fmOpenRead or fmShareDenyNone);
  try
    if FS.Size < 32 then
      raise EIndexCorrupt.CreateWithCode(ERR_INDEX_CORRUPT, 'Index file too small');

    { Read 12-byte header }
    Magic := 0;
    FS.ReadBuffer(Magic, 4);
    Magic := (LongWord(PByte(@Magic)[0]) shl 24) or (LongWord(PByte(@Magic)[1]) shl 16) or
             (LongWord(PByte(@Magic)[2]) shl 8) or LongWord(PByte(@Magic)[3]);

    if Magic <> INDEX_SIGNATURE then
      raise EIndexCorrupt.CreateWithCode(ERR_INDEX_CORRUPT, 'Invalid index signature: ' + TargetFile);

    Ver := 0;
    FS.ReadBuffer(Ver, 4);
    Ver := (LongWord(PByte(@Ver)[0]) shl 24) or (LongWord(PByte(@Ver)[1]) shl 16) or
           (LongWord(PByte(@Ver)[2]) shl 8) or LongWord(PByte(@Ver)[3]);

    if (Ver < 2) or (Ver > 4) then
      raise EIndexCorrupt.CreateWithCode(ERR_INDEX_CORRUPT, 'Unsupported index version: ' + IntToStr(Ver));
    FVersion := Ver;

    EntryCountVal := 0;
    FS.ReadBuffer(EntryCountVal, 4);
    EntryCountVal := (LongWord(PByte(@EntryCountVal)[0]) shl 24) or (LongWord(PByte(@EntryCountVal)[1]) shl 16) or
                     (LongWord(PByte(@EntryCountVal)[2]) shl 8) or LongWord(PByte(@EntryCountVal)[3]);

    { Update checksum over 12-byte header }
    FS.Position := 0;
    SetLength(ExtBytes, 12);
    FS.ReadBuffer(ExtBytes[0], 12);
    SHA1Update(SHA1Ctx, ExtBytes[0], 12);

    EnsureCapacity(EntryCountVal);

    for I := 0 to EntryCountVal - 1 do
    begin
      StreamPos := FS.Position;
      if ReadIndexEntry(FS, FVersion, FAlgo, Entry) = 0 then
        Break;

      { Hash raw entry bytes into running SHA-1 }
      SetLength(ExtBytes, FS.Position - StreamPos);
      FS.Position := StreamPos;
      FS.ReadBuffer(ExtBytes[0], Length(ExtBytes));
      SHA1Update(SHA1Ctx, ExtBytes[0], Length(ExtBytes));

      FEntries[FCount] := Entry;
      Inc(FCount);
    end;

    { Read optional extension blocks }
    while FS.Position < FS.Size - 20 do
    begin
      StreamPos := FS.Position;
      FS.ReadBuffer(ExtSig, 4);
      FS.ReadBuffer(ExtSize, 4);
      ExtSize := (LongWord(PByte(@ExtSize)[0]) shl 24) or (LongWord(PByte(@ExtSize)[1]) shl 16) or
                 (LongWord(PByte(@ExtSize)[2]) shl 8) or LongWord(PByte(@ExtSize)[3]);

      SetLength(ExtBytes, ExtSize + 8);
      FS.Position := StreamPos;
      FS.ReadBuffer(ExtBytes[0], Length(ExtBytes));
      SHA1Update(SHA1Ctx, ExtBytes[0], Length(ExtBytes));
    end;

    { Read trailing SHA-1 checksum }
    FS.ReadBuffer(FileDigest[0], 20);
    SHA1Final(SHA1Ctx, RawDigest);

    if not CompareMem(@FileDigest[0], @RawDigest[0], 20) then
      raise EIndexCorrupt.CreateWithCode(ERR_INDEX_CORRUPT, 'Index checksum mismatch');

  finally
    FS.Free;
  end;
end;

procedure TIndex.WriteToFile(const AFilePath: string);
var
  TargetFile, LockFile: string;
  FS: TFileStream;
  SHA1Ctx: TSHA1Context;
  Magic, Ver, CountVal: LongWord;
  I: Integer;
  EntryStartPos: Int64;
  EntryBytes: array of Byte;
  Digest: TSHA1Digest;
  HeaderBuf: array[0..11] of Byte;

  procedure StreamWrite(const Data; Len: Integer);
  begin
    if Len <= 0 then Exit;
    FS.WriteBuffer(Data, Len);
    SHA1Update(SHA1Ctx, Data, Len);
  end;

begin
  if AFilePath <> '' then
    FFilePath := AFilePath;
  TargetFile := FFilePath;
  if TargetFile = '' then
    raise EAnvilError.CreateWithCode(ERR_GENERIC, 'Cannot write index: file path not specified');

  SortEntries;
  LockFile := TargetFile + '.lock';
  EnsureDirectoryExists(ExtractFileDir(TargetFile));

  SHA1Init(SHA1Ctx);
  FS := TFileStream.Create(LockFile, fmCreate);
  try
    Magic := INDEX_SIGNATURE;
    Ver := FVersion;
    CountVal := FCount;

    HeaderBuf[0] := Byte((Magic shr 24) and $FF);
    HeaderBuf[1] := Byte((Magic shr 16) and $FF);
    HeaderBuf[2] := Byte((Magic shr 8) and $FF);
    HeaderBuf[3] := Byte(Magic and $FF);

    HeaderBuf[4] := Byte((Ver shr 24) and $FF);
    HeaderBuf[5] := Byte((Ver shr 16) and $FF);
    HeaderBuf[6] := Byte((Ver shr 8) and $FF);
    HeaderBuf[7] := Byte(Ver and $FF);

    HeaderBuf[8] := Byte((CountVal shr 24) and $FF);
    HeaderBuf[9] := Byte((CountVal shr 16) and $FF);
    HeaderBuf[10] := Byte((CountVal shr 8) and $FF);
    HeaderBuf[11] := Byte(CountVal and $FF);

    StreamWrite(HeaderBuf[0], 12);

    for I := 0 to FCount - 1 do
    begin
      EntryStartPos := FS.Position;
      WriteIndexEntry(FS, FVersion, FEntries[I]);

      SetLength(EntryBytes, FS.Position - EntryStartPos);
      FS.Position := EntryStartPos;
      FS.ReadBuffer(EntryBytes[0], Length(EntryBytes));
      SHA1Update(SHA1Ctx, EntryBytes[0], Length(EntryBytes));
    end;

    { Write trailing 20-byte SHA-1 }
    SHA1Final(SHA1Ctx, Digest);
    FS.WriteBuffer(Digest[0], 20);

  finally
    FS.Free;
  end;

  if FileExists(TargetFile) then
    DeleteFile(TargetFile);

  if not RenameFile(LockFile, TargetFile) then
  begin
    DeleteFile(LockFile);
    raise EIndexLocked.CreateWithCode(ERR_INDEX_LOCKED, 'Failed to commit index lockfile: ' + LockFile);
  end;
end;

function TIndex.Add(const Entry: TIndexEntry): Integer;
var
  Idx, I: Integer;
begin
  FCacheTree.Invalidate;
  Idx := FindInsertIndex(Entry.Path, Entry.Stage);
  if Idx >= 0 then
  begin
    FEntries[Idx] := Entry;
    Exit(Idx);
  end;

  Idx := -1 - Idx;
  EnsureCapacity(FCount + 1);

  for I := FCount - 1 downto Idx do
    FEntries[I + 1] := FEntries[I];

  FEntries[Idx] := Entry;
  Inc(FCount);
  Result := Idx;
end;

function TIndex.AddFile(const Path: string; const Id: TObjectId; Mode: TFileMode; FileSize: LongWord; Stage: TStageNumber): Integer;
var
  Entry: TIndexEntry;
begin
  Entry := MakeIndexEntry(Path, Id, Mode, FileSize, Stage);
  Result := Add(Entry);
end;

function TIndex.Remove(const Path: string; Stage: TStageNumber): Boolean;
var
  Idx, I: Integer;
begin
  FCacheTree.Invalidate;
  Idx := FindInsertIndex(Path, Stage);
  if Idx < 0 then
    Exit(False);

  for I := Idx to FCount - 2 do
    FEntries[I] := FEntries[I + 1];

  FEntries[FCount - 1].Path := '';
  FillChar(FEntries[FCount - 1], SizeOf(TIndexEntry), 0);

  Dec(FCount);
  Result := True;
end;

function TIndex.RemoveAllStages(const Path: string): Boolean;
var
  StageNum: TStageNumber;
begin
  Result := False;
  for StageNum := 0 to 3 do
  begin
    if Remove(Path, StageNum) then
      Result := True;
  end;
end;

function TIndex.Find(const Path: string; Stage: TStageNumber; out Entry: TIndexEntry): Boolean;
var
  Idx: Integer;
begin
  Idx := FindInsertIndex(Path, Stage);
  if Idx >= 0 then
  begin
    Entry := FEntries[Idx];
    Exit(True);
  end;
  FillChar(Entry, SizeOf(Entry), 0);
  Result := False;
end;

function TIndex.FindAny(const Path: string; out Entry: TIndexEntry): Boolean;
var
  StageNum: TStageNumber;
begin
  for StageNum := 0 to 3 do
  begin
    if Find(Path, StageNum, Entry) then
      Exit(True);
  end;
  FillChar(Entry, SizeOf(Entry), 0);
  Result := False;
end;

function TIndex.HasConflicts: Boolean;
var
  I: Integer;
begin
  for I := 0 to FCount - 1 do
  begin
    if FEntries[I].Stage > 0 then
      Exit(True);
  end;
  Result := False;
end;

function TIndex.GetEntry(Index: Integer): TIndexEntry;
begin
  if (Index < 0) or (Index >= FCount) then
    raise EIndexCorrupt.CreateWithCode(ERR_INDEX_CORRUPT, 'Index entry out of bounds');
  Result := FEntries[Index];
end;

function TIndex.WriteSubtree(Odb: TObjectDatabase; const Prefix: string; StartIdx, EndIdx: Integer): TObjectId;
var
  Tree: TTreeObject;
  I, SubStart, SubEnd: Integer;
  EntryPath, RelPath, CompName, SubPrefix: string;
  SlashPos: Integer;
  SubtreeId: TObjectId;
begin
  Tree := TTreeObject.Create;
  try
    I := StartIdx;
    while I <= EndIdx do
    begin
      EntryPath := FEntries[I].Path;
      if (Prefix <> '') and (Pos(Prefix, EntryPath) = 1) then
        RelPath := Copy(EntryPath, Length(Prefix) + 1, MaxInt)
      else
        RelPath := EntryPath;

      SlashPos := Pos('/', RelPath);
      if SlashPos > 0 then
      begin
        CompName := Copy(RelPath, 1, SlashPos - 1);
        SubPrefix := Prefix + CompName + '/';

        SubStart := I;
        SubEnd := I;
        while (SubEnd + 1 <= EndIdx) and (Pos(SubPrefix, FEntries[SubEnd + 1].Path) = 1) do
          Inc(SubEnd);

        SubtreeId := WriteSubtree(Odb, SubPrefix, SubStart, SubEnd);
        Tree.AddEntry(fmDirectory, CompName, SubtreeId);
        I := SubEnd + 1;
      end
      else
      begin
        Tree.AddEntry(FEntries[I].Mode, RelPath, FEntries[I].Id);
        Inc(I);
      end;
    end;

    Result := Odb.WriteObject(Tree);
  finally
    Tree.Free;
  end;
end;

function TIndex.WriteTree(Odb: TObjectDatabase): TObjectId;
begin
  if HasConflicts then
    raise EMergeConflict.CreateWithCode(ERR_MERGE_CONFLICT, 'Cannot write-tree with unmerged staging conflicts');

  if FCount = 0 then
  begin
    { Return empty tree object }
    Result := WriteSubtree(Odb, '', 0, -1);
  end
  else
    Result := WriteSubtree(Odb, '', 0, FCount - 1);
end;

procedure TIndex.ReadSubtree(Odb: TObjectDatabase; const TreeId: TObjectId; const PathPrefix: string);
var
  Tree: TTreeObject;
  Entry: TTreeEntry;
  I: Integer;
  FullPath: string;
begin
  Tree := TTreeObject(Odb.ReadObject(TreeId));
  try
    for I := 0 to Tree.Count - 1 do
    begin
      Entry := Tree.GetEntry(I);
      FullPath := PathPrefix + Entry.Name;

      if Entry.Mode = fmDirectory then
        ReadSubtree(Odb, Entry.Id, FullPath + '/')
      else
        AddFile(FullPath, Entry.Id, Entry.Mode, 0, 0);
    end;
  finally
    Tree.Free;
  end;
end;

procedure TIndex.ReadTree(Odb: TObjectDatabase; const RootTreeId: TObjectId);
begin
  Clear;
  ReadSubtree(Odb, RootTreeId, '');
  SortEntries;
end;

end.
