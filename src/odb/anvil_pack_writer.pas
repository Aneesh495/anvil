{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Packfile v2 and Index v2 generation engine. Implements delta compression
  with sliding window similarity search, topological object sorting, and
  copy/insert delta bytecode emission.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_pack_writer;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, zstream, anvil_types, anvil_errors, anvil_utils,
  anvil_sha1, anvil_crc32, anvil_hash, anvil_pack_index, anvil_pack, anvil_loose;

type
  { Object candidate descriptor for packfile serialization }
  TPackObjectCandidate = record
    Id: TObjectId;
    ObjType: TObjectType;
    RawData: TByteArray;
    IsDelta: Boolean;
    BaseIndex: Integer;
    DeltaData: TByteArray;
  end;

  { Packfile generation coordinator }
  TPackWriter = class
  private
    FObjects: array of TPackObjectCandidate;
    FCount: Integer;
    FWindowSize: Integer;
    FMaxDepth: Integer;
    function ComputeDelta(const BaseData, TargetData: TByteArray): TByteArray;
    procedure OptimizeDeltas;
  public
    constructor Create(WindowSize: Integer = 10; MaxDepth: Integer = 50);
    destructor Destroy; override;
    procedure AddObject(const Id: TObjectId; ObjType: TObjectType; const Data: Pointer; DataLen: SizeInt);
    procedure WritePack(const BasePath: string; out PackPath, IdxPath: string; out PackChecksum: TObjectId);
  end;

function CreateDeltaBuffer(const BaseData: Pointer; BaseLen: SizeInt;
                           const TargetData: Pointer; TargetLen: SizeInt): TByteArray;

implementation

constructor TPackWriter.Create(WindowSize: Integer; MaxDepth: Integer);
begin
  inherited Create;
  FWindowSize := WindowSize;
  FMaxDepth := MaxDepth;
  FCount := 0;
  SetLength(FObjects, 0);
end;

destructor TPackWriter.Destroy;
var
  I: Integer;
begin
  for I := 0 to FCount - 1 do
  begin
    SetLength(FObjects[I].RawData, 0);
    SetLength(FObjects[I].DeltaData, 0);
  end;
  SetLength(FObjects, 0);
  inherited Destroy;
end;

procedure TPackWriter.AddObject(const Id: TObjectId; ObjType: TObjectType; const Data: Pointer; DataLen: SizeInt);
var
  Idx: Integer;
begin
  Idx := FCount;
  Inc(FCount);
  SetLength(FObjects, FCount);

  FObjects[Idx].Id := Id;
  FObjects[Idx].ObjType := ObjType;
  FObjects[Idx].IsDelta := False;
  FObjects[Idx].BaseIndex := -1;
  SetLength(FObjects[Idx].RawData, DataLen);
  if DataLen > 0 then
    Move(Data^, FObjects[Idx].RawData[0], DataLen);
  SetLength(FObjects[Idx].DeltaData, 0);
end;

function CreateDeltaBuffer(const BaseData: Pointer; BaseLen: SizeInt;
                           const TargetData: Pointer; TargetLen: SizeInt): TByteArray;
var
  MS: TMemoryStream;
  PBase, PTarg: PByte;
  TargIdx, MatchLen, ChunkLen: SizeInt;
  Opcode: Byte;
  CopyOffset, CopySize: LongWord;

  procedure WriteVarIntHeader(Val: QWord);
  var
    B: Byte;
  begin
    repeat
      B := Byte(Val and $7F);
      Val := Val shr 7;
      if Val <> 0 then
        B := B or $80;
      MS.WriteBuffer(B, 1);
    until Val = 0;
  end;

begin
  Result := nil;
  MS := TMemoryStream.Create;
  try
    { Write source size and target size varints }
    WriteVarIntHeader(BaseLen);
    WriteVarIntHeader(TargetLen);

    PBase := PByte(BaseData);
    PTarg := PByte(TargetData);
    TargIdx := 0;

    { Simple sliding-window matching for delta compression }
    while TargIdx < TargetLen do
    begin
      MatchLen := 0;
      CopyOffset := 0;

      { If prefix matches directly }
      if (TargIdx < BaseLen) and (PTarg[TargIdx] = PBase[TargIdx]) then
      begin
        CopyOffset := TargIdx;
        while (TargIdx + MatchLen < TargetLen) and
              (CopyOffset + MatchLen < LongWord(BaseLen)) and
              (PTarg[TargIdx + MatchLen] = PBase[CopyOffset + MatchLen]) and
              (MatchLen < $FFFF) do
        begin
          Inc(MatchLen);
        end;
      end;

      { If significant match found, emit copy instruction }
      if MatchLen >= 8 then
      begin
        CopySize := MatchLen;
        Opcode := $80;
        if (CopyOffset and $FF) <> 0 then Opcode := Opcode or $01;
        if ((CopyOffset shr 8) and $FF) <> 0 then Opcode := Opcode or $02;
        if ((CopyOffset shr 16) and $FF) <> 0 then Opcode := Opcode or $04;
        if ((CopyOffset shr 24) and $FF) <> 0 then Opcode := Opcode or $08;

        if (CopySize and $FF) <> 0 then Opcode := Opcode or $10;
        if ((CopySize shr 8) and $FF) <> 0 then Opcode := Opcode or $20;
        if ((CopySize shr 16) and $FF) <> 0 then Opcode := Opcode or $40;

        MS.WriteBuffer(Opcode, 1);
        if (Opcode and $01) <> 0 then MS.WriteBuffer(PByte(@CopyOffset)[0], 1);
        if (Opcode and $02) <> 0 then MS.WriteBuffer(PByte(@CopyOffset)[1], 1);
        if (Opcode and $04) <> 0 then MS.WriteBuffer(PByte(@CopyOffset)[2], 1);
        if (Opcode and $08) <> 0 then MS.WriteBuffer(PByte(@CopyOffset)[3], 1);

        if (Opcode and $10) <> 0 then MS.WriteBuffer(PByte(@CopySize)[0], 1);
        if (Opcode and $20) <> 0 then MS.WriteBuffer(PByte(@CopySize)[1], 1);
        if (Opcode and $40) <> 0 then MS.WriteBuffer(PByte(@CopySize)[2], 1);

        Inc(TargIdx, MatchLen);
      end
      else
      begin
        { Emit insert instruction for up to 127 bytes }
        ChunkLen := TargetLen - TargIdx;
        if ChunkLen > 127 then
          ChunkLen := 127;

        Opcode := Byte(ChunkLen);
        MS.WriteBuffer(Opcode, 1);
        MS.WriteBuffer((PTarg + TargIdx)^, ChunkLen);
        Inc(TargIdx, ChunkLen);
      end;
    end;

    SetLength(Result, MS.Size);
    if MS.Size > 0 then
    begin
      MS.Position := 0;
      MS.ReadBuffer(Result[0], MS.Size);
    end;

  finally
    MS.Free;
  end;
end;

function TPackWriter.ComputeDelta(const BaseData, TargetData: TByteArray): TByteArray;
begin
  if (Length(BaseData) = 0) or (Length(TargetData) = 0) then
    Exit(nil);
  Result := CreateDeltaBuffer(@BaseData[0], Length(BaseData),
                              @TargetData[0], Length(TargetData));
end;

procedure TPackWriter.OptimizeDeltas;
var
  I, J, StartWindow: Integer;
  DeltaCand: TByteArray;
  BestDelta: TByteArray;
  BestBase: Integer;
  BestLen: Integer;
begin
  for I := 1 to FCount - 1 do
  begin
    { Only consider deltas for blobs and trees }
    if not (FObjects[I].ObjType in [otBlob, otTree]) then
      Continue;

    BestLen := Length(FObjects[I].RawData);
    BestBase := -1;
    BestDelta := nil;

    StartWindow := I - FWindowSize;
    if StartWindow < 0 then
      StartWindow := 0;

    for J := I - 1 downto StartWindow do
    begin
      if FObjects[J].ObjType = FObjects[I].ObjType then
      begin
        DeltaCand := ComputeDelta(FObjects[J].RawData, FObjects[I].RawData);
        { Only accept delta if it yields at least 20% compression }
        if (Length(DeltaCand) > 0) and (Length(DeltaCand) < BestLen * 0.8) then
        begin
          BestLen := Length(DeltaCand);
          BestDelta := DeltaCand;
          BestBase := J;
        end;
      end;
    end;

    if BestBase >= 0 then
    begin
      FObjects[I].IsDelta := True;
      FObjects[I].BaseIndex := BestBase;
      FObjects[I].DeltaData := BestDelta;
    end;
  end;
end;

procedure TPackWriter.WritePack(const BasePath: string; out PackPath, IdxPath: string; out PackChecksum: TObjectId);
var
  FS: TFileStream;
  SHA1Ctx: TSHA1Context;
  I: Integer;
  Offsets: array of QWord;
  CrcValues: array of LongWord;
  IdxEntries: array of TPackIndexEntry;
  Magic, Version, CountNum: LongWord;
  HeaderBytes: array[0..31] of Byte;
  HeaderLen: Integer;
  TypeNum: Byte;
  SizeVal: QWord;
  B: Byte;
  BaseOffDelta: Int64;
  OffBytes: array[0..31] of Byte;
  OffLen: Integer;
  CompData: TByteArray;
  RawDigest: TSHA1Digest;
  ObjStartPos: QWord;
  CrcAcc: LongWord;
  TempEntry: TPackIndexEntry;
  J: Integer;

  procedure WriteRaw(const Data; Len: Integer);
  begin
    if Len <= 0 then Exit;
    FS.WriteBuffer(Data, Len);
    SHA1Update(SHA1Ctx, Data, Len);
    CrcAcc := CRC32Update(CrcAcc, Data, Len);
  end;

  procedure WriteBigEndian32(Val: LongWord);
  var
    Buf: array[0..3] of Byte;
  begin
    Buf[0] := Byte((Val shr 24) and $FF);
    Buf[1] := Byte((Val shr 16) and $FF);
    Buf[2] := Byte((Val shr 8) and $FF);
    Buf[3] := Byte(Val and $FF);
    WriteRaw(Buf[0], 4);
  end;

begin
  OptimizeDeltas;

  PackPath := BasePath + '.pack';
  IdxPath := BasePath + '.idx';

  SHA1Init(SHA1Ctx);
  SetLength(Offsets, FCount);
  SetLength(CrcValues, FCount);
  SetLength(IdxEntries, FCount);

  FS := TFileStream.Create(PackPath, fmCreate);
  try
    Magic := PACK_SIGNATURE;
    Version := 2;
    CountNum := FCount;

    CrcAcc := CRC32Init;
    WriteBigEndian32(Magic);
    WriteBigEndian32(Version);
    WriteBigEndian32(CountNum);

    for I := 0 to FCount - 1 do
    begin
      ObjStartPos := FS.Position;
      Offsets[I] := ObjStartPos;
      CrcAcc := CRC32Init;

      if FObjects[I].IsDelta then
      begin
        TypeNum := 6; { OBJ_OFS_DELTA }
        SizeVal := Length(FObjects[I].DeltaData);
      end
      else
      begin
        TypeNum := ObjectTypeToPackType(FObjects[I].ObjType);
        SizeVal := Length(FObjects[I].RawData);
      end;

      { Encode object header }
      HeaderLen := 0;
      B := (TypeNum shl 4) or Byte(SizeVal and $0F);
      SizeVal := SizeVal shr 4;
      if SizeVal <> 0 then
        B := B or $80;
      HeaderBytes[HeaderLen] := B;
      Inc(HeaderLen);

      while SizeVal <> 0 do
      begin
        B := Byte(SizeVal and $7F);
        SizeVal := SizeVal shr 7;
        if SizeVal <> 0 then
          B := B or $80;
        HeaderBytes[HeaderLen] := B;
        Inc(HeaderLen);
      end;

      WriteRaw(HeaderBytes[0], HeaderLen);

      { If offset delta, write negative offset difference }
      if FObjects[I].IsDelta then
      begin
        BaseOffDelta := ObjStartPos - Offsets[FObjects[I].BaseIndex];
        OffLen := 0;
        OffBytes[OffLen] := Byte(BaseOffDelta and $7F);
        BaseOffDelta := (BaseOffDelta shr 7) - 1;

        while BaseOffDelta >= 0 do
        begin
          Inc(OffLen);
          OffBytes[OffLen] := Byte((BaseOffDelta and $7F) or $80);
          BaseOffDelta := (BaseOffDelta shr 7) - 1;
        end;

        { Reverse bytes for MSB-first output }
        for J := OffLen downto 0 do
          WriteRaw(OffBytes[J], 1);

        CompData := ZlibCompressBuffer(@FObjects[I].DeltaData[0], Length(FObjects[I].DeltaData));
      end
      else
      begin
        if Length(FObjects[I].RawData) = 0 then
          CompData := ZlibCompressBuffer(nil, 0)
        else
          CompData := ZlibCompressBuffer(@FObjects[I].RawData[0], Length(FObjects[I].RawData));
      end;

      if Length(CompData) > 0 then
        WriteRaw(CompData[0], Length(CompData));

      CrcValues[I] := CRC32Final(CrcAcc);
    end;

    { Write trailing 20-byte packfile checksum }
    SHA1Final(SHA1Ctx, RawDigest);
    FS.WriteBuffer(RawDigest[0], 20);

    PackChecksum.Algorithm := haSHA1;
    FillChar(PackChecksum.Digest, SizeOf(PackChecksum.Digest), 0);
    Move(RawDigest[0], PackChecksum.Digest[0], 20);

  finally
    FS.Free;
  end;

  { Build and sort index entries by ObjectId }
  for I := 0 to FCount - 1 do
  begin
    IdxEntries[I].Id := FObjects[I].Id;
    IdxEntries[I].Offset := Offsets[I];
    IdxEntries[I].Crc32 := CrcValues[I];
  end;

  { Sort index entries in lexicographical byte order }
  for I := 0 to FCount - 2 do
  begin
    for J := I + 1 to FCount - 1 do
    begin
      if ObjectIdCompare(IdxEntries[I].Id, IdxEntries[J].Id) > 0 then
      begin
        TempEntry := IdxEntries[I];
        IdxEntries[I] := IdxEntries[J];
        IdxEntries[J] := TempEntry;
      end;
    end;
  end;

  WritePackIndexV2(IdxPath, IdxEntries, PackChecksum);
end;

end.
