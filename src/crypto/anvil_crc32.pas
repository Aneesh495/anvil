{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  High-speed cyclic redundancy check (CRC-32) implementations.
  Includes standard IEEE 802.3 CRC-32 (for Git pack index v2)
  and Castagnoli CRC-32C for modern storage verification.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_crc32;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

{ IEEE 802.3 CRC32 (used by Git pack index files) }
function CRC32Init: LongWord;
function CRC32Update(CurrentCRC: LongWord; const Data; Len: SizeInt): LongWord;
function CRC32Final(CurrentCRC: LongWord): LongWord;
function CRC32Buffer(const Data; Len: SizeInt): LongWord;
function CRC32String(const S: string): LongWord;

{ Castagnoli CRC32-C }
function CRC32CInit: LongWord;
function CRC32CUpdate(CurrentCRC: LongWord; const Data; Len: SizeInt): LongWord;
function CRC32CFinal(CurrentCRC: LongWord): LongWord;
function CRC32CBuffer(const Data; Len: SizeInt): LongWord;

implementation

var
  IEEE_Table: array[0..255] of LongWord;
  Castagnoli_Table: array[0..255] of LongWord;
  TablesInitialized: Boolean = False;

procedure InitCRCTables;
var
  I, J: Integer;
  V_IEEE, V_Cast: LongWord;
begin
  if TablesInitialized then
    Exit;

  for I := 0 to 255 do
  begin
    V_IEEE := LongWord(I);
    V_Cast := LongWord(I);
    for J := 0 to 7 do
    begin
      if (V_IEEE and 1) <> 0 then
        V_IEEE := (V_IEEE shr 1) xor $EDB88320
      else
        V_IEEE := V_IEEE shr 1;

      if (V_Cast and 1) <> 0 then
        V_Cast := (V_Cast shr 1) xor $82F63B78
      else
        V_Cast := V_Cast shr 1;
    end;
    IEEE_Table[I] := V_IEEE;
    Castagnoli_Table[I] := V_Cast;
  end;

  TablesInitialized := True;
end;

function CRC32Init: LongWord;
begin
  if not TablesInitialized then
    InitCRCTables;
  Result := $FFFFFFFF;
end;

function CRC32Update(CurrentCRC: LongWord; const Data; Len: SizeInt): LongWord;
var
  P: PByte;
  I: SizeInt;
begin
  if not TablesInitialized then
    InitCRCTables;
  P := PByte(@Data);
  Result := CurrentCRC;
  for I := 0 to Len - 1 do
  begin
    Result := IEEE_Table[(Result xor P^) and $FF] xor (Result shr 8);
    Inc(P);
  end;
end;

function CRC32Final(CurrentCRC: LongWord): LongWord;
begin
  Result := CurrentCRC xor $FFFFFFFF;
end;

function CRC32Buffer(const Data; Len: SizeInt): LongWord;
begin
  Result := CRC32Final(CRC32Update(CRC32Init, Data, Len));
end;

function CRC32String(const S: string): LongWord;
begin
  if Length(S) = 0 then
    Result := CRC32Buffer('', 0)
  else
    Result := CRC32Buffer(S[1], Length(S));
end;

function CRC32CInit: LongWord;
begin
  if not TablesInitialized then
    InitCRCTables;
  Result := $FFFFFFFF;
end;

function CRC32CUpdate(CurrentCRC: LongWord; const Data; Len: SizeInt): LongWord;
var
  P: PByte;
  I: SizeInt;
begin
  if not TablesInitialized then
    InitCRCTables;
  P := PByte(@Data);
  Result := CurrentCRC;
  for I := 0 to Len - 1 do
  begin
    Result := Castagnoli_Table[(Result xor P^) and $FF] xor (Result shr 8);
    Inc(P);
  end;
end;

function CRC32CFinal(CurrentCRC: LongWord): LongWord;
begin
  Result := CurrentCRC xor $FFFFFFFF;
end;

function CRC32CBuffer(const Data; Len: SizeInt): LongWord;
begin
  Result := CRC32CFinal(CRC32CUpdate(CRC32CInit, Data, Len));
end;

initialization
  InitCRCTables;

end.
