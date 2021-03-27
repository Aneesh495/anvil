{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Binary Git Index (DIRC) entry representation and wire serialization.
  Compliant with Git Index format versions 2 and 3, supporting 62-byte
  fixed headers, 8-byte padded paths, and stage numbers 0..3.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_index_entry;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DateUtils, anvil_types, anvil_errors, anvil_utils;

const
  INDEX_SIGNATURE = $44495243; { "DIRC" }

type
  { Stat information cached in index entry }
  TIndexStat = record
    CTimeSecs: LongWord;
    CTimeNano: LongWord;
    MTimeSecs: LongWord;
    MTimeNano: LongWord;
    Dev: LongWord;
    Ino: LongWord;
    Uid: LongWord;
    Gid: LongWord;
    FileSize: LongWord;
  end;

  { Individual index entry }
  PIndexEntry = ^TIndexEntry;
  TIndexEntry = record
    Stat: TIndexStat;
    Mode: TFileMode;
    Id: TObjectId;
    Flags: Word;
    ExtendedFlags: Word;
    Path: string;
    Stage: TStageNumber;
    AssumeUnchanged: Boolean;
    Valid: Boolean;
    SkipWorktree: Boolean;
  end;

{ Index entry creation and decoding }
function MakeIndexEntry(const APath: string; const AId: TObjectId; AMode: TFileMode;
                        AFileSize: LongWord = 0; AStage: TStageNumber = 0): TIndexEntry;

function ReadIndexEntry(Stream: TStream; Version: LongWord; Algo: THashAlgorithm; out Entry: TIndexEntry): SizeInt;
function WriteIndexEntry(Stream: TStream; Version: LongWord; const Entry: TIndexEntry): SizeInt;
function CompareIndexEntries(const A, B: TIndexEntry): Integer;

implementation

function MakeIndexEntry(const APath: string; const AId: TObjectId; AMode: TFileMode;
                        AFileSize: LongWord; AStage: TStageNumber): TIndexEntry;
begin
  Result.Path := APath;
  Result.Id := AId;
  Result.Mode := AMode;
  Result.Stage := AStage;
  Result.Flags := 0;
  Result.ExtendedFlags := 0;
  Result.AssumeUnchanged := False;
  Result.SkipWorktree := False;
  FillChar(Result.Stat, SizeOf(Result.Stat), 0);
  Result.Stat.FileSize := AFileSize;
  Result.Stat.MTimeSecs := LongWord(DateTimeToUnix(Now));
  Result.Stat.CTimeSecs := Result.Stat.MTimeSecs;
  Result.Flags := (Word(AStage and 3) shl 12);
  if Length(APath) < $0FFF then
    Result.Flags := Result.Flags or Word(Length(APath))
  else
    Result.Flags := Result.Flags or $0FFF;
  Result.Valid := True;
end;

function ReadIndexEntry(Stream: TStream; Version: LongWord; Algo: THashAlgorithm; out Entry: TIndexEntry): SizeInt;
var
  FixedBuf: array[0..61] of Byte;
  RawDigest: array[0..19] of Byte;
  OctalMode: LongWord;
  FlagsVal: Word;
  PathLen: Integer;
  PathBytes: array of Byte;
  B: Byte;
  PadCount: Integer;
  EntryStartPos: Int64;
  BytesConsumed: SizeInt;
  ExtFlags: Word;
begin
  FillChar(Entry, SizeOf(Entry), 0);
  EntryStartPos := Stream.Position;

  if Stream.Read(FixedBuf[0], 62) < 62 then
    Exit(0);

  Entry.Stat.CTimeSecs := ReadUInt32BE(@FixedBuf[0]);
  Entry.Stat.CTimeNano := ReadUInt32BE(@FixedBuf[4]);
  Entry.Stat.MTimeSecs := ReadUInt32BE(@FixedBuf[8]);
  Entry.Stat.MTimeNano := ReadUInt32BE(@FixedBuf[12]);
  Entry.Stat.Dev       := ReadUInt32BE(@FixedBuf[16]);
  Entry.Stat.Ino       := ReadUInt32BE(@FixedBuf[20]);

  OctalMode            := ReadUInt32BE(@FixedBuf[24]);
  Entry.Mode           := OctalToFileMode(OctalMode);

  Entry.Stat.Uid       := ReadUInt32BE(@FixedBuf[28]);
  Entry.Stat.Gid       := ReadUInt32BE(@FixedBuf[32]);
  Entry.Stat.FileSize  := ReadUInt32BE(@FixedBuf[36]);

  Move(FixedBuf[40], RawDigest[0], 20);
  Entry.Id.Algorithm   := Algo;
  FillChar(Entry.Id.Digest, SizeOf(Entry.Id.Digest), 0);
  Move(RawDigest[0], Entry.Id.Digest[0], 20);

  FlagsVal := ReadUInt16BE(@FixedBuf[60]);
  Entry.Flags := FlagsVal;
  Entry.Stage := TStageNumber((FlagsVal shr 12) and 3);
  Entry.AssumeUnchanged := (FlagsVal and $8000) <> 0;

  { Check for extended flags in index version 3 }
  if (Version >= 3) and ((FlagsVal and $4000) <> 0) then
  begin
    Stream.ReadBuffer(ExtFlags, 2);
    ExtFlags := (Word(PByte(@ExtFlags)[0]) shl 8) or Word(PByte(@ExtFlags)[1]);
    Entry.ExtendedFlags := ExtFlags;
    Entry.SkipWorktree := (ExtFlags and $4000) <> 0;
  end;

  { Read variable length null-terminated path }
  PathLen := 0;
  SetLength(PathBytes, 256);
  repeat
    if Stream.Read(B, 1) < 1 then
      raise EIndexCorrupt.CreateWithCode(ERR_INDEX_CORRUPT, 'Truncated path in index entry');
    if B = 0 then
      Break;
    if PathLen >= Length(PathBytes) then
      SetLength(PathBytes, Length(PathBytes) * 2);
    PathBytes[PathLen] := B;
    Inc(PathLen);
  until False;

  SetString(Entry.Path, PChar(@PathBytes[0]), PathLen);
  Entry.Valid := True;

  { In index v2/v3, each entry is padded with 1..8 null bytes to align entry size to 8-byte boundary }
  BytesConsumed := Stream.Position - EntryStartPos;
  PadCount := (8 - (BytesConsumed mod 8)) mod 8;
  if PadCount > 0 then
  begin
    while PadCount > 0 do
    begin
      Stream.ReadBuffer(B, 1);
      Dec(PadCount);
    end;
  end;

  Result := Stream.Position - EntryStartPos;
end;

function WriteIndexEntry(Stream: TStream; Version: LongWord; const Entry: TIndexEntry): SizeInt;
var
  FixedBuf: array[0..61] of Byte;
  EntryStartPos: Int64;
  OctalMode: LongWord;
  FlagsVal, ExtFlags: Word;
  PadCount, I: Integer;
  ZeroByte: Byte;
  TotalBytes: Int64;
begin
  EntryStartPos := Stream.Position;

  WriteUInt32BE(@FixedBuf[0],  Entry.Stat.CTimeSecs);
  WriteUInt32BE(@FixedBuf[4],  Entry.Stat.CTimeNano);
  WriteUInt32BE(@FixedBuf[8],  Entry.Stat.MTimeSecs);
  WriteUInt32BE(@FixedBuf[12], Entry.Stat.MTimeNano);
  WriteUInt32BE(@FixedBuf[16], Entry.Stat.Dev);
  WriteUInt32BE(@FixedBuf[20], Entry.Stat.Ino);

  OctalMode := FileModeToOctal(Entry.Mode);
  WriteUInt32BE(@FixedBuf[24], OctalMode);

  WriteUInt32BE(@FixedBuf[28], Entry.Stat.Uid);
  WriteUInt32BE(@FixedBuf[32], Entry.Stat.Gid);
  WriteUInt32BE(@FixedBuf[36], Entry.Stat.FileSize);

  Move(Entry.Id.Digest[0], FixedBuf[40], 20);

  FlagsVal := (Word(Entry.Stage and 3) shl 12);
  if Entry.AssumeUnchanged then
    FlagsVal := FlagsVal or $8000;

  if Length(Entry.Path) < $0FFF then
    FlagsVal := FlagsVal or Word(Length(Entry.Path))
  else
    FlagsVal := FlagsVal or $0FFF;

  if (Version >= 3) and (Entry.ExtendedFlags <> 0) then
    FlagsVal := FlagsVal or $4000;

  WriteUInt16BE(@FixedBuf[60], FlagsVal);
  Stream.WriteBuffer(FixedBuf[0], 62);

  if (Version >= 3) and ((FlagsVal and $4000) <> 0) then
  begin
    ExtFlags := Entry.ExtendedFlags;
    FixedBuf[0] := Byte((ExtFlags shr 8) and $FF);
    FixedBuf[1] := Byte(ExtFlags and $FF);
    Stream.WriteBuffer(FixedBuf[0], 2);
  end;

  if Length(Entry.Path) > 0 then
    Stream.WriteBuffer(Entry.Path[1], Length(Entry.Path));

  ZeroByte := 0;
  Stream.WriteBuffer(ZeroByte, 1); { Null terminator }

  { Pad to 8-byte boundary }
  TotalBytes := Stream.Position - EntryStartPos;
  PadCount := (8 - (TotalBytes mod 8)) mod 8;
  for I := 1 to PadCount do
    Stream.WriteBuffer(ZeroByte, 1);

  Result := Stream.Position - EntryStartPos;
end;

function CompareIndexEntries(const A, B: TIndexEntry): Integer;
begin
  Result := CompareStr(A.Path, B.Path);
  if Result = 0 then
  begin
    if A.Stage < B.Stage then
      Result := -1
    else if A.Stage > B.Stage then
      Result := 1;
  end;
end;

end.
