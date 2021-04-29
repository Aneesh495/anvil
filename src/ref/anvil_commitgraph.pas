{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Git commit-graph binary format reader and writer.
  Implements the standard CGPH specification with 256-fanout OIDF chunk,
  lexicographically sorted OIDL lookup table, and fixed-stride CDAT commit data chunk.
  Accelerates topological traversal and revision parsing by orders of magnitude.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_commitgraph;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_sha1, anvil_sha256,
  anvil_hash, anvil_object, anvil_odb, anvil_utils;

const
  COMMIT_GRAPH_MAGIC = $43475048; { 'CGPH' }
  COMMIT_GRAPH_VERSION = 1;
  CHUNK_ID_OIDF = $4F494446;     { 'OIDF' }
  CHUNK_ID_OIDL = $4F49444C;     { 'OIDL' }
  CHUNK_ID_CDAT = $43444154;     { 'CDAT' }

type
  { In-memory parsed commit-graph entry }
  TCommitGraphEntry = record
    CommitId: TObjectId;
    TreeId: TObjectId;
    Generation: LongWord;
    CommitTime: Int64;
    Parent1Index: Integer; { -1 if none }
    Parent2Index: Integer; { -1 if none }
    ParentIds: TObjectIdArray;
  end;
  TCommitGraphEntryArray = array of TCommitGraphEntry;

  { Commit Graph manager }
  TCommitGraph = class
  private
    FFilePath: string;
    FAlgo: THashAlgorithm;
    FDigestLen: Integer;
    FFanout: array[0..255] of LongWord;
    FEntries: TCommitGraphEntryArray;
    FCount: Integer;
    FLoaded: Boolean;

    function BinarySearch(const Id: TObjectId; out FoundIdx: Integer): Boolean;
  public
    constructor Create(const AFilePath: string; Algo: THashAlgorithm = haSHA1);

    { Load and verify binary commit-graph from file }
    function Load: Boolean;

    { Build and serialize commit-graph from repository commits }
    procedure BuildFromODB(Odb: TObjectDatabase; const TipCommitIds: TObjectIdArray);

    { Fast lookups }
    function FindCommit(const Id: TObjectId; out Entry: TCommitGraphEntry): Boolean;
    function GetEntry(Index: Integer): TCommitGraphEntry;

    property Count: Integer read FCount;
    property Loaded: Boolean read FLoaded;
  end;

implementation

function ReadStreamUInt32BE(S: TStream): LongWord;
var
  Buf: array[0..3] of Byte;
begin
  S.ReadBuffer(Buf[0], 4);
  Result := ReadUInt32BE(@Buf[0]);
end;

function ReadStreamUInt64BE(S: TStream): QWord;
var
  Buf: array[0..7] of Byte;
begin
  S.ReadBuffer(Buf[0], 8);
  Result := ReadUInt64BE(@Buf[0]);
end;

procedure WriteStreamUInt32BE(S: TStream; V: LongWord);
var
  Buf: array[0..3] of Byte;
begin
  WriteUInt32BE(@Buf[0], V);
  S.WriteBuffer(Buf[0], 4);
end;

procedure WriteStreamUInt64BE(S: TStream; V: QWord);
var
  Buf: array[0..7] of Byte;
begin
  WriteUInt64BE(@Buf[0], V);
  S.WriteBuffer(Buf[0], 8);
end;

constructor TCommitGraph.Create(const AFilePath: string; Algo: THashAlgorithm);
begin
  inherited Create;
  FFilePath := AFilePath;
  FAlgo := Algo;
  if Algo = haSHA1 then
    FDigestLen := SHA1_DIGEST_LENGTH
  else
    FDigestLen := SHA256_DIGEST_LENGTH;
  FillChar(FFanout, SizeOf(FFanout), 0);
  SetLength(FEntries, 0);
  FCount := 0;
  FLoaded := False;
end;

function TCommitGraph.BinarySearch(const Id: TObjectId; out FoundIdx: Integer): Boolean;
var
  FirstByte: Byte;
  LowIdx, HighIdx, MidIdx, Cmp: Integer;
begin
  FoundIdx := -1;
  Result := False;
  if FCount = 0 then Exit;

  FirstByte := Id.Digest[0];
  if FirstByte = 0 then
    LowIdx := 0
  else
    LowIdx := Integer(FFanout[FirstByte - 1]);
  HighIdx := Integer(FFanout[FirstByte]) - 1;

  while LowIdx <= HighIdx do
  begin
    MidIdx := LowIdx + (HighIdx - LowIdx) div 2;
    Cmp := ObjectIdCompare(Id, FEntries[MidIdx].CommitId);

    if Cmp = 0 then
    begin
      FoundIdx := MidIdx;
      Exit(True);
    end
    else if Cmp < 0 then
      HighIdx := MidIdx - 1
    else
      LowIdx := MidIdx + 1;
  end;
end;

function TCommitGraph.FindCommit(const Id: TObjectId; out Entry: TCommitGraphEntry): Boolean;
var
  Idx: Integer;
begin
  Result := BinarySearch(Id, Idx);
  if Result then
    Entry := FEntries[Idx]
  else
    FillChar(Entry, SizeOf(Entry), 0);
end;

function TCommitGraph.GetEntry(Index: Integer): TCommitGraphEntry;
begin
  if (Index < 0) or (Index >= FCount) then
    raise EAnvilError.CreateWithCode(ERR_GENERIC, 'Commit graph index out of bounds');
  Result := FEntries[Index];
end;

function TCommitGraph.Load: Boolean;
var
  FS: TFileStream;
  Magic: LongWord;
  Version, HashVer, NumChunks, BaseGraphs: Byte;
  ChunkHeaders: array of record
    Id: LongWord;
    Offset: QWord;
  end;
  I, J: Integer;
  OidfOffset, OidlOffset, CdatOffset: Int64;
  P1Raw, P2Raw: LongWord;
  GenRaw, TimeRawHi, TimeRawLo: LongWord;
begin
  Result := False;
  FLoaded := False;
  if not FileExists(FFilePath) then Exit;

  FS := TFileStream.Create(FFilePath, fmOpenRead or fmShareDenyNone);
  try
    if FS.Size < 8 then Exit;

    Magic := ReadStreamUInt32BE(FS);
    if Magic <> COMMIT_GRAPH_MAGIC then Exit;

    Version := FS.ReadByte;
    if Version <> COMMIT_GRAPH_VERSION then Exit;

    HashVer := FS.ReadByte;
    if (HashVer = 1) and (FAlgo <> haSHA1) then Exit;
    if (HashVer = 2) and (FAlgo <> haSHA256) then Exit;

    NumChunks := FS.ReadByte;
    BaseGraphs := FS.ReadByte;

    SetLength(ChunkHeaders, NumChunks + 1);
    for I := 0 to NumChunks do
    begin
      ChunkHeaders[I].Id := ReadStreamUInt32BE(FS);
      ChunkHeaders[I].Offset := ReadStreamUInt64BE(FS);
    end;

    OidfOffset := -1;
    OidlOffset := -1;
    CdatOffset := -1;

    for I := 0 to NumChunks - 1 do
    begin
      case ChunkHeaders[I].Id of
        CHUNK_ID_OIDF: OidfOffset := Int64(ChunkHeaders[I].Offset);
        CHUNK_ID_OIDL: OidlOffset := Int64(ChunkHeaders[I].Offset);
        CHUNK_ID_CDAT: CdatOffset := Int64(ChunkHeaders[I].Offset);
      end;
    end;

    if (OidfOffset < 0) or (OidlOffset < 0) or (CdatOffset < 0) then Exit;

    { Read OIDF }
    FS.Position := OidfOffset;
    for I := 0 to 255 do
      FFanout[I] := ReadStreamUInt32BE(FS);

    FCount := Integer(FFanout[255]);
    SetLength(FEntries, FCount);

    { Read OIDL }
    FS.Position := OidlOffset;
    for I := 0 to FCount - 1 do
    begin
      FEntries[I].CommitId.Algorithm := FAlgo;
      FS.ReadBuffer(FEntries[I].CommitId.Digest[0], FDigestLen);
    end;

    { Read CDAT }
    FS.Position := CdatOffset;
    for I := 0 to FCount - 1 do
    begin
      FEntries[I].TreeId.Algorithm := FAlgo;
      FS.ReadBuffer(FEntries[I].TreeId.Digest[0], FDigestLen);

      P1Raw := ReadStreamUInt32BE(FS);
      P2Raw := ReadStreamUInt32BE(FS);
      GenRaw := ReadStreamUInt32BE(FS);
      TimeRawHi := ReadStreamUInt32BE(FS);
      TimeRawLo := ReadStreamUInt32BE(FS);

      FEntries[I].Generation := GenRaw;
      FEntries[I].CommitTime := (Int64(TimeRawHi) shl 32) or Int64(TimeRawLo);

      if P1Raw = $7FFFFFFF then
        FEntries[I].Parent1Index := -1
      else
        FEntries[I].Parent1Index := Integer(P1Raw);

      if P2Raw = $7FFFFFFF then
        FEntries[I].Parent2Index := -1
      else
        FEntries[I].Parent2Index := Integer(P2Raw);
    end;

    { Reconstitute ParentIds }
    for I := 0 to FCount - 1 do
    begin
      SetLength(FEntries[I].ParentIds, 0);
      if (FEntries[I].Parent1Index >= 0) and (FEntries[I].Parent1Index < FCount) then
      begin
        SetLength(FEntries[I].ParentIds, Length(FEntries[I].ParentIds) + 1);
        FEntries[I].ParentIds[Length(FEntries[I].ParentIds) - 1] := FEntries[FEntries[I].Parent1Index].CommitId;
      end;
      if (FEntries[I].Parent2Index >= 0) and (FEntries[I].Parent2Index < FCount) then
      begin
        SetLength(FEntries[I].ParentIds, Length(FEntries[I].ParentIds) + 1);
        FEntries[I].ParentIds[Length(FEntries[I].ParentIds) - 1] := FEntries[FEntries[I].Parent2Index].CommitId;
      end;
    end;

    FLoaded := True;
    Result := True;
  finally
    FS.Free;
  end;
end;

procedure TCommitGraph.BuildFromODB(Odb: TObjectDatabase; const TipCommitIds: TObjectIdArray);
var
  Visited: TObjectIdSet;
  Queue: array of TObjectId;
  Head, Tail: Integer;
  CurrId: TObjectId;
  Obj: TAnvilObject;
  Commit: TCommitObject;
  Commits: array of TCommitObject;
  CommitCount: Integer;
  I, J: Integer;
  TmpCommit: TCommitObject;
  TmpEntry: TCommitGraphEntry;

  { File write variables }
  FS: TFileStream;
  HeaderOffset: Int64;
  OidfPos, OidlPos, CdatPos, EndPos: QWord;
  TotalChunks: Byte;
  P1Idx, P2Idx: Integer;
  Parent1Val, Parent2Val: LongWord;
  P1Id, P2Id: TObjectId;
  TimeVal: Int64;
  TimeHi, TimeLo: LongWord;
  FileBuf: TByteArray;
  SHA1Ctx: TSHA1Context;
  SHA256Ctx: TSHA256Context;
  TrailerDigest1: TSHA1Digest;
  TrailerDigest256: TSHA256Digest;
begin
  Visited := TObjectIdSet.Create;
  try
    SetLength(Queue, 32);
    Head := 0;
    Tail := 0;

    for I := 0 to Length(TipCommitIds) - 1 do
    begin
      if not Visited.Contains(TipCommitIds[I]) then
      begin
        Visited.Add(TipCommitIds[I]);
        Queue[Tail] := TipCommitIds[I];
        Inc(Tail);
      end;
    end;

    SetLength(Commits, 32);
    CommitCount := 0;

    { BFS walk reachable commits }
    while Head < Tail do
    begin
      CurrId := Queue[Head];
      Inc(Head);

      Obj := Odb.ReadObject(CurrId);
      if Assigned(Obj) and (Obj is TCommitObject) then
      begin
        Commit := TCommitObject(Obj);
        if CommitCount >= Length(Commits) then
          SetLength(Commits, Length(Commits) * 2);
        Commits[CommitCount] := Commit;
        Inc(CommitCount);

        for J := 0 to Length(Commit.ParentIds) - 1 do
        begin
          if not Visited.Contains(Commit.ParentIds[J]) then
          begin
            Visited.Add(Commit.ParentIds[J]);
            if Tail >= Length(Queue) then
              SetLength(Queue, Length(Queue) * 2);
            Queue[Tail] := Commit.ParentIds[J];
            Inc(Tail);
          end;
        end;
      end
      else if Assigned(Obj) then
        Obj.Free;
    end;
  finally
    Visited.Free;
  end;

  { Sort commits lexicographically by ObjectId }
  for I := 0 to CommitCount - 2 do
  begin
    for J := I + 1 to CommitCount - 1 do
    begin
      if ObjectIdCompare(Commits[I].ObjectId, Commits[J].ObjectId) > 0 then
      begin
        TmpCommit := Commits[I];
        Commits[I] := Commits[J];
        Commits[J] := TmpCommit;
      end;
    end;
  end;

  { Compute fanout table }
  FillChar(FFanout, SizeOf(FFanout), 0);
  for I := 0 to CommitCount - 1 do
    Inc(FFanout[Commits[I].ObjectId.Digest[0]]);
  for I := 1 to 255 do
    FFanout[I] := FFanout[I] + FFanout[I - 1];

  { Populate in-memory entries }
  FCount := CommitCount;
  SetLength(FEntries, FCount);
  for I := 0 to FCount - 1 do
  begin
    FEntries[I].CommitId := Commits[I].ObjectId;
    FEntries[I].TreeId := Commits[I].TreeId;
    FEntries[I].Generation := 1; { default generation }
    FEntries[I].CommitTime := Commits[I].Author.When.Seconds;
    FEntries[I].ParentIds := Commits[I].ParentIds;
  end;

  { Resolve parent indices }
  for I := 0 to FCount - 1 do
  begin
    FEntries[I].Parent1Index := -1;
    FEntries[I].Parent2Index := -1;

    if Length(FEntries[I].ParentIds) > 0 then
    begin
      P1Id := FEntries[I].ParentIds[0];
      if BinarySearch(P1Id, P1Idx) then
        FEntries[I].Parent1Index := P1Idx;
    end;

    if Length(FEntries[I].ParentIds) > 1 then
    begin
      P2Id := FEntries[I].ParentIds[1];
      if BinarySearch(P2Id, P2Idx) then
        FEntries[I].Parent2Index := P2Idx;
    end;
  end;

  { Serialize commit-graph to disk }
  EnsureDirectoryExists(ExtractFileDir(FFilePath));
  FS := TFileStream.Create(FFilePath, fmCreate);
  try
    { 1. Header (8 bytes) }
    WriteStreamUInt32BE(FS, COMMIT_GRAPH_MAGIC);
    FS.WriteByte(COMMIT_GRAPH_VERSION);
    if FAlgo = haSHA1 then
      FS.WriteByte(1)
    else
      FS.WriteByte(2);
    TotalChunks := 3;
    FS.WriteByte(TotalChunks);
    FS.WriteByte(0); { Base graphs }

    { Calculate offsets }
    { Chunk table size: (TotalChunks + 1) * 12 bytes = 48 bytes }
    OidfPos := 8 + (TotalChunks + 1) * 12;
    OidlPos := OidfPos + 256 * 4;
    CdatPos := OidlPos + QWord(FCount) * QWord(FDigestLen);
    { CDAT stride: DigestLen (tree) + 4 (P1) + 4 (P2) + 4 (Gen) + 8 (Time) = DigestLen + 20 }
    EndPos := CdatPos + QWord(FCount) * QWord(FDigestLen + 20);

    { 2. Chunk Table }
    WriteStreamUInt32BE(FS, CHUNK_ID_OIDF);
    WriteStreamUInt64BE(FS, OidfPos);

    WriteStreamUInt32BE(FS, CHUNK_ID_OIDL);
    WriteStreamUInt64BE(FS, OidlPos);

    WriteStreamUInt32BE(FS, CHUNK_ID_CDAT);
    WriteStreamUInt64BE(FS, CdatPos);

    { Terminator entry }
    WriteStreamUInt32BE(FS, 0);
    WriteStreamUInt64BE(FS, EndPos);

    { 3. OIDF Chunk }
    for I := 0 to 255 do
      WriteStreamUInt32BE(FS, FFanout[I]);

    { 4. OIDL Chunk }
    for I := 0 to FCount - 1 do
      FS.WriteBuffer(FEntries[I].CommitId.Digest[0], FDigestLen);

    { 5. CDAT Chunk }
    for I := 0 to FCount - 1 do
    begin
      FS.WriteBuffer(FEntries[I].TreeId.Digest[0], FDigestLen);

      if FEntries[I].Parent1Index < 0 then
        Parent1Val := $7FFFFFFF
      else
        Parent1Val := LongWord(FEntries[I].Parent1Index);
      WriteStreamUInt32BE(FS, Parent1Val);

      if FEntries[I].Parent2Index < 0 then
        Parent2Val := $7FFFFFFF
      else
        Parent2Val := LongWord(FEntries[I].Parent2Index);
      WriteStreamUInt32BE(FS, Parent2Val);

      WriteStreamUInt32BE(FS, FEntries[I].Generation);

      TimeVal := FEntries[I].CommitTime;
      TimeHi := LongWord((TimeVal shr 32) and $FFFFFFFF);
      TimeLo := LongWord(TimeVal and $FFFFFFFF);
      WriteStreamUInt32BE(FS, TimeHi);
      WriteStreamUInt32BE(FS, TimeLo);
    end;

    { 6. Trailer: Checksum of file data written so far }
    SetLength(FileBuf, FS.Position);
    FS.Position := 0;
    if Length(FileBuf) > 0 then
      FS.ReadBuffer(FileBuf[0], Length(FileBuf));

    FS.Seek(0, soFromEnd);
    if FAlgo = haSHA1 then
    begin
      SHA1Init(SHA1Ctx);
      if Length(FileBuf) > 0 then
        SHA1Update(SHA1Ctx, FileBuf[0], Length(FileBuf));
      SHA1Final(SHA1Ctx, TrailerDigest1);
      FS.WriteBuffer(TrailerDigest1[0], SHA1_DIGEST_LENGTH);
    end
    else
    begin
      SHA256Init(SHA256Ctx);
      if Length(FileBuf) > 0 then
        SHA256Update(SHA256Ctx, FileBuf[0], Length(FileBuf));
      SHA256Final(SHA256Ctx, TrailerDigest256);
      FS.WriteBuffer(TrailerDigest256[0], SHA256_DIGEST_LENGTH);
    end;

  finally
    for I := 0 to CommitCount - 1 do
      Commits[I].Free;
    FS.Free;
  end;

  FLoaded := True;
end;

end.
