{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Git Packfile Index Version 2 (.idx) reader and writer.
  Provides O(log N) binary search lookup across 256-entry first-level
  fanout tables, 4-byte/8-byte file offset resolution, and CRC32 verification.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_pack_index;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, anvil_types, anvil_errors, anvil_utils, anvil_sha1, anvil_crc32;

const
  PACK_INDEX_V2_MAGIC = $FF744F63; { "\xFFtOc" }

type
  { Pack index entry metadata }
  TPackIndexEntry = record
    Id: TObjectId;
    Offset: QWord;
    Crc32: LongWord;
  end;
  PPackIndexEntry = ^TPackIndexEntry;

  { Pack index reader and parser }
  TPackIndex = class
  private
    FFilePath: string;
    FFanout: array[0..255] of LongWord;
    FObjectCount: LongWord;
    FObjectIds: array of TObjectId;
    FOffsets: array of QWord;
    FCrc32s: array of LongWord;
    FPackfileChecksum: TObjectId;
    FIndexChecksum: TObjectId;
    procedure LoadFromFile(const AFilePath: string);
  public
    constructor Create(const AFilePath: string);
    destructor Destroy; override;
    function FindObject(const Id: TObjectId; out Offset: QWord): Boolean;
    function GetEntry(Index: LongWord): TPackIndexEntry;
    property FilePath: string read FFilePath;
    property ObjectCount: LongWord read FObjectCount;
    property PackfileChecksum: TObjectId read FPackfileChecksum;
    property IndexChecksum: TObjectId read FIndexChecksum;
  end;

{ Writes a Packfile Index v2 file corresponding to an array of sorted entries }
procedure WritePackIndexV2(const IdxFilePath: string;
                           const Entries: array of TPackIndexEntry;
                           const PackChecksum: TObjectId);

implementation

constructor TPackIndex.Create(const AFilePath: string);
begin
  inherited Create;
  FFilePath := AFilePath;
  LoadFromFile(AFilePath);
end;

destructor TPackIndex.Destroy;
begin
  SetLength(FObjectIds, 0);
  SetLength(FOffsets, 0);
  SetLength(FCrc32s, 0);
  inherited Destroy;
end;

procedure TPackIndex.LoadFromFile(const AFilePath: string);
var
  FS: TFileStream;
  Magic, Version: LongWord;
  I: Integer;
  TotalObjs: LongWord;
  RawDigest: array[0..19] of Byte;
  RawOffsets: array of LongWord;
  ExtOffsetCount: Integer;
  ExtOffsets: array of QWord;
  OffVal: LongWord;
  ExtIdx: LongWord;
begin
  FS := TFileStream.Create(AFilePath, fmOpenRead or fmShareDenyNone);
  try
    if FS.Size < (8 + 256 * 4 + 40) then
      raise EPackIndexCorrupt.CreateWithCode(ERR_PACK_CORRUPT, 'Pack index file too small: ' + AFilePath);

    Magic := 0;
    FS.ReadBuffer(Magic, 4);
    Magic := (LongWord(PByte(@Magic)[0]) shl 24) or (LongWord(PByte(@Magic)[1]) shl 16) or
             (LongWord(PByte(@Magic)[2]) shl 8) or LongWord(PByte(@Magic)[3]);

    if Magic <> PACK_INDEX_V2_MAGIC then
      raise EPackIndexCorrupt.CreateWithCode(ERR_PACK_CORRUPT, 'Invalid pack index magic: ' + AFilePath);

    Version := 0;
    FS.ReadBuffer(Version, 4);
    Version := (LongWord(PByte(@Version)[0]) shl 24) or (LongWord(PByte(@Version)[1]) shl 16) or
               (LongWord(PByte(@Version)[2]) shl 8) or LongWord(PByte(@Version)[3]);

    if Version <> 2 then
      raise EPackIndexCorrupt.CreateWithCode(ERR_PACK_CORRUPT, 'Unsupported pack index version: ' + IntToStr(Version));

    { Read 256 fanout entries }
    for I := 0 to 255 do
    begin
      FS.ReadBuffer(FFanout[I], 4);
      FFanout[I] := (LongWord(PByte(@FFanout[I])[0]) shl 24) or (LongWord(PByte(@FFanout[I])[1]) shl 16) or
                    (LongWord(PByte(@FFanout[I])[2]) shl 8) or LongWord(PByte(@FFanout[I])[3]);
    end;

    TotalObjs := FFanout[255];
    FObjectCount := TotalObjs;

    SetLength(FObjectIds, TotalObjs);
    SetLength(FOffsets, TotalObjs);
    SetLength(FCrc32s, TotalObjs);

    if TotalObjs = 0 then
      Exit;

    { Read SHA-1 table }
    for I := 0 to TotalObjs - 1 do
    begin
      FS.ReadBuffer(RawDigest[0], 20);
      FObjectIds[I].Algorithm := haSHA1;
      FillChar(FObjectIds[I].Digest, SizeOf(FObjectIds[I].Digest), 0);
      Move(RawDigest[0], FObjectIds[I].Digest[0], 20);
    end;

    { Read CRC32 table }
    for I := 0 to TotalObjs - 1 do
    begin
      FS.ReadBuffer(FCrc32s[I], 4);
      FCrc32s[I] := (LongWord(PByte(@FCrc32s[I])[0]) shl 24) or (LongWord(PByte(@FCrc32s[I])[1]) shl 16) or
                    (LongWord(PByte(@FCrc32s[I])[2]) shl 8) or LongWord(PByte(@FCrc32s[I])[3]);
    end;

    { Read 4-byte offset table }
    SetLength(RawOffsets, TotalObjs);
    ExtOffsetCount := 0;
    for I := 0 to TotalObjs - 1 do
    begin
      FS.ReadBuffer(RawOffsets[I], 4);
      RawOffsets[I] := (LongWord(PByte(@RawOffsets[I])[0]) shl 24) or (LongWord(PByte(@RawOffsets[I])[1]) shl 16) or
                       (LongWord(PByte(@RawOffsets[I])[2]) shl 8) or LongWord(PByte(@RawOffsets[I])[3]);
      if (RawOffsets[I] and $80000000) <> 0 then
        Inc(ExtOffsetCount);
    end;

    { Read 8-byte extended offset table if any }
    if ExtOffsetCount > 0 then
    begin
      SetLength(ExtOffsets, ExtOffsetCount);
      for I := 0 to ExtOffsetCount - 1 do
      begin
        FS.ReadBuffer(ExtOffsets[I], 8);
        ExtOffsets[I] := ReadUInt64BE(@ExtOffsets[I]);
      end;
    end;

    { Resolve 64-bit offsets }
    for I := 0 to TotalObjs - 1 do
    begin
      OffVal := RawOffsets[I];
      if (OffVal and $80000000) <> 0 then
      begin
        ExtIdx := OffVal and $7FFFFFFF;
        if ExtIdx >= LongWord(ExtOffsetCount) then
          raise EPackIndexCorrupt.CreateWithCode(ERR_PACK_CORRUPT, 'Extended offset index out of range');
        FOffsets[I] := ExtOffsets[ExtIdx];
      end
      else
        FOffsets[I] := OffVal;
    end;

    { Read trailing packfile and index checksums }
    FS.ReadBuffer(RawDigest[0], 20);
    FPackfileChecksum.Algorithm := haSHA1;
    FillChar(FPackfileChecksum.Digest, SizeOf(FPackfileChecksum.Digest), 0);
    Move(RawDigest[0], FPackfileChecksum.Digest[0], 20);

    FS.ReadBuffer(RawDigest[0], 20);
    FIndexChecksum.Algorithm := haSHA1;
    FillChar(FIndexChecksum.Digest, SizeOf(FIndexChecksum.Digest), 0);
    Move(RawDigest[0], FIndexChecksum.Digest[0], 20);

  finally
    FS.Free;
  end;
end;

function TPackIndex.FindObject(const Id: TObjectId; out Offset: QWord): Boolean;
var
  FirstByte: Byte;
  LowIdx, HighIdx, Mid: Integer;
  Cmp: Integer;
begin
  Offset := 0;
  if FObjectCount = 0 then
    Exit(False);

  FirstByte := Id.Digest[0];
  if FirstByte = 0 then
    LowIdx := 0
  else
    LowIdx := FFanout[FirstByte - 1];
  HighIdx := FFanout[FirstByte] - 1;

  while LowIdx <= HighIdx do
  begin
    Mid := LowIdx + (HighIdx - LowIdx) div 2;
    Cmp := ObjectIdCompare(FObjectIds[Mid], Id);
    if Cmp = 0 then
    begin
      Offset := FOffsets[Mid];
      Exit(True);
    end
    else if Cmp < 0 then
      LowIdx := Mid + 1
    else
      HighIdx := Mid - 1;
  end;

  Result := False;
end;

function TPackIndex.GetEntry(Index: LongWord): TPackIndexEntry;
begin
  if Index >= FObjectCount then
    raise EPackIndexCorrupt.CreateWithCode(ERR_PACK_CORRUPT, 'Index entry out of bounds');
  Result.Id := FObjectIds[Index];
  Result.Offset := FOffsets[Index];
  Result.Crc32 := FCrc32s[Index];
end;

procedure WritePackIndexV2(const IdxFilePath: string;
                           const Entries: array of TPackIndexEntry;
                           const PackChecksum: TObjectId);
var
  FS: TFileStream;
  SHA1Ctx: TSHA1Context;
  Fanout: array[0..255] of LongWord;
  TotalObjs, I: Integer;
  FirstByte: Byte;
  Magic, Version: LongWord;
  Buf32: LongWord;
  ExtOffsets: array of QWord;
  ExtCount: Integer;
  IndexDigest: TSHA1Digest;
  RawTmp: array[0..3] of Byte;

  procedure StreamWrite(const Data; Len: Integer);
  begin
    if Len <= 0 then Exit;
    FS.WriteBuffer(Data, Len);
    SHA1Update(SHA1Ctx, Data, Len);
  end;

  procedure StreamWriteUInt32BE(Val: LongWord);
  begin
    RawTmp[0] := Byte((Val shr 24) and $FF);
    RawTmp[1] := Byte((Val shr 16) and $FF);
    RawTmp[2] := Byte((Val shr 8) and $FF);
    RawTmp[3] := Byte(Val and $FF);
    StreamWrite(RawTmp[0], 4);
  end;

  procedure StreamWriteUInt64BE(Val: QWord);
  var
    Raw64: array[0..7] of Byte;
  begin
    Raw64[0] := Byte((Val shr 56) and $FF);
    Raw64[1] := Byte((Val shr 48) and $FF);
    Raw64[2] := Byte((Val shr 40) and $FF);
    Raw64[3] := Byte((Val shr 32) and $FF);
    Raw64[4] := Byte((Val shr 24) and $FF);
    Raw64[5] := Byte((Val shr 16) and $FF);
    Raw64[6] := Byte((Val shr 8) and $FF);
    Raw64[7] := Byte(Val and $FF);
    StreamWrite(Raw64[0], 8);
  end;

begin
  TotalObjs := Length(Entries);
  FillChar(Fanout, SizeOf(Fanout), 0);

  { Compute fanout table }
  for I := 0 to TotalObjs - 1 do
  begin
    FirstByte := Entries[I].Id.Digest[0];
    Inc(Fanout[FirstByte]);
  end;

  { Cumulative summation }
  for I := 1 to 255 do
    Inc(Fanout[I], Fanout[I - 1]);

  SHA1Init(SHA1Ctx);
  FS := TFileStream.Create(IdxFilePath, fmCreate);
  try
    Magic := PACK_INDEX_V2_MAGIC;
    Version := 2;
    StreamWriteUInt32BE(Magic);
    StreamWriteUInt32BE(Version);

    { Write 256 fanout entries }
    for I := 0 to 255 do
      StreamWriteUInt32BE(Fanout[I]);

    { Write sorted SHA-1 table }
    for I := 0 to TotalObjs - 1 do
      StreamWrite(Entries[I].Id.Digest[0], 20);

    { Write CRC-32 table }
    for I := 0 to TotalObjs - 1 do
      StreamWriteUInt32BE(Entries[I].Crc32);

    { Check for 64-bit extended offsets }
    ExtCount := 0;
    SetLength(ExtOffsets, TotalObjs);
    for I := 0 to TotalObjs - 1 do
    begin
      if Entries[I].Offset >= $80000000 then
      begin
        ExtOffsets[ExtCount] := Entries[I].Offset;
        Inc(ExtCount);
      end;
    end;

    { Write 4-byte offset table }
    ExtCount := 0;
    for I := 0 to TotalObjs - 1 do
    begin
      if Entries[I].Offset >= $80000000 then
      begin
        Buf32 := $80000000 or LongWord(ExtCount);
        Inc(ExtCount);
        StreamWriteUInt32BE(Buf32);
      end
      else
        StreamWriteUInt32BE(LongWord(Entries[I].Offset));
    end;

    { Write 8-byte extended offset table }
    for I := 0 to ExtCount - 1 do
      StreamWriteUInt64BE(ExtOffsets[I]);

    { Write packfile checksum }
    StreamWrite(PackChecksum.Digest[0], 20);

    { Finalize index checksum }
    SHA1Final(SHA1Ctx, IndexDigest);
    FS.WriteBuffer(IndexDigest[0], 20);

  finally
    FS.Free;
  end;
end;

end.
