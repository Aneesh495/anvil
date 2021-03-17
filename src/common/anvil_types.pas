{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Core type definitions, object identifiers, file modes, and basic records.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_types;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DateUtils;

const
  ANVIL_VERSION_MAJOR = 1;
  ANVIL_VERSION_MINOR = 0;
  ANVIL_VERSION_PATCH = 0;
  ANVIL_VERSION_STRING = '1.0.0';

  { Object Identifier lengths }
  SHA1_DIGEST_LENGTH = 20;
  SHA1_HEX_LENGTH    = 40;
  SHA256_DIGEST_LENGTH = 32;
  SHA256_HEX_LENGTH    = 64;

  { Default buffer and window parameters }
  DEFAULT_PACK_WINDOW_MEMORY = 104857600; { 100 MB }
  DEFAULT_MAX_DELTA_DEPTH    = 50;
  DEFAULT_COMPRESSION_LEVEL  = 6;
  ANVIL_PAGE_SIZE            = 8192;

type
  { Supported hash algorithms for repository backends }
  THashAlgorithm = (
    haSHA1,
    haSHA256
  );

  { Raw binary object identifier }
  TObjectId = record
    Digest: array[0..31] of Byte;
    Algorithm: THashAlgorithm;
  end;
  PObjectId = ^TObjectId;

  { Git object types }
  TObjectType = (
    otNone,
    otCommit,
    otTree,
    otBlob,
    otTag,
    otOfsDelta,
    otRefDelta
  );

  { Unix file modes mapped to Git representations }
  TFileMode = (
    fmNone,
    fmDirectory,   { 040000 }
    fmRegular,     { 100644 }
    fmExecutable,  { 100755 }
    fmSymlink,     { 120000 }
    fmGitLink      { 160000 }
  );

  { Staging conflict stages }
  TStageNumber = 0..3;

  { Merge strategies }
  TMergeStrategy = (
    msRecursive,
    msResolve,
    msOurs,
    msTheirs
  );

  { Diff output formats }
  TDiffFormat = (
    dfUnified,
    dfStat,
    dfNameOnly,
    dfNameStatus,
    dfRaw
  );

  { Reset operational modes }
  TResetMode = (
    rmSoft,
    rmMixed,
    rmHard
  );

  { Rebase operational actions }
  TRebaseAction = (
    raPick,
    raReword,
    raEdit,
    raSquash,
    raFixup,
    raDrop
  );

  { Time identity with timezone offset in minutes }
  TAnvilTime = record
    Seconds: Int64;
    OffsetMinutes: SmallInt;
  end;

  { Author or Committer metadata identity }
  TIdentity = record
    Name: string;
    Email: string;
    When: TAnvilTime;
  end;

  { Zero-copy byte slice }
  TByteSpan = record
    Data: PByte;
    Length: SizeInt;
  end;

  { Dynamic array aliases }
  TObjectIdArray = array of TObjectId;
  TStringArray = array of string;
  TByteArray = array of Byte;

{ Global helper routines }
function NullObjectId(Algo: THashAlgorithm = haSHA1): TObjectId;
function IsNullObjectId(const Id: TObjectId): Boolean;
function ObjectIdEqual(const A, B: TObjectId): Boolean;
function ObjectIdCompare(const A, B: TObjectId): Integer;
function ObjectIdToHex(const Id: TObjectId): string;
function HexToObjectId(const HexStr: string; Algo: THashAlgorithm = haSHA1): TObjectId;
function TryHexToObjectId(const HexStr: string; out Id: TObjectId; Algo: THashAlgorithm = haSHA1): Boolean;

function ObjectTypeToString(ObjType: TObjectType): string;
function StringToObjectType(const S: string): TObjectType;
function ObjectTypeToPackType(ObjType: TObjectType): Byte;
function PackTypeToObjectType(PackType: Byte): TObjectType;

function FileModeToOctal(Mode: TFileMode): LongWord;
function OctalToFileMode(Octal: LongWord): TFileMode;
function FileModeToString(Mode: TFileMode): string;

function MakeIdentity(const AName, AEmail: string; WhenSecs: Int64 = 0; OffsetMins: SmallInt = 0): TIdentity;
function FormatIdentity(const Id: TIdentity): string;
function ParseIdentity(const Line: string; out Id: TIdentity): Boolean;

implementation

function NullObjectId(Algo: THashAlgorithm): TObjectId;
begin
  FillChar(Result.Digest, SizeOf(Result.Digest), 0);
  Result.Algorithm := Algo;
end;

function IsNullObjectId(const Id: TObjectId): Boolean;
var
  Len, I: Integer;
begin
  if Id.Algorithm = haSHA1 then
    Len := SHA1_DIGEST_LENGTH
  else
    Len := SHA256_DIGEST_LENGTH;

  for I := 0 to Len - 1 do
  begin
    if Id.Digest[I] <> 0 then
      Exit(False);
  end;
  Result := True;
end;

function ObjectIdEqual(const A, B: TObjectId): Boolean;
var
  Len: Integer;
begin
  if A.Algorithm <> B.Algorithm then
    Exit(False);
  if A.Algorithm = haSHA1 then
    Len := SHA1_DIGEST_LENGTH
  else
    Len := SHA256_DIGEST_LENGTH;
  Result := CompareMem(@A.Digest[0], @B.Digest[0], Len);
end;

function ObjectIdCompare(const A, B: TObjectId): Integer;
var
  Len, I: Integer;
begin
  if A.Algorithm <> B.Algorithm then
  begin
    if A.Algorithm < B.Algorithm then
      Exit(-1)
    else
      Exit(1);
  end;

  if A.Algorithm = haSHA1 then
    Len := SHA1_DIGEST_LENGTH
  else
    Len := SHA256_DIGEST_LENGTH;

  for I := 0 to Len - 1 do
  begin
    if A.Digest[I] < B.Digest[I] then
      Exit(-1)
    else if A.Digest[I] > B.Digest[I] then
      Exit(1);
  end;
  Result := 0;
end;

function ObjectIdToHex(const Id: TObjectId): string;
const
  HexChars: array[0..15] of Char = '0123456789abcdef';
var
  Len, I: Integer;
begin
  if Id.Algorithm = haSHA1 then
    Len := SHA1_DIGEST_LENGTH
  else
    Len := SHA256_DIGEST_LENGTH;

  SetLength(Result, Len * 2);
  for I := 0 to Len - 1 do
  begin
    Result[I * 2 + 1] := HexChars[(Id.Digest[I] shr 4) and $0F];
    Result[I * 2 + 2] := HexChars[Id.Digest[I] and $0F];
  end;
end;

function TryHexToObjectId(const HexStr: string; out Id: TObjectId; Algo: THashAlgorithm): Boolean;
var
  ExpectedLen, I: Integer;
  HighNibble, LowNibble: Integer;
  C1, C2: Char;

  function CharToNibble(C: Char): Integer;
  begin
    case C of
      '0'..'9': Result := Ord(C) - Ord('0');
      'a'..'f': Result := Ord(C) - Ord('a') + 10;
      'A'..'F': Result := Ord(C) - Ord('A') + 10;
    else
      Result := -1;
    end;
  end;

begin
  Id := NullObjectId(Algo);
  if Algo = haSHA1 then
    ExpectedLen := SHA1_HEX_LENGTH
  else
    ExpectedLen := SHA256_HEX_LENGTH;

  if Length(HexStr) <> ExpectedLen then
    Exit(False);

  for I := 0 to (ExpectedLen div 2) - 1 do
  begin
    C1 := HexStr[I * 2 + 1];
    C2 := HexStr[I * 2 + 2];
    HighNibble := CharToNibble(C1);
    LowNibble := CharToNibble(C2);
    if (HighNibble < 0) or (LowNibble < 0) then
      Exit(False);
    Id.Digest[I] := Byte((HighNibble shl 4) or LowNibble);
  end;
  Result := True;
end;

function HexToObjectId(const HexStr: string; Algo: THashAlgorithm): TObjectId;
begin
  if not TryHexToObjectId(HexStr, Result, Algo) then
    raise Exception.CreateFmt('Invalid hex object identifier: %s', [HexStr]);
end;

function ObjectTypeToString(ObjType: TObjectType): string;
begin
  case ObjType of
    otCommit:   Result := 'commit';
    otTree:     Result := 'tree';
    otBlob:     Result := 'blob';
    otTag:      Result := 'tag';
    otOfsDelta: Result := 'ofs-delta';
    otRefDelta: Result := 'ref-delta';
  else
    Result := 'unknown';
  end;
end;

function StringToObjectType(const S: string): TObjectType;
begin
  if S = 'commit' then
    Result := otCommit
  else if S = 'tree' then
    Result := otTree
  else if S = 'blob' then
    Result := otBlob
  else if S = 'tag' then
    Result := otTag
  else if S = 'ofs-delta' then
    Result := otOfsDelta
  else if S = 'ref-delta' then
    Result := otRefDelta
  else
    Result := otNone;
end;

function ObjectTypeToPackType(ObjType: TObjectType): Byte;
begin
  case ObjType of
    otCommit:   Result := 1;
    otTree:     Result := 2;
    otBlob:     Result := 3;
    otTag:      Result := 4;
    otOfsDelta: Result := 6;
    otRefDelta: Result := 7;
  else
    Result := 0;
  end;
end;

function PackTypeToObjectType(PackType: Byte): TObjectType;
begin
  case PackType of
    1: Result := otCommit;
    2: Result := otTree;
    3: Result := otBlob;
    4: Result := otTag;
    6: Result := otOfsDelta;
    7: Result := otRefDelta;
  else
    Result := otNone;
  end;
end;

function FileModeToOctal(Mode: TFileMode): LongWord;
begin
  case Mode of
    fmDirectory:  Result := $4000;  { Octal 0040000 }
    fmRegular:    Result := $81A4;  { Octal 0100644 }
    fmExecutable: Result := $81ED;  { Octal 0100755 }
    fmSymlink:    Result := $A000;  { Octal 0120000 }
    fmGitLink:    Result := $E000;  { Octal 0160000 }
  else
    Result := 0;
  end;
end;

function OctalToFileMode(Octal: LongWord): TFileMode;
begin
  case Octal of
    $4000:       Result := fmDirectory;
    $81A4:       Result := fmRegular;
    $81ED:       Result := fmExecutable;
    $A000:       Result := fmSymlink;
    $E000:       Result := fmGitLink;
  else
    { Mask out permission bits for directory check }
    if (Octal and $F000) = $4000 then
      Result := fmDirectory
    else if (Octal and $F000) = $A000 then
      Result := fmSymlink
    else if (Octal and $F000) = $E000 then
      Result := fmGitLink
    else if (Octal and $0049) <> 0 then { Check executable bit }
      Result := fmExecutable
    else
      Result := fmRegular;
  end;
end;

function FileModeToString(Mode: TFileMode): string;
begin
  case Mode of
    fmDirectory:  Result := '040000';
    fmRegular:    Result := '100644';
    fmExecutable: Result := '100755';
    fmSymlink:    Result := '120000';
    fmGitLink:    Result := '160000';
  else
    Result := '000000';
  end;
end;

function MakeIdentity(const AName, AEmail: string; WhenSecs: Int64; OffsetMins: SmallInt): TIdentity;
begin
  Result.Name := AName;
  Result.Email := AEmail;
  if WhenSecs = 0 then
    Result.When.Seconds := DateTimeToUnix(Now)
  else
    Result.When.Seconds := WhenSecs;
  Result.When.OffsetMinutes := OffsetMins;
end;

function FormatIdentity(const Id: TIdentity): string;
var
  Sign: Char;
  AbsMins, Hours, Mins: Integer;
begin
  if Id.When.OffsetMinutes >= 0 then
    Sign := '+'
  else
    Sign := '-';
  AbsMins := Abs(Id.When.OffsetMinutes);
  Hours := AbsMins div 60;
  Mins := AbsMins mod 60;

  Result := Format('%s <%s> %d %s%.2d%.2d', [
    Id.Name,
    Id.Email,
    Id.When.Seconds,
    Sign,
    Hours,
    Mins
  ]);
end;

function ParseIdentity(const Line: string; out Id: TIdentity): Boolean;
var
  LtPos, GtPos, LastSpacePos, SecondLastSpacePos: Integer;
  TimeStr, TzStr: string;
  TzVal, SignMult: Integer;
begin
  Id.Name := '';
  Id.Email := '';
  Id.When.Seconds := 0;
  Id.When.OffsetMinutes := 0;

  LtPos := Pos('<', Line);
  GtPos := Pos('>', Line);
  if (LtPos <= 1) or (GtPos <= LtPos) then
    Exit(False);

  Id.Name := Trim(Copy(Line, 1, LtPos - 1));
  Id.Email := Copy(Line, LtPos + 1, GtPos - LtPos - 1);

  LastSpacePos := LastDelimiter(' ', Line);
  if LastSpacePos <= GtPos + 1 then
    Exit(False);

  TzStr := Copy(Line, LastSpacePos + 1, MaxInt);
  SecondLastSpacePos := LastDelimiter(' ', Copy(Line, 1, LastSpacePos - 1));
  if SecondLastSpacePos <= GtPos then
    Exit(False);

  TimeStr := Copy(Line, SecondLastSpacePos + 1, LastSpacePos - SecondLastSpacePos - 1);

  try
    Id.When.Seconds := StrToInt64(TimeStr);
  except
    Exit(False);
  end;

  if (Length(TzStr) >= 5) and ((TzStr[1] = '+') or (TzStr[1] = '-')) then
  begin
    if TzStr[1] = '-' then
      SignMult := -1
    else
      SignMult := 1;
    try
      TzVal := StrToInt(Copy(TzStr, 2, 4));
      Id.When.OffsetMinutes := SignMult * ((TzVal div 100) * 60 + (TzVal mod 100));
    except
      Id.When.OffsetMinutes := 0;
    end;
  end;

  Result := True;
end;

end.
