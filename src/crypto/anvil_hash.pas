{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Unified cryptographic hashing facilities, Git object header hashing,
  and specialized hash map and hash set collections for TObjectId.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_hash;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, anvil_types, anvil_sha1, anvil_sha256;

{ Git object payload hashing }
function HashGitObject(ObjType: TObjectType; const Data: Pointer; DataLen: Int64; Algo: THashAlgorithm = haSHA1): TObjectId;
function HashGitObjectStream(ObjType: TObjectType; Stream: TStream; StreamLen: Int64; Algo: THashAlgorithm = haSHA1): TObjectId;
function HashBuffer(const Data; Len: SizeInt; Algo: THashAlgorithm = haSHA1): TObjectId;
function HashString(const S: string; Algo: THashAlgorithm = haSHA1): TObjectId;

type
  { Hash set optimized for 20-byte / 32-byte TObjectId }
  PObjectIdNode = ^TObjectIdNode;
  TObjectIdNode = record
    Id: TObjectId;
    Next: PObjectIdNode;
  end;

  TObjectIdSet = class
  private
    FBuckets: array of PObjectIdNode;
    FCapacity: Integer;
    FCount: Integer;
    function HashKey(const Id: TObjectId): Cardinal;
    procedure Rehash(NewCapacity: Integer);
  public
    constructor Create(InitialCapacity: Integer = 1024);
    destructor Destroy; override;
    function Contains(const Id: TObjectId): Boolean;
    function Add(const Id: TObjectId): Boolean; { Returns True if newly added }
    function Remove(const Id: TObjectId): Boolean;
    procedure Clear;
    function ToArray: TObjectIdArray;
    property Count: Integer read FCount;
  end;

  { Hash map mapping TObjectId to Pointer / Integer }
  PObjectIdMapEntry = ^TObjectIdMapEntry;
  TObjectIdMapEntry = record
    Id: TObjectId;
    Value: Pointer;
    Next: PObjectIdMapEntry;
  end;

  TObjectIdMap = class
  private
    FBuckets: array of PObjectIdMapEntry;
    FCapacity: Integer;
    FCount: Integer;
    function HashKey(const Id: TObjectId): Cardinal;
    procedure Rehash(NewCapacity: Integer);
  public
    constructor Create(InitialCapacity: Integer = 1024);
    destructor Destroy; override;
    function Find(const Id: TObjectId; out Value: Pointer): Boolean;
    procedure Put(const Id: TObjectId; Value: Pointer);
    function Remove(const Id: TObjectId): Boolean;
    procedure Clear;
    property Count: Integer read FCount;
  end;

implementation

function HashGitObject(ObjType: TObjectType; const Data: Pointer; DataLen: Int64; Algo: THashAlgorithm): TObjectId;
var
  Header: string;
  SHA1Ctx: TSHA1Context;
  SHA256Ctx: TSHA256Context;
  Digest1: TSHA1Digest;
  Digest256: TSHA256Digest;
begin
  Header := Format('%s %d', [ObjectTypeToString(ObjType), DataLen]) + #0;

  if Algo = haSHA1 then
  begin
    SHA1Init(SHA1Ctx);
    SHA1Update(SHA1Ctx, Header[1], Length(Header));
    if DataLen > 0 then
      SHA1Update(SHA1Ctx, Data^, DataLen);
    SHA1Final(SHA1Ctx, Digest1);
    Result := SHA1DigestToObjectId(Digest1);
  end
  else
  begin
    SHA256Init(SHA256Ctx);
    SHA256Update(SHA256Ctx, Header[1], Length(Header));
    if DataLen > 0 then
      SHA256Update(SHA256Ctx, Data^, DataLen);
    SHA256Final(SHA256Ctx, Digest256);
    Result := SHA256DigestToObjectId(Digest256);
  end;
end;

function HashGitObjectStream(ObjType: TObjectType; Stream: TStream; StreamLen: Int64; Algo: THashAlgorithm): TObjectId;
var
  Header: string;
  SHA1Ctx: TSHA1Context;
  SHA256Ctx: TSHA256Context;
  Digest1: TSHA1Digest;
  Digest256: TSHA256Digest;
  Buf: array[0..8191] of Byte;
  Remaining: Int64;
  ChunkSize: LongInt;
begin
  Header := Format('%s %d', [ObjectTypeToString(ObjType), StreamLen]) + #0;
  Remaining := StreamLen;

  if Algo = haSHA1 then
  begin
    SHA1Init(SHA1Ctx);
    SHA1Update(SHA1Ctx, Header[1], Length(Header));
    while Remaining > 0 do
    begin
      if Remaining > SizeOf(Buf) then
        ChunkSize := SizeOf(Buf)
      else
        ChunkSize := LongInt(Remaining);
      Stream.ReadBuffer(Buf[0], ChunkSize);
      SHA1Update(SHA1Ctx, Buf[0], ChunkSize);
      Dec(Remaining, ChunkSize);
    end;
    SHA1Final(SHA1Ctx, Digest1);
    Result := SHA1DigestToObjectId(Digest1);
  end
  else
  begin
    SHA256Init(SHA256Ctx);
    SHA256Update(SHA256Ctx, Header[1], Length(Header));
    while Remaining > 0 do
    begin
      if Remaining > SizeOf(Buf) then
        ChunkSize := SizeOf(Buf)
      else
        ChunkSize := LongInt(Remaining);
      Stream.ReadBuffer(Buf[0], ChunkSize);
      SHA256Update(SHA256Ctx, Buf[0], ChunkSize);
      Dec(Remaining, ChunkSize);
    end;
    SHA256Final(SHA256Ctx, Digest256);
    Result := SHA256DigestToObjectId(Digest256);
  end;
end;

function HashBuffer(const Data; Len: SizeInt; Algo: THashAlgorithm): TObjectId;
begin
  if Algo = haSHA1 then
    Result := SHA1DigestToObjectId(SHA1Buffer(Data, Len))
  else
    Result := SHA256DigestToObjectId(SHA256Buffer(Data, Len));
end;

function HashString(const S: string; Algo: THashAlgorithm): TObjectId;
begin
  if Length(S) = 0 then
    Result := HashBuffer('', 0, Algo)
  else
    Result := HashBuffer(S[1], Length(S), Algo);
end;

{ TObjectIdSet implementation }

constructor TObjectIdSet.Create(InitialCapacity: Integer);
begin
  inherited Create;
  FCapacity := InitialCapacity;
  if FCapacity < 16 then
    FCapacity := 16;
  SetLength(FBuckets, FCapacity);
  FCount := 0;
end;

destructor TObjectIdSet.Destroy;
begin
  Clear;
  inherited Destroy;
end;

function TObjectIdSet.HashKey(const Id: TObjectId): Cardinal;
begin
  { Direct integer fold over first 8 bytes of digest }
  Result := (Cardinal(Id.Digest[0]) shl 24) or
            (Cardinal(Id.Digest[1]) shl 16) or
            (Cardinal(Id.Digest[2]) shl 8) or
             Cardinal(Id.Digest[3]);
  Result := Result xor ((Cardinal(Id.Digest[4]) shl 24) or
                        (Cardinal(Id.Digest[5]) shl 16) or
                        (Cardinal(Id.Digest[6]) shl 8) or
                         Cardinal(Id.Digest[7]));
end;

procedure TObjectIdSet.Rehash(NewCapacity: Integer);
var
  NewBuckets: array of PObjectIdNode;
  I: Integer;
  Curr, NextNode: PObjectIdNode;
  BucketIdx: Cardinal;
begin
  SetLength(NewBuckets, NewCapacity);
  for I := 0 to FCapacity - 1 do
  begin
    Curr := FBuckets[I];
    while Curr <> nil do
    begin
      NextNode := Curr^.Next;
      BucketIdx := HashKey(Curr^.Id) mod Cardinal(NewCapacity);
      Curr^.Next := NewBuckets[BucketIdx];
      NewBuckets[BucketIdx] := Curr;
      Curr := NextNode;
    end;
  end;
  FBuckets := NewBuckets;
  FCapacity := NewCapacity;
end;

function TObjectIdSet.Contains(const Id: TObjectId): Boolean;
var
  BucketIdx: Cardinal;
  Node: PObjectIdNode;
begin
  BucketIdx := HashKey(Id) mod Cardinal(FCapacity);
  Node := FBuckets[BucketIdx];
  while Node <> nil do
  begin
    if ObjectIdEqual(Node^.Id, Id) then
      Exit(True);
    Node := Node^.Next;
  end;
  Result := False;
end;

function TObjectIdSet.Add(const Id: TObjectId): Boolean;
var
  BucketIdx: Cardinal;
  Node: PObjectIdNode;
begin
  if FCount >= FCapacity * 2 then
    Rehash(FCapacity * 2);

  BucketIdx := HashKey(Id) mod Cardinal(FCapacity);
  Node := FBuckets[BucketIdx];
  while Node <> nil do
  begin
    if ObjectIdEqual(Node^.Id, Id) then
      Exit(False); { Already present }
    Node := Node^.Next;
  end;

  New(Node);
  Node^.Id := Id;
  Node^.Next := FBuckets[BucketIdx];
  FBuckets[BucketIdx] := Node;
  Inc(FCount);
  Result := True;
end;

function TObjectIdSet.Remove(const Id: TObjectId): Boolean;
var
  BucketIdx: Cardinal;
  Curr, Prev: PObjectIdNode;
begin
  BucketIdx := HashKey(Id) mod Cardinal(FCapacity);
  Curr := FBuckets[BucketIdx];
  Prev := nil;
  while Curr <> nil do
  begin
    if ObjectIdEqual(Curr^.Id, Id) then
    begin
      if Prev = nil then
        FBuckets[BucketIdx] := Curr^.Next
      else
        Prev^.Next := Curr^.Next;
      Dispose(Curr);
      Dec(FCount);
      Exit(True);
    end;
    Prev := Curr;
    Curr := Curr^.Next;
  end;
  Result := False;
end;

procedure TObjectIdSet.Clear;
var
  I: Integer;
  Curr, NextNode: PObjectIdNode;
begin
  for I := 0 to FCapacity - 1 do
  begin
    Curr := FBuckets[I];
    while Curr <> nil do
    begin
      NextNode := Curr^.Next;
      Dispose(Curr);
      Curr := NextNode;
    end;
    FBuckets[I] := nil;
  end;
  FCount := 0;
end;

function TObjectIdSet.ToArray: TObjectIdArray;
var
  I, Idx: Integer;
  Node: PObjectIdNode;
begin
  Result := nil;
  SetLength(Result, FCount);
  Idx := 0;
  for I := 0 to FCapacity - 1 do
  begin
    Node := FBuckets[I];
    while Node <> nil do
    begin
      Result[Idx] := Node^.Id;
      Inc(Idx);
      Node := Node^.Next;
    end;
  end;
end;

{ TObjectIdMap implementation }

constructor TObjectIdMap.Create(InitialCapacity: Integer);
begin
  inherited Create;
  FCapacity := InitialCapacity;
  if FCapacity < 16 then
    FCapacity := 16;
  SetLength(FBuckets, FCapacity);
  FCount := 0;
end;

destructor TObjectIdMap.Destroy;
begin
  Clear;
  inherited Destroy;
end;

function TObjectIdMap.HashKey(const Id: TObjectId): Cardinal;
begin
  Result := (Cardinal(Id.Digest[0]) shl 24) or
            (Cardinal(Id.Digest[1]) shl 16) or
            (Cardinal(Id.Digest[2]) shl 8) or
             Cardinal(Id.Digest[3]);
  Result := Result xor ((Cardinal(Id.Digest[4]) shl 24) or
                        (Cardinal(Id.Digest[5]) shl 16) or
                        (Cardinal(Id.Digest[6]) shl 8) or
                         Cardinal(Id.Digest[7]));
end;

procedure TObjectIdMap.Rehash(NewCapacity: Integer);
var
  NewBuckets: array of PObjectIdMapEntry;
  I: Integer;
  Curr, NextEntry: PObjectIdMapEntry;
  BucketIdx: Cardinal;
begin
  SetLength(NewBuckets, NewCapacity);
  for I := 0 to FCapacity - 1 do
  begin
    Curr := FBuckets[I];
    while Curr <> nil do
    begin
      NextEntry := Curr^.Next;
      BucketIdx := HashKey(Curr^.Id) mod Cardinal(NewCapacity);
      Curr^.Next := NewBuckets[BucketIdx];
      NewBuckets[BucketIdx] := Curr;
      Curr := NextEntry;
    end;
  end;
  FBuckets := NewBuckets;
  FCapacity := NewCapacity;
end;

function TObjectIdMap.Find(const Id: TObjectId; out Value: Pointer): Boolean;
var
  BucketIdx: Cardinal;
  Entry: PObjectIdMapEntry;
begin
  BucketIdx := HashKey(Id) mod Cardinal(FCapacity);
  Entry := FBuckets[BucketIdx];
  while Entry <> nil do
  begin
    if ObjectIdEqual(Entry^.Id, Id) then
    begin
      Value := Entry^.Value;
      Exit(True);
    end;
    Entry := Entry^.Next;
  end;
  Value := nil;
  Result := False;
end;

procedure TObjectIdMap.Put(const Id: TObjectId; Value: Pointer);
var
  BucketIdx: Cardinal;
  Entry: PObjectIdMapEntry;
begin
  if FCount >= FCapacity * 2 then
    Rehash(FCapacity * 2);

  BucketIdx := HashKey(Id) mod Cardinal(FCapacity);
  Entry := FBuckets[BucketIdx];
  while Entry <> nil do
  begin
    if ObjectIdEqual(Entry^.Id, Id) then
    begin
      Entry^.Value := Value;
      Exit;
    end;
    Entry := Entry^.Next;
  end;

  New(Entry);
  Entry^.Id := Id;
  Entry^.Value := Value;
  Entry^.Next := FBuckets[BucketIdx];
  FBuckets[BucketIdx] := Entry;
  Inc(FCount);
end;

function TObjectIdMap.Remove(const Id: TObjectId): Boolean;
var
  BucketIdx: Cardinal;
  Curr, Prev: PObjectIdMapEntry;
begin
  BucketIdx := HashKey(Id) mod Cardinal(FCapacity);
  Curr := FBuckets[BucketIdx];
  Prev := nil;
  while Curr <> nil do
  begin
    if ObjectIdEqual(Curr^.Id, Id) then
    begin
      if Prev = nil then
        FBuckets[BucketIdx] := Curr^.Next
      else
        Prev^.Next := Curr^.Next;
      Dispose(Curr);
      Dec(FCount);
      Exit(True);
    end;
    Prev := Curr;
    Curr := Curr^.Next;
  end;
  Result := False;
end;

procedure TObjectIdMap.Clear;
var
  I: Integer;
  Curr, NextEntry: PObjectIdMapEntry;
begin
  for I := 0 to FCapacity - 1 do
  begin
    Curr := FBuckets[I];
    while Curr <> nil do
    begin
      NextEntry := Curr^.Next;
      Dispose(Curr);
      Curr := NextEntry;
    end;
    FBuckets[I] := nil;
  end;
  FCount := 0;
end;

end.
