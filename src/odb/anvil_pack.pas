{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Git Packfile Version 2 (.pack) reader and delta decompression engine.
  Resolves OBJ_OFS_DELTA and OBJ_REF_DELTA delta chains using sliding
  window base recovery and copy/insert bytecode instruction execution.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_pack;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, zstream, anvil_types, anvil_errors, anvil_utils,
  anvil_sha1, anvil_crc32, anvil_pack_index, anvil_object, anvil_loose;

const
  PACK_SIGNATURE = $5041434B; { "PACK" }

type
  { Base resolver callback for resolving REF_DELTA base objects }
  TBaseObjectResolver = function(const BaseId: TObjectId; out BaseType: TObjectType; out BaseData: TByteArray): Boolean of object;

  { Packfile reader }
  TPackfile = class
  private
    FPackPath: string;
    FIndex: TPackIndex;
    FStream: TFileStream;
    FObjectCount: LongWord;
    FChecksum: TObjectId;
    FResolver: TBaseObjectResolver;
    procedure ReadHeader;
    function ApplyDelta(const BaseData: TByteArray; const DeltaData: TByteArray): TByteArray;
  public
    constructor Create(const APackPath, AIdxPath: string; Resolver: TBaseObjectResolver = nil);
    destructor Destroy; override;
    function ReadObjectAtOffset(Offset: QWord; out ObjType: TObjectType; out Data: TByteArray): Boolean;
    function ReadObject(const Id: TObjectId; out ObjType: TObjectType; out Data: TByteArray): Boolean;
    function ContainsObject(const Id: TObjectId): Boolean;
    property PackPath: string read FPackPath;
    property Index: TPackIndex read FIndex;
    property ObjectCount: LongWord read FObjectCount;
    property Checksum: TObjectId read FChecksum;
  end;

function ExecuteDeltaInstructions(const BaseData: Pointer; BaseLen: SizeInt;
                                  const DeltaData: Pointer; DeltaLen: SizeInt): TByteArray;

implementation

constructor TPackfile.Create(const APackPath, AIdxPath: string; Resolver: TBaseObjectResolver);
begin
  inherited Create;
  FPackPath := APackPath;
  FResolver := Resolver;
  FIndex := TPackIndex.Create(AIdxPath);
  FStream := TFileStream.Create(APackPath, fmOpenRead or fmShareDenyNone);
  ReadHeader;
end;

destructor TPackfile.Destroy;
begin
  if Assigned(FStream) then
    FStream.Free;
  if Assigned(FIndex) then
    FIndex.Free;
  inherited Destroy;
end;

procedure TPackfile.ReadHeader;
var
  Magic, Version, Count: LongWord;
  RawDigest: array[0..19] of Byte;
begin
  FStream.Position := 0;
  if FStream.Size < 32 then
    raise EPackCorrupt.CreateWithCode(ERR_PACK_CORRUPT, 'Packfile smaller than header and checksum: ' + FPackPath);

  Magic := 0;
  FStream.ReadBuffer(Magic, 4);
  Magic := (LongWord(PByte(@Magic)[0]) shl 24) or (LongWord(PByte(@Magic)[1]) shl 16) or
           (LongWord(PByte(@Magic)[2]) shl 8) or LongWord(PByte(@Magic)[3]);

  if Magic <> PACK_SIGNATURE then
    raise EPackCorrupt.CreateWithCode(ERR_PACK_CORRUPT, 'Invalid packfile signature: ' + FPackPath);

  Version := 0;
  FStream.ReadBuffer(Version, 4);
  Version := (LongWord(PByte(@Version)[0]) shl 24) or (LongWord(PByte(@Version)[1]) shl 16) or
             (LongWord(PByte(@Version)[2]) shl 8) or LongWord(PByte(@Version)[3]);

  if Version <> 2 then
    raise EPackCorrupt.CreateWithCode(ERR_PACK_CORRUPT, 'Unsupported packfile version: ' + IntToStr(Version));

  Count := 0;
  FStream.ReadBuffer(Count, 4);
  FObjectCount := (LongWord(PByte(@Count)[0]) shl 24) or (LongWord(PByte(@Count)[1]) shl 16) or
                  (LongWord(PByte(@Count)[2]) shl 8) or LongWord(PByte(@Count)[3]);

  { Read trailing 20-byte packfile checksum }
  FStream.Position := FStream.Size - 20;
  FStream.ReadBuffer(RawDigest[0], 20);
  FChecksum.Algorithm := haSHA1;
  FillChar(FChecksum.Digest, SizeOf(FChecksum.Digest), 0);
  Move(RawDigest[0], FChecksum.Digest[0], 20);
end;

function TPackfile.ContainsObject(const Id: TObjectId): Boolean;
var
  DummyOffset: QWord;
begin
  Result := FIndex.FindObject(Id, DummyOffset);
end;

function TPackfile.ReadObject(const Id: TObjectId; out ObjType: TObjectType; out Data: TByteArray): Boolean;
var
  Offset: QWord;
begin
  ObjType := otNone;
  Data := nil;
  if not FIndex.FindObject(Id, Offset) then
    Exit(False);
  Result := ReadObjectAtOffset(Offset, ObjType, Data);
end;

function TPackfile.ReadObjectAtOffset(Offset: QWord; out ObjType: TObjectType; out Data: TByteArray): Boolean;
var
  B: Byte;
  TypeNum: Byte;
  UncompressedSize: QWord;
  Shift: Integer;
  BaseOffsetDelta: Int64;
  BaseId: TObjectId;
  RawDigest: array[0..19] of Byte;
  BaseData, DeltaData: TByteArray;
  BaseType: TObjectType;
  ResolvedBase: Boolean;
begin
  ObjType := otNone;
  Data := nil;

  FStream.Position := Offset;

  { Read object type and uncompressed size from variable-length header }
  FStream.ReadBuffer(B, 1);
  TypeNum := (B shr 4) and 7;
  UncompressedSize := B and $0F;
  Shift := 4;

  while (B and $80) <> 0 do
  begin
    FStream.ReadBuffer(B, 1);
    UncompressedSize := UncompressedSize or (QWord(B and $7F) shl Shift);
    Inc(Shift, 7);
  end;

  ObjType := PackTypeToObjectType(TypeNum);

  case ObjType of
    otCommit, otTree, otBlob, otTag:
    begin
      { Standard non-delta object: directly decompress zlib payload }
      Data := ZlibDecompressStream(FStream);
    end;

    otOfsDelta:
    begin
      { Read negative offset back from current object start }
      BaseOffsetDelta := 0;
      FStream.ReadBuffer(B, 1);
      BaseOffsetDelta := B and $7F;
      while (B and $80) <> 0 do
      begin
        FStream.ReadBuffer(B, 1);
        BaseOffsetDelta := ((BaseOffsetDelta + 1) shl 7) or (B and $7F);
      end;

      { Decompress delta payload }
      DeltaData := ZlibDecompressStream(FStream);

      { Recursively resolve base object }
      if not ReadObjectAtOffset(Offset - BaseOffsetDelta, BaseType, BaseData) then
        raise EPackCorrupt.CreateWithCode(ERR_PACK_CORRUPT, 'Failed to resolve OFS_DELTA base object');

      ObjType := BaseType;
      Data := ApplyDelta(BaseData, DeltaData);
    end;

    otRefDelta:
    begin
      { Read 20-byte base object ID }
      FStream.ReadBuffer(RawDigest[0], 20);
      BaseId.Algorithm := haSHA1;
      FillChar(BaseId.Digest, SizeOf(BaseId.Digest), 0);
      Move(RawDigest[0], BaseId.Digest[0], 20);

      { Decompress delta payload }
      DeltaData := ZlibDecompressStream(FStream);

      { Look up base object in this packfile first }
      ResolvedBase := False;
      BaseType := otNone;
      BaseData := nil;
      if ContainsObject(BaseId) then
        ResolvedBase := ReadObject(BaseId, BaseType, BaseData);

      { Fall back to external resolver if needed }
      if (not ResolvedBase) and Assigned(FResolver) then
        ResolvedBase := FResolver(BaseId, BaseType, BaseData);

      if not ResolvedBase then
        raise EPackCorrupt.CreateWithCode(ERR_PACK_CORRUPT,
          'Failed to resolve REF_DELTA base object: ' + ObjectIdToHex(BaseId));

      ObjType := BaseType;
      Data := ApplyDelta(BaseData, DeltaData);
    end;
  else
    raise EPackCorrupt.CreateWithCode(ERR_PACK_CORRUPT, 'Unknown packed object type: ' + IntToStr(TypeNum));
  end;

  Result := True;
end;

function TPackfile.ApplyDelta(const BaseData: TByteArray; const DeltaData: TByteArray): TByteArray;
begin
  if (Length(BaseData) = 0) or (Length(DeltaData) = 0) then
    Exit(nil);
  Result := ExecuteDeltaInstructions(@BaseData[0], Length(BaseData),
                                     @DeltaData[0], Length(DeltaData));
end;

function ExecuteDeltaInstructions(const BaseData: Pointer; BaseLen: SizeInt;
                                  const DeltaData: Pointer; DeltaLen: SizeInt): TByteArray;
var
  P, PEnd: PByte;
  BaseP: PByte;
  SrcSize, TargetSize: QWord;
  Shift: Integer;
  B, Opcode: Byte;
  CopyOffset, CopySize: LongWord;
  OutMS: TMemoryStream;
begin
  Result := nil;
  P := PByte(DeltaData);
  PEnd := P + DeltaLen;
  BaseP := PByte(BaseData);

  { Read source size varint }
  SrcSize := 0;
  Shift := 0;
  repeat
    if P >= PEnd then
      raise EPackCorrupt.CreateWithCode(ERR_PACK_CORRUPT, 'Truncated delta header: source size');
    B := P^;
    Inc(P);
    SrcSize := SrcSize or (QWord(B and $7F) shl Shift);
    Inc(Shift, 7);
  until (B and $80) = 0;

  if SrcSize <> QWord(BaseLen) then
    raise EPackCorrupt.CreateWithCode(ERR_PACK_CORRUPT,
      Format('Delta source size mismatch: expected %d, got %d', [BaseLen, SrcSize]));

  { Read target size varint }
  TargetSize := 0;
  Shift := 0;
  repeat
    if P >= PEnd then
      raise EPackCorrupt.CreateWithCode(ERR_PACK_CORRUPT, 'Truncated delta header: target size');
    B := P^;
    Inc(P);
    TargetSize := TargetSize or (QWord(B and $7F) shl Shift);
    Inc(Shift, 7);
  until (B and $80) = 0;

  OutMS := TMemoryStream.Create;
  try
    while P < PEnd do
    begin
      Opcode := P^;
      Inc(P);

      if (Opcode and $80) <> 0 then
      begin
        { Copy opcode: copy from base buffer }
        CopyOffset := 0;
        CopySize := 0;

        if (Opcode and $01) <> 0 then begin CopyOffset := CopyOffset or LongWord(P^); Inc(P); end;
        if (Opcode and $02) <> 0 then begin CopyOffset := CopyOffset or (LongWord(P^) shl 8); Inc(P); end;
        if (Opcode and $04) <> 0 then begin CopyOffset := CopyOffset or (LongWord(P^) shl 16); Inc(P); end;
        if (Opcode and $08) <> 0 then begin CopyOffset := CopyOffset or (LongWord(P^) shl 24); Inc(P); end;

        if (Opcode and $10) <> 0 then begin CopySize := CopySize or LongWord(P^); Inc(P); end;
        if (Opcode and $20) <> 0 then begin CopySize := CopySize or (LongWord(P^) shl 8); Inc(P); end;
        if (Opcode and $40) <> 0 then begin CopySize := CopySize or (LongWord(P^) shl 16); Inc(P); end;

        if CopySize = 0 then
          CopySize := $10000; { 65536 bytes }

        if (CopyOffset + CopySize > QWord(BaseLen)) then
          raise EPackCorrupt.CreateWithCode(ERR_PACK_CORRUPT, 'Delta copy instruction exceeds base bounds');

        OutMS.WriteBuffer((BaseP + CopyOffset)^, CopySize);
      end
      else if Opcode > 0 then
      begin
        { Insert opcode: copy literal bytes from delta stream }
        if P + Opcode > PEnd then
          raise EPackCorrupt.CreateWithCode(ERR_PACK_CORRUPT, 'Delta insert instruction exceeds stream bounds');

        OutMS.WriteBuffer(P^, Opcode);
        Inc(P, Opcode);
      end
      else
        raise EPackCorrupt.CreateWithCode(ERR_PACK_CORRUPT, 'Invalid delta opcode 0');
    end;

    if OutMS.Size <> Int64(TargetSize) then
      raise EPackCorrupt.CreateWithCode(ERR_PACK_CORRUPT,
        Format('Reconstructed delta size mismatch: expected %d, produced %d', [TargetSize, OutMS.Size]));

    SetLength(Result, OutMS.Size);
    if OutMS.Size > 0 then
    begin
      OutMS.Position := 0;
      OutMS.ReadBuffer(Result[0], OutMS.Size);
    end;

  finally
    OutMS.Free;
  end;
end;

end.
