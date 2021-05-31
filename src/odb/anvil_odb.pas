{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Unified Object Database (ODB) coordinator. Integrates loose object storage,
  packfile indexes, LRU caching, and garbage collection packing.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_odb;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DateUtils, anvil_types, anvil_errors, anvil_utils, anvil_hash,
  anvil_object, anvil_loose, anvil_pack_index, anvil_pack, anvil_pack_writer;

type
  { LRU cache entry }
  PLRUCacheEntry = ^TLRUCacheEntry;
  TLRUCacheEntry = record
    Id: TObjectId;
    ObjType: TObjectType;
    Data: TByteArray;
    Prev, Next: PLRUCacheEntry;
  end;

  { Simple LRU object cache }
  TObjectCache = class
  private
    FMap: TObjectIdMap;
    FHead, FTail: PLRUCacheEntry;
    FCapacity: Integer;
    FCount: Integer;
    procedure MoveToFront(Entry: PLRUCacheEntry);
    procedure RemoveEntry(Entry: PLRUCacheEntry);
  public
    constructor Create(Capacity: Integer = 2048);
    destructor Destroy; override;
    function Get(const Id: TObjectId; out ObjType: TObjectType; out Data: TByteArray): Boolean;
    procedure Put(const Id: TObjectId; ObjType: TObjectType; const Data: Pointer; DataLen: SizeInt);
    procedure Clear;
    property Capacity: Integer read FCapacity;
    property Count: Integer read FCount;
  end;

  { Unified Object Database coordinator }
  TObjectDatabase = class
  private
    FObjectsDir: string;
    FAlgo: THashAlgorithm;
    FLooseBackend: TLooseBackend;
    FPackfiles: array of TPackfile;
    FPackCount: Integer;
    FCache: TObjectCache;
    function ResolvePackBase(const BaseId: TObjectId; out BaseType: TObjectType; out BaseData: TByteArray): Boolean;
  public
    constructor Create(const AObjectsDir: string; Algo: THashAlgorithm = haSHA1);
    destructor Destroy; override;

    function Exists(const Id: TObjectId): Boolean;
    function FindObjectByPrefix(const HexPrefix: string; out FullId: TObjectId): Boolean;
    function ReadObjectRaw(const Id: TObjectId; out ObjType: TObjectType; out Data: TByteArray): Boolean;
    function ReadObject(const Id: TObjectId): TAnvilObject;
    function WriteObjectRaw(ObjType: TObjectType; const Data: Pointer; DataLen: Int64): TObjectId;
    function WriteObject(Obj: TAnvilObject): TObjectId;

    function EnumerateAllObjects: TObjectIdArray;
    procedure PackLooseObjects;
    procedure DiscoverPacks;

    property ObjectsDir: string read FObjectsDir;
    property Algorithm: THashAlgorithm read FAlgo;
    property PackCount: Integer read FPackCount;
  end;

implementation

{ TObjectCache implementation }

constructor TObjectCache.Create(Capacity: Integer);
begin
  inherited Create;
  FCapacity := Capacity;
  FCount := 0;
  FHead := nil;
  FTail := nil;
  FMap := TObjectIdMap.Create(Capacity);
end;

destructor TObjectCache.Destroy;
begin
  Clear;
  FMap.Free;
  inherited Destroy;
end;

procedure TObjectCache.MoveToFront(Entry: PLRUCacheEntry);
begin
  if Entry = FHead then
    Exit;

  { Detach from current position }
  if Entry^.Prev <> nil then
    Entry^.Prev^.Next := Entry^.Next;
  if Entry^.Next <> nil then
    Entry^.Next^.Prev := Entry^.Prev;
  if Entry = FTail then
    FTail := Entry^.Prev;

  { Attach to head }
  Entry^.Prev := nil;
  Entry^.Next := FHead;
  if FHead <> nil then
    FHead^.Prev := Entry;
  FHead := Entry;

  if FTail = nil then
    FTail := Entry;
end;

procedure TObjectCache.RemoveEntry(Entry: PLRUCacheEntry);
begin
  if Entry^.Prev <> nil then
    Entry^.Prev^.Next := Entry^.Next;
  if Entry^.Next <> nil then
    Entry^.Next^.Prev := Entry^.Prev;
  if Entry = FHead then
    FHead := Entry^.Next;
  if Entry = FTail then
    FTail := Entry^.Prev;

  FMap.Remove(Entry^.Id);
  SetLength(Entry^.Data, 0);
  Dispose(Entry);
  Dec(FCount);
end;

function TObjectCache.Get(const Id: TObjectId; out ObjType: TObjectType; out Data: TByteArray): Boolean;
var
  PtrVal: Pointer;
  Entry: PLRUCacheEntry;
begin
  ObjType := otNone;
  Data := nil;
  if not FMap.Find(Id, PtrVal) then
    Exit(False);

  Entry := PLRUCacheEntry(PtrVal);
  MoveToFront(Entry);
  ObjType := Entry^.ObjType;
  Data := Entry^.Data;
  Result := True;
end;

procedure TObjectCache.Put(const Id: TObjectId; ObjType: TObjectType; const Data: Pointer; DataLen: SizeInt);
var
  PtrVal: Pointer;
  Entry: PLRUCacheEntry;
begin
  if FMap.Find(Id, PtrVal) then
  begin
    Entry := PLRUCacheEntry(PtrVal);
    Entry^.ObjType := ObjType;
    SetLength(Entry^.Data, DataLen);
    if DataLen > 0 then
      Move(Data^, Entry^.Data[0], DataLen);
    MoveToFront(Entry);
    Exit;
  end;

  if FCount >= FCapacity then
  begin
    if FTail <> nil then
      RemoveEntry(FTail);
  end;

  New(Entry);
  Entry^.Id := Id;
  Entry^.ObjType := ObjType;
  SetLength(Entry^.Data, DataLen);
  if DataLen > 0 then
    Move(Data^, Entry^.Data[0], DataLen);

  Entry^.Prev := nil;
  Entry^.Next := FHead;
  if FHead <> nil then
    FHead^.Prev := Entry;
  FHead := Entry;
  if FTail = nil then
    FTail := Entry;

  FMap.Put(Id, Entry);
  Inc(FCount);
end;

procedure TObjectCache.Clear;
var
  Curr, NextEntry: PLRUCacheEntry;
begin
  Curr := FHead;
  while Curr <> nil do
  begin
    NextEntry := Curr^.Next;
    SetLength(Curr^.Data, 0);
    Dispose(Curr);
    Curr := NextEntry;
  end;
  FHead := nil;
  FTail := nil;
  FCount := 0;
  FMap.Clear;
end;

{ TObjectDatabase implementation }

constructor TObjectDatabase.Create(const AObjectsDir: string; Algo: THashAlgorithm);
begin
  inherited Create;
  FObjectsDir := AObjectsDir;
  FAlgo := Algo;
  FLooseBackend := TLooseBackend.Create(AObjectsDir, Algo);
  FCache := TObjectCache.Create(2048);
  FPackCount := 0;
  SetLength(FPackfiles, 0);
  DiscoverPacks;
end;

destructor TObjectDatabase.Destroy;
var
  I: Integer;
begin
  for I := 0 to FPackCount - 1 do
    FPackfiles[I].Free;
  SetLength(FPackfiles, 0);

  FLooseBackend.Free;
  FCache.Free;
  inherited Destroy;
end;

procedure TObjectDatabase.DiscoverPacks;
var
  PackDir: string;
  Rec: TSearchRec;
  PackPath, IdxPath, BaseName: string;
  PackObj: TPackfile;
  I: Integer;
begin
  for I := 0 to FPackCount - 1 do
    FPackfiles[I].Free;
  FPackCount := 0;
  SetLength(FPackfiles, 0);

  PackDir := JoinPaths(FObjectsDir, 'pack');
  if not DirectoryExists(PackDir) then
    Exit;

  if FindFirst(JoinPaths(PackDir, '*.pack'), faAnyFile, Rec) = 0 then
  begin
    repeat
      PackPath := JoinPaths(PackDir, Rec.Name);
      BaseName := ChangeFileExt(Rec.Name, '');
      IdxPath := JoinPaths(PackDir, BaseName + '.idx');

      if FileExists(IdxPath) then
      begin
        try
          PackObj := TPackfile.Create(PackPath, IdxPath, @ResolvePackBase);
          Inc(FPackCount);
          SetLength(FPackfiles, FPackCount);
          FPackfiles[FPackCount - 1] := PackObj;
        except
          { Ignore corrupt or incomplete packfiles gracefully }
        end;
      end;
    until FindNext(Rec) <> 0;
    FindClose(Rec);
  end;
end;

function TObjectDatabase.ResolvePackBase(const BaseId: TObjectId; out BaseType: TObjectType; out BaseData: TByteArray): Boolean;
begin
  Result := ReadObjectRaw(BaseId, BaseType, BaseData);
end;

function TObjectDatabase.Exists(const Id: TObjectId): Boolean;
var
  I: Integer;
  DummyType: TObjectType;
  DummyData: TByteArray;
begin
  if FCache.Get(Id, DummyType, DummyData) then
    Exit(True);

  for I := 0 to FPackCount - 1 do
  begin
    if FPackfiles[I].ContainsObject(Id) then
      Exit(True);
  end;

  Result := FLooseBackend.Exists(Id);
end;

function TObjectDatabase.FindObjectByPrefix(const HexPrefix: string; out FullId: TObjectId): Boolean;
var
  AllIds: TObjectIdArray;
  I: Integer;
  TargetPrefix: string;
  PrefixLen: Integer;
  CandidateHex: string;
  FoundCount: Integer;
begin
  Result := False;
  FullId := NullObjectId(FAlgo);
  TargetPrefix := LowerCase(Trim(HexPrefix));
  PrefixLen := Length(TargetPrefix);
  if PrefixLen < 4 then Exit;

  AllIds := EnumerateAllObjects;
  FoundCount := 0;

  for I := 0 to Length(AllIds) - 1 do
  begin
    CandidateHex := ObjectIdToHex(AllIds[I]);
    if Copy(CandidateHex, 1, PrefixLen) = TargetPrefix then
    begin
      FullId := AllIds[I];
      Inc(FoundCount);
      if FoundCount > 1 then
      begin
        { Ambiguous prefix: multiple matches exist }
        FullId := NullObjectId(FAlgo);
        Exit(False);
      end;
    end;
  end;

  Result := FoundCount = 1;
end;

function TObjectDatabase.ReadObjectRaw(const Id: TObjectId; out ObjType: TObjectType; out Data: TByteArray): Boolean;
var
  I: Integer;
begin
  { Check LRU cache first }
  if FCache.Get(Id, ObjType, Data) then
    Exit(True);

  { Check packfiles }
  for I := 0 to FPackCount - 1 do
  begin
    if FPackfiles[I].ContainsObject(Id) then
    begin
      if FPackfiles[I].ReadObject(Id, ObjType, Data) then
      begin
        if Length(Data) = 0 then
          FCache.Put(Id, ObjType, nil, 0)
        else
          FCache.Put(Id, ObjType, @Data[0], Length(Data));
        Exit(True);
      end;
    end;
  end;

  { Fall back to loose objects }
  if FLooseBackend.ReadObjectRaw(Id, ObjType, Data) then
  begin
    if Length(Data) = 0 then
      FCache.Put(Id, ObjType, nil, 0)
    else
      FCache.Put(Id, ObjType, @Data[0], Length(Data));
    Exit(True);
  end;

  ObjType := otNone;
  Data := nil;
  Result := False;
end;

function TObjectDatabase.ReadObject(const Id: TObjectId): TAnvilObject;
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

function TObjectDatabase.WriteObjectRaw(ObjType: TObjectType; const Data: Pointer; DataLen: Int64): TObjectId;
begin
  Result := FLooseBackend.WriteObjectRaw(ObjType, Data, DataLen);
  FCache.Put(Result, ObjType, Data, DataLen);
end;

function TObjectDatabase.WriteObject(Obj: TAnvilObject): TObjectId;
var
  Payload: TByteArray;
begin
  Payload := Obj.Serialize;
  Result := FLooseBackend.WriteObject(Obj);
  if Length(Payload) = 0 then
    FCache.Put(Result, Obj.ObjectType, nil, 0)
  else
    FCache.Put(Result, Obj.ObjectType, @Payload[0], Length(Payload));
end;

function TObjectDatabase.EnumerateAllObjects: TObjectIdArray;
var
  SetObj: TObjectIdSet;
  I: Integer;
  DirRec, FileRec: TSearchRec;
  ShardDir: string;
  HexStr: string;
  CandId: TObjectId;
  PackEntry: TPackIndexEntry;
  J: LongWord;
begin
  SetObj := TObjectIdSet.Create(4096);
  try
    { 1. Scan loose objects directory }
    if FindFirst(JoinPaths(FObjectsDir, '*'), faDirectory, DirRec) = 0 then
    begin
      repeat
        if (Length(DirRec.Name) = 2) and (DirRec.Name[1] in ['0'..'9', 'a'..'f']) and
           (DirRec.Name[2] in ['0'..'9', 'a'..'f']) then
        begin
          ShardDir := JoinPaths(FObjectsDir, DirRec.Name);
          if FindFirst(JoinPaths(ShardDir, '*'), faAnyFile, FileRec) = 0 then
          begin
            repeat
              if (FileRec.Name <> '.') and (FileRec.Name <> '..') then
              begin
                HexStr := DirRec.Name + FileRec.Name;
                if TryHexToObjectId(HexStr, CandId, FAlgo) then
                  SetObj.Add(CandId);
              end;
            until FindNext(FileRec) <> 0;
            FindClose(FileRec);
          end;
        end;
      until FindNext(DirRec) <> 0;
      FindClose(DirRec);
    end;

    { 2. Scan all packfiles }
    for I := 0 to FPackCount - 1 do
    begin
      for J := 0 to FPackfiles[I].ObjectCount - 1 do
      begin
        PackEntry := FPackfiles[I].Index.GetEntry(J);
        SetObj.Add(PackEntry.Id);
      end;
    end;

    Result := SetObj.ToArray;
  finally
    SetObj.Free;
  end;
end;

procedure TObjectDatabase.PackLooseObjects;
var
  AllIds: TObjectIdArray;
  Writer: TPackWriter;
  PackDir, BasePackPath, OutPack, OutIdx: string;
  PackChecksum: TObjectId;
  ObjType: TObjectType;
  Data: TByteArray;
  I: Integer;
  LoosePath: string;
begin
  AllIds := EnumerateAllObjects;
  if Length(AllIds) = 0 then
    Exit;

  PackDir := JoinPaths(FObjectsDir, 'pack');
  EnsureDirectoryExists(PackDir);

  Writer := TPackWriter.Create(10, 50);
  try
    for I := 0 to High(AllIds) do
    begin
      if ReadObjectRaw(AllIds[I], ObjType, Data) then
      begin
        if Length(Data) = 0 then
          Writer.AddObject(AllIds[I], ObjType, nil, 0)
        else
          Writer.AddObject(AllIds[I], ObjType, @Data[0], Length(Data));
      end;
    end;

    BasePackPath := JoinPaths(PackDir, Format('pack-%d', [DateTimeToUnix(Now)]));
    Writer.WritePack(BasePackPath, OutPack, OutIdx, PackChecksum);

    { Re-hash to include new packfile checksum }
    RenameFile(OutPack, JoinPaths(PackDir, 'pack-' + ObjectIdToHex(PackChecksum) + '.pack'));
    RenameFile(OutIdx, JoinPaths(PackDir, 'pack-' + ObjectIdToHex(PackChecksum) + '.idx'));

    { Delete loose objects that are now packed }
    for I := 0 to High(AllIds) do
    begin
      LoosePath := FLooseBackend.GetObjectPath(AllIds[I]);
      if FileExists(LoosePath) then
        DeleteFile(LoosePath);
    end;

  finally
    Writer.Free;
  end;

  { Reload packfiles }
  for I := 0 to FPackCount - 1 do
    FPackfiles[I].Free;
  SetLength(FPackfiles, 0);
  FPackCount := 0;
  DiscoverPacks;
end;

end.
