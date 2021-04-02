{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Object abstractions and in-memory representation for Git entities:
  blobs, trees, commits, and annotated tags. Implements canonical
  binary parsing and serialization according to the Git object format.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_object;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, anvil_types, anvil_errors, anvil_utils, anvil_hash;

type
  { Base Git object class }
  TAnvilObject = class
  protected
    FObjectId: TObjectId;
    FObjectType: TObjectType;
    FSize: Int64;
    function GetObjectId: TObjectId;
  public
    constructor Create; virtual; overload;
    constructor Create(AType: TObjectType); virtual; overload;
    function Serialize: TByteArray; virtual; abstract;
    function ComputeId(Algo: THashAlgorithm = haSHA1): TObjectId;
    property ObjectId: TObjectId read GetObjectId write FObjectId;
    property ObjectType: TObjectType read FObjectType;
    property Size: Int64 read FSize;
  end;

  { Blob object representing opaque file content }
  TBlobObject = class(TAnvilObject)
  private
    FData: TByteArray;
  public
    constructor Create; override;
    constructor CreateWithData(const AData: Pointer; ALength: SizeInt);
    constructor CreateWithString(const S: string);
    function Serialize: TByteArray; override;
    function AsString: string;
    property Data: TByteArray read FData write FData;
  end;

  { Single entry in a tree object }
  PTreeEntry = ^TTreeEntry;
  TTreeEntry = record
    Mode: TFileMode;
    Name: string;
    Id: TObjectId;
  end;

  { Tree object representing a directory snapshot }
  TTreeObject = class(TAnvilObject)
  private
    FEntries: array of TTreeEntry;
    FCount: Integer;
    procedure EnsureCapacity(MinCap: Integer);
    procedure SortEntries;
  public
    constructor Create; override;
    destructor Destroy; override;
    procedure Clear;
    function AddEntry(Mode: TFileMode; const Name: string; const Id: TObjectId): Integer;
    function RemoveEntry(const Name: string): Boolean;
    function FindEntry(const Name: string; out Entry: TTreeEntry): Boolean;
    function GetEntry(Index: Integer): TTreeEntry;
    function Serialize: TByteArray; override;
    procedure Deserialize(const RawData: Pointer; DataLen: SizeInt; Algo: THashAlgorithm = haSHA1);
    property Count: Integer read FCount;
  end;

  { Commit object representing a version control snapshot }
  TCommitObject = class(TAnvilObject)
  private
    FTreeId: TObjectId;
    FParentIds: TObjectIdArray;
    FAuthor: TIdentity;
    FCommitter: TIdentity;
    FEncoding: string;
    FGpgSig: string;
    FMessage: string;
  public
    constructor Create; override;
    destructor Destroy; override;
    procedure AddParent(const AParentId: TObjectId);
    function Serialize: TByteArray; override;
    procedure Deserialize(const RawData: Pointer; DataLen: SizeInt; Algo: THashAlgorithm = haSHA1);
    function AsString: string;

    property TreeId: TObjectId read FTreeId write FTreeId;
    property ParentIds: TObjectIdArray read FParentIds write FParentIds;
    property Author: TIdentity read FAuthor write FAuthor;
    property Committer: TIdentity read FCommitter write FCommitter;
    property Encoding: string read FEncoding write FEncoding;
    property GpgSig: string read FGpgSig write FGpgSig;
    property Message: string read FMessage write FMessage;
  end;

  { Tag object representing an annotated repository tag }
  TTagObject = class(TAnvilObject)
  private
    FTargetId: TObjectId;
    FTargetType: TObjectType;
    FTagName: string;
    FTagger: TIdentity;
    FMessage: string;
  public
    constructor Create; override;
    function Serialize: TByteArray; override;
    procedure Deserialize(const RawData: Pointer; DataLen: SizeInt; Algo: THashAlgorithm = haSHA1);

    property TargetId: TObjectId read FTargetId write FTargetId;
    property TargetType: TObjectType read FTargetType write FTargetType;
    property TagName: string read FTagName write FTagName;
    property Tagger: TIdentity read FTagger write FTagger;
    property Message: string read FMessage write FMessage;
  end;

{ Factory helper to parse raw object payload into concrete class }
function ParseObjectPayload(ObjType: TObjectType; const RawData: Pointer; DataLen: SizeInt; Algo: THashAlgorithm = haSHA1): TAnvilObject;

implementation

{ TAnvilObject implementation }

constructor TAnvilObject.Create;
begin
  Create(otNone);
end;

constructor TAnvilObject.Create(AType: TObjectType);
begin
  inherited Create;
  FObjectType := AType;
  FObjectId := NullObjectId;
  FSize := 0;
end;

function TAnvilObject.GetObjectId: TObjectId;
begin
  if IsNullObjectId(FObjectId) then
    ComputeId;
  Result := FObjectId;
end;

function TAnvilObject.ComputeId(Algo: THashAlgorithm): TObjectId;
var
  Payload: TByteArray;
begin
  Payload := Serialize;
  if Length(Payload) = 0 then
    FObjectId := HashGitObject(FObjectType, nil, 0, Algo)
  else
    FObjectId := HashGitObject(FObjectType, @Payload[0], Length(Payload), Algo);
  FSize := Length(Payload);
  Result := FObjectId;
end;

{ TBlobObject implementation }

constructor TBlobObject.Create;
begin
  inherited Create(otBlob);
  SetLength(FData, 0);
end;

constructor TBlobObject.CreateWithData(const AData: Pointer; ALength: SizeInt);
begin
  inherited Create(otBlob);
  SetLength(FData, ALength);
  if ALength > 0 then
    Move(AData^, FData[0], ALength);
  FSize := ALength;
end;

constructor TBlobObject.CreateWithString(const S: string);
begin
  if Length(S) = 0 then
    CreateWithData(nil, 0)
  else
    CreateWithData(@S[1], Length(S));
end;

function TBlobObject.Serialize: TByteArray;
begin
  Result := FData;
end;

function TBlobObject.AsString: string;
begin
  if Length(FData) = 0 then
    Exit('');
  SetString(Result, PChar(@FData[0]), Length(FData));
end;

{ TTreeObject implementation }

constructor TTreeObject.Create;
begin
  inherited Create(otTree);
  FCount := 0;
  SetLength(FEntries, 0);
end;

destructor TTreeObject.Destroy;
begin
  Clear;
  inherited Destroy;
end;

procedure TTreeObject.Clear;
begin
  SetLength(FEntries, 0);
  FCount := 0;
end;

procedure TTreeObject.EnsureCapacity(MinCap: Integer);
var
  NewCap: Integer;
begin
  if Length(FEntries) >= MinCap then
    Exit;
  NewCap := Length(FEntries) * 2;
  if NewCap < MinCap then
    NewCap := MinCap;
  if NewCap < 8 then
    NewCap := 8;
  SetLength(FEntries, NewCap);
end;

{ Git sorts tree entries byte-by-byte, but directories are sorted as if ending with '/' }
function CompareTreeEntries(const A, B: TTreeEntry): Integer;
var
  NameA, NameB: string;
begin
  NameA := A.Name;
  NameB := B.Name;
  if A.Mode = fmDirectory then
    NameA := NameA + '/';
  if B.Mode = fmDirectory then
    NameB := NameB + '/';
  Result := CompareStr(NameA, NameB);
end;

procedure TTreeObject.SortEntries;
var
  I, J: Integer;
  Temp: TTreeEntry;
begin
  for I := 0 to FCount - 2 do
  begin
    for J := I + 1 to FCount - 1 do
    begin
      if CompareTreeEntries(FEntries[I], FEntries[J]) > 0 then
      begin
        Temp := FEntries[I];
        FEntries[I] := FEntries[J];
        FEntries[J] := Temp;
      end;
    end;
  end;
end;

function TTreeObject.AddEntry(Mode: TFileMode; const Name: string; const Id: TObjectId): Integer;
var
  I: Integer;
begin
  { Check if entry already exists }
  for I := 0 to FCount - 1 do
  begin
    if FEntries[I].Name = Name then
    begin
      FEntries[I].Mode := Mode;
      FEntries[I].Id := Id;
      SortEntries;
      Exit(I);
    end;
  end;

  EnsureCapacity(FCount + 1);
  FEntries[FCount].Mode := Mode;
  FEntries[FCount].Name := Name;
  FEntries[FCount].Id := Id;
  Inc(FCount);
  SortEntries;
  Result := FCount - 1;
end;

function TTreeObject.RemoveEntry(const Name: string): Boolean;
var
  I, J: Integer;
begin
  for I := 0 to FCount - 1 do
  begin
    if FEntries[I].Name = Name then
    begin
      for J := I to FCount - 2 do
        FEntries[J] := FEntries[J + 1];
      Dec(FCount);
      Exit(True);
    end;
  end;
  Result := False;
end;

function TTreeObject.FindEntry(const Name: string; out Entry: TTreeEntry): Boolean;
var
  I: Integer;
begin
  for I := 0 to FCount - 1 do
  begin
    if FEntries[I].Name = Name then
    begin
      Entry := FEntries[I];
      Exit(True);
    end;
  end;
  Result := False;
end;

function TTreeObject.GetEntry(Index: Integer): TTreeEntry;
begin
  if (Index < 0) or (Index >= FCount) then
    raise EAnvilError.CreateWithCode(ERR_GENERIC, 'Tree entry index out of bounds');
  Result := FEntries[Index];
end;

function TTreeObject.Serialize: TByteArray;
var
  MS: TMemoryStream;
  I: Integer;
  ModeStr, HeaderStr: string;
  DigestLen: Integer;
begin
  Result := nil;
  SortEntries;
  MS := TMemoryStream.Create;
  try
    for I := 0 to FCount - 1 do
    begin
      case FEntries[I].Mode of
        fmDirectory:  ModeStr := '40000';
        fmRegular:    ModeStr := '100644';
        fmExecutable: ModeStr := '100755';
        fmSymlink:    ModeStr := '120000';
        fmGitLink:    ModeStr := '160000';
      else
        ModeStr := '100644';
      end;

      HeaderStr := ModeStr + ' ' + FEntries[I].Name + #0;
      MS.WriteBuffer(HeaderStr[1], Length(HeaderStr));

      if FEntries[I].Id.Algorithm = haSHA1 then
        DigestLen := SHA1_DIGEST_LENGTH
      else
        DigestLen := SHA256_DIGEST_LENGTH;

      MS.WriteBuffer(FEntries[I].Id.Digest[0], DigestLen);
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

procedure TTreeObject.Deserialize(const RawData: Pointer; DataLen: SizeInt; Algo: THashAlgorithm);
var
  P, PEnd: PByte;
  SpacePos, NullPos: PByte;
  ModeOctal: LongWord;
  EntryName: string;
  EntryId: TObjectId;
  DigestLen: Integer;
begin
  Clear;
  if DataLen <= 0 then
    Exit;

  if Algo = haSHA1 then
    DigestLen := SHA1_DIGEST_LENGTH
  else
    DigestLen := SHA256_DIGEST_LENGTH;

  P := PByte(RawData);
  PEnd := P + DataLen;

  while P < PEnd do
  begin
    { Find space terminating octal mode string }
    SpacePos := P;
    while (SpacePos < PEnd) and (SpacePos^ <> Byte(' ')) do
      Inc(SpacePos);

    if SpacePos >= PEnd then
      raise ECorruptObject.CreateWithCode(ERR_CORRUPT_OBJECT, 'Corrupt tree: missing mode delimiter');

    { Parse octal mode string }
    ModeOctal := 0;
    while P < SpacePos do
    begin
      if (P^ < Byte('0')) or (P^ > Byte('7')) then
        raise ECorruptObject.CreateWithCode(ERR_CORRUPT_OBJECT, 'Invalid octal character in tree mode');
      ModeOctal := (ModeOctal shl 3) or LongWord(P^ - Byte('0'));
      Inc(P);
    end;
    Inc(P); { Skip space }

    { Find null byte terminating entry name }
    NullPos := P;
    while (NullPos < PEnd) and (NullPos^ <> 0) do
      Inc(NullPos);

    if NullPos >= PEnd then
      raise ECorruptObject.CreateWithCode(ERR_CORRUPT_OBJECT, 'Corrupt tree: missing name null terminator');

    SetString(EntryName, PChar(P), NullPos - P);
    P := NullPos + 1;

    { Check remaining buffer for raw binary digest }
    if P + DigestLen > PEnd then
      raise ECorruptObject.CreateWithCode(ERR_CORRUPT_OBJECT, 'Corrupt tree: truncated entry digest');

    EntryId.Algorithm := Algo;
    FillChar(EntryId.Digest, SizeOf(EntryId.Digest), 0);
    Move(P^, EntryId.Digest[0], DigestLen);
    Inc(P, DigestLen);

    AddEntry(OctalToFileMode(ModeOctal), EntryName, EntryId);
  end;
end;

{ TCommitObject implementation }

constructor TCommitObject.Create;
begin
  inherited Create(otCommit);
  FTreeId := NullObjectId;
  SetLength(FParentIds, 0);
  FAuthor := MakeIdentity('', '');
  FCommitter := MakeIdentity('', '');
  FEncoding := '';
  FGpgSig := '';
  FMessage := '';
end;

destructor TCommitObject.Destroy;
begin
  SetLength(FParentIds, 0);
  inherited Destroy;
end;

procedure TCommitObject.AddParent(const AParentId: TObjectId);
begin
  SetLength(FParentIds, Length(FParentIds) + 1);
  FParentIds[High(FParentIds)] := AParentId;
end;

function TCommitObject.Serialize: TByteArray;
var
  S: string;
  I: Integer;
begin
  Result := nil;
  S := 'tree ' + ObjectIdToHex(FTreeId) + #10;
  for I := 0 to High(FParentIds) do
    S := S + 'parent ' + ObjectIdToHex(FParentIds[I]) + #10;

  S := S + 'author ' + FormatIdentity(FAuthor) + #10;
  S := S + 'committer ' + FormatIdentity(FCommitter) + #10;

  if FEncoding <> '' then
    S := S + 'encoding ' + FEncoding + #10;

  if FGpgSig <> '' then
    S := S + 'gpgsig ' + FGpgSig + #10;

  S := S + #10 + FMessage;

  SetLength(Result, Length(S));
  if Length(S) > 0 then
    Move(S[1], Result[0], Length(S));
end;

procedure TCommitObject.Deserialize(const RawData: Pointer; DataLen: SizeInt; Algo: THashAlgorithm);
var
  RawStr, Line, HeaderKey, HeaderVal: string;
  Lines: TStringArray;
  I, ColonPos, MsgStartIdx: Integer;
  InGpgSig: Boolean;
begin
  SetLength(FParentIds, 0);
  FTreeId := NullObjectId(Algo);
  FGpgSig := '';
  FEncoding := '';
  FMessage := '';

  if DataLen <= 0 then
    Exit;

  SetString(RawStr, PChar(RawData), DataLen);
  Lines := SplitStringByChar(RawStr, #10);

  MsgStartIdx := -1;
  InGpgSig := False;

  for I := 0 to High(Lines) do
  begin
    Line := Lines[I];
    if InGpgSig then
    begin
      if (Line <> '') and (Line[1] = ' ') then
      begin
        FGpgSig := FGpgSig + #10 + Copy(Line, 2, MaxInt);
        Continue;
      end
      else
        InGpgSig := False;
    end;

    if Line = '' then
    begin
      MsgStartIdx := I + 1;
      Break;
    end;

    ColonPos := Pos(' ', Line);
    if ColonPos <= 1 then
      Continue;

    HeaderKey := Copy(Line, 1, ColonPos - 1);
    HeaderVal := Copy(Line, ColonPos + 1, MaxInt);

    if HeaderKey = 'tree' then
      FTreeId := HexToObjectId(HeaderVal, Algo)
    else if HeaderKey = 'parent' then
      AddParent(HexToObjectId(HeaderVal, Algo))
    else if HeaderKey = 'author' then
      ParseIdentity(HeaderVal, FAuthor)
    else if HeaderKey = 'committer' then
      ParseIdentity(HeaderVal, FCommitter)
    else if HeaderKey = 'encoding' then
      FEncoding := HeaderVal
    else if HeaderKey = 'gpgsig' then
    begin
      FGpgSig := HeaderVal;
      InGpgSig := True;
    end;
  end;

  if MsgStartIdx >= 0 then
  begin
    FMessage := '';
    for I := MsgStartIdx to High(Lines) do
    begin
      if I > MsgStartIdx then
        FMessage := FMessage + #10 + Lines[I]
      else
        FMessage := Lines[I];
    end;
  end;
end;

function TCommitObject.AsString: string;
var
  Bytes: TByteArray;
begin
  Bytes := Serialize;
  if Length(Bytes) = 0 then
    Exit('');
  SetString(Result, PChar(@Bytes[0]), Length(Bytes));
end;

{ TTagObject implementation }

constructor TTagObject.Create;
begin
  inherited Create(otTag);
  FTargetId := NullObjectId;
  FTargetType := otNone;
  FTagName := '';
  FTagger := MakeIdentity('', '');
  FMessage := '';
end;

function TTagObject.Serialize: TByteArray;
var
  S: string;
begin
  Result := nil;
  S := 'object ' + ObjectIdToHex(FTargetId) + #10;
  S := S + 'type ' + ObjectTypeToString(FTargetType) + #10;
  S := S + 'tag ' + FTagName + #10;
  S := S + 'tagger ' + FormatIdentity(FTagger) + #10;
  S := S + #10 + FMessage;

  SetLength(Result, Length(S));
  if Length(S) > 0 then
    Move(S[1], Result[0], Length(S));
end;

procedure TTagObject.Deserialize(const RawData: Pointer; DataLen: SizeInt; Algo: THashAlgorithm);
var
  RawStr, Line, HeaderKey, HeaderVal: string;
  Lines: TStringArray;
  I, ColonPos, MsgStartIdx: Integer;
begin
  FTargetId := NullObjectId(Algo);
  FTargetType := otNone;
  FTagName := '';
  FMessage := '';

  if DataLen <= 0 then
    Exit;

  SetString(RawStr, PChar(RawData), DataLen);
  Lines := SplitStringByChar(RawStr, #10);
  MsgStartIdx := -1;

  for I := 0 to High(Lines) do
  begin
    Line := Lines[I];
    if Line = '' then
    begin
      MsgStartIdx := I + 1;
      Break;
    end;

    ColonPos := Pos(' ', Line);
    if ColonPos <= 1 then
      Continue;

    HeaderKey := Copy(Line, 1, ColonPos - 1);
    HeaderVal := Copy(Line, ColonPos + 1, MaxInt);

    if HeaderKey = 'object' then
      FTargetId := HexToObjectId(HeaderVal, Algo)
    else if HeaderKey = 'type' then
      FTargetType := StringToObjectType(HeaderVal)
    else if HeaderKey = 'tag' then
      FTagName := HeaderVal
    else if HeaderKey = 'tagger' then
      ParseIdentity(HeaderVal, FTagger);
  end;

  if MsgStartIdx >= 0 then
  begin
    FMessage := '';
    for I := MsgStartIdx to High(Lines) do
    begin
      if I > MsgStartIdx then
        FMessage := FMessage + #10 + Lines[I]
      else
        FMessage := Lines[I];
    end;
  end;
end;

function ParseObjectPayload(ObjType: TObjectType; const RawData: Pointer; DataLen: SizeInt; Algo: THashAlgorithm): TAnvilObject;
var
  BlobObj: TBlobObject;
  TreeObj: TTreeObject;
  CommitObj: TCommitObject;
  TagObj: TTagObject;
begin
  case ObjType of
    otBlob:
    begin
      BlobObj := TBlobObject.CreateWithData(RawData, DataLen);
      Result := BlobObj;
    end;
    otTree:
    begin
      TreeObj := TTreeObject.Create;
      TreeObj.Deserialize(RawData, DataLen, Algo);
      Result := TreeObj;
    end;
    otCommit:
    begin
      CommitObj := TCommitObject.Create;
      CommitObj.Deserialize(RawData, DataLen, Algo);
      Result := CommitObj;
    end;
    otTag:
    begin
      TagObj := TTagObject.Create;
      TagObj.Deserialize(RawData, DataLen, Algo);
      Result := TagObj;
    end;
  else
    raise EAnvilError.CreateWithCode(ERR_GENERIC, 'Cannot instantiate unknown object type');
  end;
end;

end.
