{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  General utility functions, binary serialization primitives,
  endian conversions, atomic file operations, and path canonicalization.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_utils;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DateUtils, anvil_types, anvil_errors;

{ Endian conversion utilities }
function ReadUInt16BE(P: Pointer): Word;
function ReadUInt32BE(P: Pointer): LongWord;
function ReadUInt64BE(P: Pointer): QWord;
procedure WriteUInt16BE(P: Pointer; V: Word);
procedure WriteUInt32BE(P: Pointer; V: LongWord);
procedure WriteUInt64BE(P: Pointer; V: QWord);

{ Variable-length integer encoding (LEB128 and Git pack varint) }
function ReadVarInt(var P: PByte; const PEnd: PByte; out Val: QWord): Boolean;
function WriteVarInt(var P: PByte; Val: QWord): Integer;
function ReadPackOffset(var P: PByte; const PEnd: PByte; out Offset: Int64): Boolean;

{ File and directory operations }
function EnsureDirectoryExists(const DirPath: string): Boolean;
function ReadEntireFile(const FilePath: string): TByteArray;
function ReadEntireFileString(const FilePath: string): string;
procedure WriteEntireFile(const FilePath: string; const Data: array of Byte);
procedure WriteEntireFileString(const FilePath: string; const S: string);
function AtomicWriteFile(const TargetPath: string; const Data: Pointer; DataLen: SizeInt): Boolean;
function AtomicWriteString(const TargetPath: string; const S: string): Boolean;

{ Path manipulation and repository discovery }
function NormalizePath(const RawPath: string): string;
function MakeRelativePath(const BaseDir, FullPath: string): string;
function JoinPaths(const PathA, PathB: string): string;
function FindRepositoryRoot(const StartDir: string; out RepoRoot, DotDir: string): Boolean;

{ String splitting and formatting }
function SplitStringByChar(const S: string; Delim: Char): TStringArray;
function FormatBytesHuman(Bytes: QWord): string;
function FormatDateTimeGit(UnixSecs: Int64; OffsetMins: SmallInt): string;

implementation

function ReadUInt16BE(P: Pointer): Word;
var
  BP: PByte;
begin
  BP := PByte(P);
  Result := (Word(BP[0]) shl 8) or Word(BP[1]);
end;

function ReadUInt32BE(P: Pointer): LongWord;
var
  BP: PByte;
begin
  BP := PByte(P);
  Result := (LongWord(BP[0]) shl 24) or
            (LongWord(BP[1]) shl 16) or
            (LongWord(BP[2]) shl 8) or
             LongWord(BP[3]);
end;

function ReadUInt64BE(P: Pointer): QWord;
var
  BP: PByte;
begin
  BP := PByte(P);
  Result := (QWord(BP[0]) shl 56) or
            (QWord(BP[1]) shl 48) or
            (QWord(BP[2]) shl 40) or
            (QWord(BP[3]) shl 32) or
            (QWord(BP[4]) shl 24) or
            (QWord(BP[5]) shl 16) or
            (QWord(BP[6]) shl 8) or
             QWord(BP[7]);
end;

procedure WriteUInt16BE(P: Pointer; V: Word);
var
  BP: PByte;
begin
  BP := PByte(P);
  BP[0] := Byte((V shr 8) and $FF);
  BP[1] := Byte(V and $FF);
end;

procedure WriteUInt32BE(P: Pointer; V: LongWord);
var
  BP: PByte;
begin
  BP := PByte(P);
  BP[0] := Byte((V shr 24) and $FF);
  BP[1] := Byte((V shr 16) and $FF);
  BP[2] := Byte((V shr 8) and $FF);
  BP[3] := Byte(V and $FF);
end;

procedure WriteUInt64BE(P: Pointer; V: QWord);
var
  BP: PByte;
begin
  BP := PByte(P);
  BP[0] := Byte((V shr 56) and $FF);
  BP[1] := Byte((V shr 48) and $FF);
  BP[2] := Byte((V shr 40) and $FF);
  BP[3] := Byte((V shr 32) and $FF);
  BP[4] := Byte((V shr 24) and $FF);
  BP[5] := Byte((V shr 16) and $FF);
  BP[6] := Byte((V shr 8) and $FF);
  BP[7] := Byte(V and $FF);
end;

function ReadVarInt(var P: PByte; const PEnd: PByte; out Val: QWord): Boolean;
var
  Shift: Integer;
  B: Byte;
begin
  Val := 0;
  Shift := 0;
  while P < PEnd do
  begin
    B := P^;
    Inc(P);
    Val := Val or (QWord(B and $7F) shl Shift);
    if (B and $80) = 0 then
      Exit(True);
    Inc(Shift, 7);
    if Shift > 64 then
      Exit(False);
  end;
  Result := False;
end;

function WriteVarInt(var P: PByte; Val: QWord): Integer;
var
  Count: Integer;
  B: Byte;
begin
  Count := 0;
  repeat
    B := Byte(Val and $7F);
    Val := Val shr 7;
    if Val <> 0 then
      B := B or $80;
    P^ := B;
    Inc(P);
    Inc(Count);
  until Val = 0;
  Result := Count;
end;

function ReadPackOffset(var P: PByte; const PEnd: PByte; out Offset: Int64): Boolean;
var
  B: Byte;
begin
  Offset := 0;
  if P >= PEnd then
    Exit(False);
  B := P^;
  Inc(P);
  Offset := B and $7F;
  while (B and $80) <> 0 do
  begin
    if P >= PEnd then
      Exit(False);
    B := P^;
    Inc(P);
    Offset := ((Offset + 1) shl 7) or (B and $7F);
  end;
  Result := True;
end;

function EnsureDirectoryExists(const DirPath: string): Boolean;
begin
  if DirectoryExists(DirPath) then
    Exit(True);
  Result := ForceDirectories(DirPath);
end;

function ReadEntireFile(const FilePath: string): TByteArray;
var
  FS: TFileStream;
  Size: Int64;
begin
  Result := nil;
  SetLength(Result, 0);
  if not FileExists(FilePath) then
    Exit;
  FS := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyNone);
  try
    Size := FS.Size;
    SetLength(Result, Size);
    if Size > 0 then
      FS.ReadBuffer(Result[0], Size);
  finally
    FS.Free;
  end;
end;

function ReadEntireFileString(const FilePath: string): string;
var
  Bytes: TByteArray;
begin
  Bytes := ReadEntireFile(FilePath);
  if Length(Bytes) = 0 then
    Exit('');
  SetString(Result, PChar(@Bytes[0]), Length(Bytes));
end;

procedure WriteEntireFile(const FilePath: string; const Data: array of Byte);
var
  FS: TFileStream;
  ParentDir: string;
begin
  ParentDir := ExtractFileDir(FilePath);
  if (ParentDir <> '') and not DirectoryExists(ParentDir) then
    ForceDirectories(ParentDir);

  FS := TFileStream.Create(FilePath, fmCreate);
  try
    if Length(Data) > 0 then
      FS.WriteBuffer(Data[0], Length(Data));
  finally
    FS.Free;
  end;
end;

procedure WriteEntireFileString(const FilePath: string; const S: string);
var
  FS: TFileStream;
  ParentDir: string;
begin
  ParentDir := ExtractFileDir(FilePath);
  if (ParentDir <> '') and not DirectoryExists(ParentDir) then
    ForceDirectories(ParentDir);

  FS := TFileStream.Create(FilePath, fmCreate);
  try
    if Length(S) > 0 then
      FS.WriteBuffer(S[1], Length(S));
  finally
    FS.Free;
  end;
end;

function AtomicWriteFile(const TargetPath: string; const Data: Pointer; DataLen: SizeInt): Boolean;
var
  TmpPath: string;
  FS: TFileStream;
  ParentDir: string;
begin
  ParentDir := ExtractFileDir(TargetPath);
  if (ParentDir <> '') and not DirectoryExists(ParentDir) then
    ForceDirectories(ParentDir);

  TmpPath := TargetPath + Format('.tmp.%d.%d', [GetProcessID, Random(1000000)]);
  try
    FS := TFileStream.Create(TmpPath, fmCreate);
    try
      if DataLen > 0 then
        FS.WriteBuffer(Data^, DataLen);
    finally
      FS.Free;
    end;

    if FileExists(TargetPath) then
      DeleteFile(TargetPath);

    Result := RenameFile(TmpPath, TargetPath);
    if not Result then
      DeleteFile(TmpPath);
  except
    if FileExists(TmpPath) then
      DeleteFile(TmpPath);
    Result := False;
  end;
end;

function AtomicWriteString(const TargetPath: string; const S: string): Boolean;
begin
  if Length(S) = 0 then
    Result := AtomicWriteFile(TargetPath, nil, 0)
  else
    Result := AtomicWriteFile(TargetPath, @S[1], Length(S));
end;

function NormalizePath(const RawPath: string): string;
var
  Parts, OutParts: TStringArray;
  P, Res: string;
  I, Top: Integer;
  IsAbsolute: Boolean;
begin
  if RawPath = '' then
    Exit('.');

  IsAbsolute := (RawPath[1] = '/');
  Parts := SplitStringByChar(RawPath, '/');
  SetLength(OutParts, Length(Parts));
  Top := 0;

  for I := 0 to High(Parts) do
  begin
    P := Parts[I];
    if (P = '') or (P = '.') then
      Continue;
    if P = '..' then
    begin
      if Top > 0 then
        Dec(Top)
      else if not IsAbsolute then
      begin
        OutParts[Top] := '..';
        Inc(Top);
      end;
    end
    else
    begin
      OutParts[Top] := P;
      Inc(Top);
    end;
  end;

  Res := '';
  for I := 0 to Top - 1 do
  begin
    if I > 0 then
      Res := Res + '/' + OutParts[I]
    else
      Res := OutParts[I];
  end;

  if IsAbsolute then
    Result := '/' + Res
  else if Res = '' then
    Result := '.'
  else
    Result := Res;
end;

function MakeRelativePath(const BaseDir, FullPath: string): string;
var
  NormBase, NormFull: string;
begin
  NormBase := NormalizePath(BaseDir);
  NormFull := NormalizePath(FullPath);

  if NormBase = NormFull then
    Exit('.');

  if not (NormBase[Length(NormBase)] = '/') then
    NormBase := NormBase + '/';

  if Pos(NormBase, NormFull) = 1 then
    Result := Copy(NormFull, Length(NormBase) + 1, MaxInt)
  else
    Result := NormFull;
end;

function JoinPaths(const PathA, PathB: string): string;
begin
  if PathA = '' then
    Result := PathB
  else if PathB = '' then
    Result := PathA
  else if PathA[Length(PathA)] = '/' then
    Result := PathA + PathB
  else
    Result := PathA + '/' + PathB;
end;

function FindRepositoryRoot(const StartDir: string; out RepoRoot, DotDir: string): Boolean;
var
  CurrentDir, ParentDir, Candidate: string;
begin
  CurrentDir := ExpandFileName(StartDir);
  while True do
  begin
    { Check for .anvil directory }
    Candidate := JoinPaths(CurrentDir, '.anvil');
    if DirectoryExists(Candidate) then
    begin
      RepoRoot := CurrentDir;
      DotDir := Candidate;
      Exit(True);
    end;

    { Check for .git directory for Git compatibility }
    Candidate := JoinPaths(CurrentDir, '.git');
    if DirectoryExists(Candidate) then
    begin
      RepoRoot := CurrentDir;
      DotDir := Candidate;
      Exit(True);
    end;

    ParentDir := ExtractFileDir(CurrentDir);
    if (ParentDir = '') or (ParentDir = CurrentDir) then
      Break;
    CurrentDir := ParentDir;
  end;

  RepoRoot := '';
  DotDir := '';
  Result := False;
end;

function SplitStringByChar(const S: string; Delim: Char): TStringArray;
var
  Count, I, StartIdx, Len: Integer;
begin
  Result := nil;
  SetLength(Result, 0);
  Len := Length(S);
  if Len = 0 then
    Exit;

  Count := 1;
  for I := 1 to Len do
  begin
    if S[I] = Delim then
      Inc(Count);
  end;

  SetLength(Result, Count);
  StartIdx := 1;
  Count := 0;

  for I := 1 to Len do
  begin
    if S[I] = Delim then
    begin
      Result[Count] := Copy(S, StartIdx, I - StartIdx);
      Inc(Count);
      StartIdx := I + 1;
    end;
  end;
  Result[Count] := Copy(S, StartIdx, Len - StartIdx + 1);
end;

function FormatBytesHuman(Bytes: QWord): string;
begin
  if Bytes < 1024 then
    Result := Format('%d B', [Bytes])
  else if Bytes < 1048576 then
    Result := Format('%.2f KB', [Bytes / 1024.0])
  else if Bytes < 1073741824 then
    Result := Format('%.2f MB', [Bytes / 1048576.0])
  else
    Result := Format('%.2f GB', [Bytes / 1073741824.0]);
end;

function FormatDateTimeGit(UnixSecs: Int64; OffsetMins: SmallInt): string;
var
  DT: TDateTime;
  Sign: Char;
  AbsMins, Hours, Mins: Integer;
begin
  DT := UnixToDateTime(UnixSecs);
  if OffsetMins >= 0 then
    Sign := '+'
  else
    Sign := '-';
  AbsMins := Abs(OffsetMins);
  Hours := AbsMins div 60;
  Mins := AbsMins mod 60;

  Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', DT) +
            Format(' %s%.2d%.2d', [Sign, Hours, Mins]);
end;

end.
