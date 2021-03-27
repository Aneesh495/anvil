{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Cache-tree extension (TREE) implementation. Stores precomputed tree
  hashes for subdirectories, accelerating write-tree from O(N) to O(modified).
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_index_tree;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, anvil_types, anvil_errors, anvil_utils;

type
  { Recursive cache-tree node }
  TIndexTreeNode = class
  private
    FName: string;
    FEntryCount: Integer; { -1 means invalidated }
    FSubtreeCount: Integer;
    FId: TObjectId;
    FChildren: array of TIndexTreeNode;
    FChildCount: Integer;
    procedure EnsureCapacity(MinCap: Integer);
  public
    constructor Create(const AName: string);
    destructor Destroy; override;
    procedure Invalidate;
    function FindChild(const AName: string): TIndexTreeNode;
    function AddChild(const AName: string): TIndexTreeNode;
    procedure Serialize(Stream: TStream);
    procedure Deserialize(Stream: TStream; Algo: THashAlgorithm = haSHA1);

    property Name: string read FName write FName;
    property EntryCount: Integer read FEntryCount write FEntryCount;
    property SubtreeCount: Integer read FSubtreeCount write FSubtreeCount;
    property Id: TObjectId read FId write FId;
    property ChildCount: Integer read FChildCount;
  end;

implementation

constructor TIndexTreeNode.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
  FEntryCount := -1;
  FSubtreeCount := 0;
  FId := NullObjectId;
  FChildCount := 0;
  SetLength(FChildren, 0);
end;

destructor TIndexTreeNode.Destroy;
var
  I: Integer;
begin
  for I := 0 to FChildCount - 1 do
    FChildren[I].Free;
  SetLength(FChildren, 0);
  inherited Destroy;
end;

procedure TIndexTreeNode.EnsureCapacity(MinCap: Integer);
var
  NewCap: Integer;
begin
  if Length(FChildren) >= MinCap then
    Exit;
  NewCap := Length(FChildren) * 2;
  if NewCap < MinCap then
    NewCap := MinCap;
  if NewCap < 4 then
    NewCap := 4;
  SetLength(FChildren, NewCap);
end;

procedure TIndexTreeNode.Invalidate;
var
  I: Integer;
begin
  FEntryCount := -1;
  FId := NullObjectId;
  for I := 0 to FChildCount - 1 do
    FChildren[I].Invalidate;
end;

function TIndexTreeNode.FindChild(const AName: string): TIndexTreeNode;
var
  I: Integer;
begin
  for I := 0 to FChildCount - 1 do
  begin
    if FChildren[I].Name = AName then
      Exit(FChildren[I]);
  end;
  Result := nil;
end;

function TIndexTreeNode.AddChild(const AName: string): TIndexTreeNode;
begin
  Result := FindChild(AName);
  if Result <> nil then
    Exit;

  EnsureCapacity(FChildCount + 1);
  Result := TIndexTreeNode.Create(AName);
  FChildren[FChildCount] := Result;
  Inc(FChildCount);
  FSubtreeCount := FChildCount;
end;

procedure TIndexTreeNode.Serialize(Stream: TStream);
var
  NullByte: Byte;
  HeaderStr: string;
  I: Integer;
begin
  NullByte := 0;
  if Length(FName) > 0 then
    Stream.WriteBuffer(FName[1], Length(FName));
  Stream.WriteBuffer(NullByte, 1);

  HeaderStr := Format('%d %d'#10, [FEntryCount, FChildCount]);
  Stream.WriteBuffer(HeaderStr[1], Length(HeaderStr));

  if FEntryCount >= 0 then
    Stream.WriteBuffer(FId.Digest[0], 20);

  for I := 0 to FChildCount - 1 do
    FChildren[I].Serialize(Stream);
end;

procedure TIndexTreeNode.Deserialize(Stream: TStream; Algo: THashAlgorithm);
var
  NameBytes: array of Byte;
  B: Byte;
  NameLen: Integer;
  NumStr: string;
  SpacePos, LfPos: Integer;
  RawDigest: array[0..19] of Byte;
  SubtreesToRead, I: Integer;
  ChildNode: TIndexTreeNode;
begin
  { Read null-terminated name }
  NameLen := 0;
  SetLength(NameBytes, 64);
  repeat
    if Stream.Read(B, 1) < 1 then
      Exit;
    if B = 0 then
      Break;
    if NameLen >= Length(NameBytes) then
      SetLength(NameBytes, Length(NameBytes) * 2);
    NameBytes[NameLen] := B;
    Inc(NameLen);
  until False;

  SetString(FName, PChar(@NameBytes[0]), NameLen);

  { Read line containing "<entryCount> <subtreeCount>\n" }
  NumStr := '';
  repeat
    if Stream.Read(B, 1) < 1 then
      Exit;
    if B = Byte(#10) then
      Break;
    NumStr := NumStr + Char(B);
  until False;

  SpacePos := Pos(' ', NumStr);
  if SpacePos > 1 then
  begin
    FEntryCount := StrToIntDef(Copy(NumStr, 1, SpacePos - 1), -1);
    SubtreesToRead := StrToIntDef(Copy(NumStr, SpacePos + 1, MaxInt), 0);
  end
  else
  begin
    FEntryCount := -1;
    SubtreesToRead := 0;
  end;

  if FEntryCount >= 0 then
  begin
    Stream.ReadBuffer(RawDigest[0], 20);
    FId.Algorithm := Algo;
    FillChar(FId.Digest, SizeOf(FId.Digest), 0);
    Move(RawDigest[0], FId.Digest[0], 20);
  end;

  FSubtreeCount := SubtreesToRead;
  for I := 0 to SubtreesToRead - 1 do
  begin
    ChildNode := TIndexTreeNode.Create('');
    ChildNode.Deserialize(Stream, Algo);
    EnsureCapacity(FChildCount + 1);
    FChildren[FChildCount] := ChildNode;
    Inc(FChildCount);
  end;
end;

end.
