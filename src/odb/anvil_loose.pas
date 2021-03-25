{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Loose object storage manager. Handles zlib deflation/inflation,
  atomic write-via-rename, object header decoding, and file path sharding.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_loose;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, zstream, anvil_types, anvil_errors, anvil_utils, anvil_hash, anvil_object;

type
  { Loose object backend }
  TLooseBackend = class
  private
    FObjectsDir: string;
    FAlgo: THashAlgorithm;
  public
    constructor Create(const AObjectsDir: string; Algo: THashAlgorithm = haSHA1);
    function GetObjectPath(const Id: TObjectId): string;
    function Exists(const Id: TObjectId): Boolean;
    function ReadObjectRaw(const Id: TObjectId; out ObjType: TObjectType; out Data: TByteArray): Boolean;
    function ReadObject(const Id: TObjectId): TAnvilObject;
    function WriteObjectRaw(ObjType: TObjectType; const Data: Pointer; DataLen: Int64): TObjectId;
    function WriteObject(Obj: TAnvilObject): TObjectId;
    property ObjectsDir: string read FObjectsDir;
    property Algorithm: THashAlgorithm read FAlgo;
  end;

function ZlibCompressBuffer(const Data: Pointer; DataLen: SizeInt): TByteArray;
function ZlibDecompressStream(InStream: TStream): TByteArray;

implementation

function ZlibCompressBuffer(const Data: Pointer; DataLen: SizeInt): TByteArray;
var
  InStream, OutStream: TMemoryStream;
  Compressor: TCompressionStream;
begin
  Result := nil;
  InStream := TMemoryStream.Create;
  OutStream := TMemoryStream.Create;
  try
    if DataLen > 0 then
      InStream.WriteBuffer(Data^, DataLen);
    InStream.Position := 0;

    Compressor := TCompressionStream.Create(clDefault, OutStream);
    try
      if DataLen > 0 then
        Compressor.CopyFrom(InStream, DataLen);
    finally
      Compressor.Free;
    end;

    SetLength(Result, OutStream.Size);
    if OutStream.Size > 0 then
    begin
      OutStream.Position := 0;
      OutStream.ReadBuffer(Result[0], OutStream.Size);
    end;
  finally
    InStream.Free;
    OutStream.Free;
  end;
end;

function ZlibDecompressStream(InStream: TStream): TByteArray;
var
  Decompressor: TDecompressionStream;
  OutStream: TMemoryStream;
  Buf: array[0..8191] of Byte;
  BytesRead: LongInt;
begin
  Result := nil;
  OutStream := TMemoryStream.Create;
  try
    Decompressor := TDecompressionStream.Create(InStream);
    try
      repeat
        BytesRead := Decompressor.Read(Buf[0], SizeOf(Buf));
        if BytesRead > 0 then
          OutStream.WriteBuffer(Buf[0], BytesRead);
      until BytesRead <= 0;
    finally
      Decompressor.Free;
    end;

    SetLength(Result, OutStream.Size);
    if OutStream.Size > 0 then
    begin
      OutStream.Position := 0;
      OutStream.ReadBuffer(Result[0], OutStream.Size);
    end;
  finally
    OutStream.Free;
  end;
end;

constructor TLooseBackend.Create(const AObjectsDir: string; Algo: THashAlgorithm);
begin
  inherited Create;
  FObjectsDir := AObjectsDir;
  FAlgo := Algo;
end;

function TLooseBackend.GetObjectPath(const Id: TObjectId): string;
var
  Hex: string;
  DirPart, FilePart: string;
begin
  Hex := ObjectIdToHex(Id);
  DirPart := Copy(Hex, 1, 2);
  FilePart := Copy(Hex, 3, MaxInt);
  Result := JoinPaths(FObjectsDir, JoinPaths(DirPart, FilePart));
end;

function TLooseBackend.Exists(const Id: TObjectId): Boolean;
begin
  Result := FileExists(GetObjectPath(Id));
end;

function TLooseBackend.ReadObjectRaw(const Id: TObjectId; out ObjType: TObjectType; out Data: TByteArray): Boolean;
var
  ObjPath: string;
  FS: TFileStream;
  DecompBytes: TByteArray;
  NullIdx, SpaceIdx: Integer;
  HeaderStr, TypeStr, SizeStr: string;
  ExpectedSize: Int64;
  ComputedId: TObjectId;
  PayloadLen: SizeInt;
begin
  ObjType := otNone;
  Data := nil;

  ObjPath := GetObjectPath(Id);
  if not FileExists(ObjPath) then
    Exit(False);

  FS := TFileStream.Create(ObjPath, fmOpenRead or fmShareDenyNone);
  try
    DecompBytes := ZlibDecompressStream(FS);
  finally
    FS.Free;
  end;

  if Length(DecompBytes) = 0 then
    raise ECorruptObject.CreateWithCode(ERR_CORRUPT_OBJECT, 'Empty loose object: ' + ObjectIdToHex(Id));

  { Find null byte separating header and payload }
  NullIdx := -1;
  for SpaceIdx := 0 to Length(DecompBytes) - 1 do
  begin
    if DecompBytes[SpaceIdx] = 0 then
    begin
      NullIdx := SpaceIdx;
      Break;
    end;
  end;

  if NullIdx < 0 then
    raise ECorruptObject.CreateWithCode(ERR_CORRUPT_OBJECT, 'Missing header null terminator in loose object: ' + ObjectIdToHex(Id));

  SetString(HeaderStr, PChar(@DecompBytes[0]), NullIdx);
  SpaceIdx := Pos(' ', HeaderStr);
  if SpaceIdx <= 1 then
    raise ECorruptObject.CreateWithCode(ERR_CORRUPT_OBJECT, 'Malformed object header: ' + HeaderStr);

  TypeStr := Copy(HeaderStr, 1, SpaceIdx - 1);
  SizeStr := Copy(HeaderStr, SpaceIdx + 1, MaxInt);

  ObjType := StringToObjectType(TypeStr);
  if ObjType = otNone then
    raise ECorruptObject.CreateWithCode(ERR_CORRUPT_OBJECT, 'Unknown object type: ' + TypeStr);

  ExpectedSize := StrToInt64Def(SizeStr, -1);
  if ExpectedSize < 0 then
    raise ECorruptObject.CreateWithCode(ERR_CORRUPT_OBJECT, 'Invalid size in header: ' + SizeStr);

  PayloadLen := Length(DecompBytes) - (NullIdx + 1);
  if PayloadLen <> ExpectedSize then
    raise ECorruptObject.CreateWithCode(ERR_CORRUPT_OBJECT,
      Format('Object size mismatch: declared %d, actual %d', [ExpectedSize, PayloadLen]));

  SetLength(Data, PayloadLen);
  if PayloadLen > 0 then
    Move(DecompBytes[NullIdx + 1], Data[0], PayloadLen);

  { Verify object checksum }
  if PayloadLen = 0 then
    ComputedId := HashGitObject(ObjType, nil, 0, FAlgo)
  else
    ComputedId := HashGitObject(ObjType, @Data[0], PayloadLen, FAlgo);

  if not ObjectIdEqual(ComputedId, Id) then
    raise ECorruptObject.CreateWithCode(ERR_CORRUPT_OBJECT,
      Format('Object SHA mismatch. Expected %s, computed %s', [ObjectIdToHex(Id), ObjectIdToHex(ComputedId)]));

  Result := True;
end;

function TLooseBackend.ReadObject(const Id: TObjectId): TAnvilObject;
var
  ObjType: TObjectType;
  Data: TByteArray;
begin
  if not ReadObjectRaw(Id, ObjType, Data) then
    raise EObjectNotFound.CreateForObject(Id);

  if Length(Data) = 0 then
    Result := ParseObjectPayload(ObjType, nil, 0, FAlgo)
  else
    Result := ParseObjectPayload(ObjType, @Data[0], Length(Data), FAlgo);
  Result.ObjectId := Id;
end;

function TLooseBackend.WriteObjectRaw(ObjType: TObjectType; const Data: Pointer; DataLen: Int64): TObjectId;
var
  Header: string;
  RawPayload: TByteArray;
  Compressed: TByteArray;
  ObjPath, ShardDir: string;
  HeaderLen: Integer;
begin
  { Compute object id }
  Result := HashGitObject(ObjType, Data, DataLen, FAlgo);
  ObjPath := GetObjectPath(Result);

  { If object already exists, skip writing }
  if FileExists(ObjPath) then
    Exit;

  Header := Format('%s %d', [ObjectTypeToString(ObjType), DataLen]) + #0;
  HeaderLen := Length(Header);

  SetLength(RawPayload, HeaderLen + DataLen);
  Move(Header[1], RawPayload[0], HeaderLen);
  if DataLen > 0 then
    Move(Data^, RawPayload[HeaderLen], DataLen);

  Compressed := ZlibCompressBuffer(@RawPayload[0], Length(RawPayload));

  ShardDir := ExtractFileDir(ObjPath);
  if not DirectoryExists(ShardDir) then
    ForceDirectories(ShardDir);

  if not AtomicWriteFile(ObjPath, @Compressed[0], Length(Compressed)) then
    raise EAnvilError.CreateWithCode(ERR_GENERIC, 'Failed to write loose object: ' + ObjPath);
end;

function TLooseBackend.WriteObject(Obj: TAnvilObject): TObjectId;
var
  Payload: TByteArray;
begin
  Payload := Obj.Serialize;
  if Length(Payload) = 0 then
    Result := WriteObjectRaw(Obj.ObjectType, nil, 0)
  else
    Result := WriteObjectRaw(Obj.ObjectType, @Payload[0], Length(Payload));
  Obj.ObjectId := Result;
end;

end.
