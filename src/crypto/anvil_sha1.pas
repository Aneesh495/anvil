{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Pure Pascal implementation of the FIPS 180-1 Secure Hash Algorithm (SHA-1).
  Produces 160-bit (20-byte) cryptographic message digests for Git objects.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_sha1;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, anvil_types;

type
  { SHA-1 state machine context }
  TSHA1Context = record
    State: array[0..4] of LongWord;
    Count: QWord;
    Buffer: array[0..63] of Byte;
  end;
  PSHA1Context = ^TSHA1Context;

  { Raw 20-byte SHA-1 digest }
  TSHA1Digest = array[0..19] of Byte;

{ Lifecycle procedures }
procedure SHA1Init(var Ctx: TSHA1Context);
procedure SHA1Update(var Ctx: TSHA1Context; const Data; Len: SizeInt);
procedure SHA1Final(var Ctx: TSHA1Context; out Digest: TSHA1Digest);

{ One-shot hashing helpers }
function SHA1Buffer(const Data; Len: SizeInt): TSHA1Digest;
function SHA1String(const S: string): TSHA1Digest;
function SHA1Stream(Stream: TStream): TSHA1Digest;
function SHA1DigestToHex(const Digest: TSHA1Digest): string;
function SHA1DigestToObjectId(const Digest: TSHA1Digest): TObjectId;

implementation

{ Bitwise circular left rotation }
function ROL(X: LongWord; N: Byte): LongWord; inline;
begin
  Result := (X shl N) or (X shr (32 - N));
end;

procedure SHA1Transform(var State: array of LongWord; const Buffer: array of Byte);
var
  A, B, C, D, E, T: LongWord;
  W: array[0..79] of LongWord;
  I: Integer;
begin
  { Read 16 32-bit big-endian words from incoming 64-byte chunk }
  for I := 0 to 15 do
  begin
    W[I] := (LongWord(Buffer[I * 4 + 0]) shl 24) or
            (LongWord(Buffer[I * 4 + 1]) shl 16) or
            (LongWord(Buffer[I * 4 + 2]) shl 8) or
             LongWord(Buffer[I * 4 + 3]);
  end;

  { Expand 16 words into 80 words }
  for I := 16 to 79 do
  begin
    W[I] := ROL(W[I - 3] xor W[I - 8] xor W[I - 14] xor W[I - 16], 1);
  end;

  A := State[0];
  B := State[1];
  C := State[2];
  D := State[3];
  E := State[4];

  { Round 1: 0..19 }
  for I := 0 to 19 do
  begin
    T := ROL(A, 5) + ((B and C) or ((not B) and D)) + E + W[I] + $5A827999;
    E := D;
    D := C;
    C := ROL(B, 30);
    B := A;
    A := T;
  end;

  { Round 2: 20..39 }
  for I := 20 to 39 do
  begin
    T := ROL(A, 5) + (B xor C xor D) + E + W[I] + $6ED9EBA1;
    E := D;
    D := C;
    C := ROL(B, 30);
    B := A;
    A := T;
  end;

  { Round 3: 40..59 }
  for I := 40 to 59 do
  begin
    T := ROL(A, 5) + ((B and C) or (B and D) or (C and D)) + E + W[I] + $8F1BBCDC;
    E := D;
    D := C;
    C := ROL(B, 30);
    B := A;
    A := T;
  end;

  { Round 4: 60..79 }
  for I := 60 to 79 do
  begin
    T := ROL(A, 5) + (B xor C xor D) + E + W[I] + $CA62C1D6;
    E := D;
    D := C;
    C := ROL(B, 30);
    B := A;
    A := T;
  end;

  Inc(State[0], A);
  Inc(State[1], B);
  Inc(State[2], C);
  Inc(State[3], D);
  Inc(State[4], E);
end;

procedure SHA1Init(var Ctx: TSHA1Context);
begin
  Ctx.State[0] := $67452301;
  Ctx.State[1] := $EFCDAB89;
  Ctx.State[2] := $98BADCFE;
  Ctx.State[3] := $10325476;
  Ctx.State[4] := $C3D2E1F0;
  Ctx.Count := 0;
  FillChar(Ctx.Buffer, SizeOf(Ctx.Buffer), 0);
end;

procedure SHA1Update(var Ctx: TSHA1Context; const Data; Len: SizeInt);
var
  BufferIndex: LongWord;
  Leftover: LongWord;
  P: PByte;
begin
  if Len <= 0 then
    Exit;

  P := PByte(@Data);
  BufferIndex := LongWord((Ctx.Count shr 3) and 63);
  Inc(Ctx.Count, QWord(Len) shl 3);

  Leftover := 64 - BufferIndex;
  if LongWord(Len) >= Leftover then
  begin
    Move(P^, Ctx.Buffer[BufferIndex], Leftover);
    SHA1Transform(Ctx.State, Ctx.Buffer);
    Inc(P, Leftover);
    Dec(Len, Leftover);
    BufferIndex := 0;

    while Len >= 64 do
    begin
      SHA1Transform(Ctx.State, PByteArray(P)^);
      Inc(P, 64);
      Dec(Len, 64);
    end;
  end;

  if Len > 0 then
    Move(P^, Ctx.Buffer[BufferIndex], Len);
end;

procedure SHA1Final(var Ctx: TSHA1Context; out Digest: TSHA1Digest);
var
  Pad: array[0..63] of Byte;
  BitLen: array[0..7] of Byte;
  TotalBits: QWord;
  PadLen: LongWord;
  BufferIndex: LongWord;
  I: Integer;
begin
  TotalBits := Ctx.Count;

  { Store bit length in big-endian order }
  for I := 0 to 7 do
    BitLen[7 - I] := Byte((TotalBits shr (I * 8)) and $FF);

  FillChar(Pad, SizeOf(Pad), 0);
  Pad[0] := $80;

  BufferIndex := LongWord((TotalBits shr 3) and 63);
  if BufferIndex < 56 then
    PadLen := 56 - BufferIndex
  else
    PadLen := 120 - BufferIndex;

  SHA1Update(Ctx, Pad, PadLen);
  SHA1Update(Ctx, BitLen, 8);

  { Write out big-endian digest words }
  for I := 0 to 4 do
  begin
    Digest[I * 4 + 0] := Byte((Ctx.State[I] shr 24) and $FF);
    Digest[I * 4 + 1] := Byte((Ctx.State[I] shr 16) and $FF);
    Digest[I * 4 + 2] := Byte((Ctx.State[I] shr 8) and $FF);
    Digest[I * 4 + 3] := Byte(Ctx.State[I] and $FF);
  end;

  { Clear context memory }
  FillChar(Ctx, SizeOf(Ctx), 0);
end;

function SHA1Buffer(const Data; Len: SizeInt): TSHA1Digest;
var
  Ctx: TSHA1Context;
begin
  SHA1Init(Ctx);
  SHA1Update(Ctx, Data, Len);
  SHA1Final(Ctx, Result);
end;

function SHA1String(const S: string): TSHA1Digest;
begin
  if Length(S) = 0 then
    Result := SHA1Buffer('', 0)
  else
    Result := SHA1Buffer(S[1], Length(S));
end;

function SHA1Stream(Stream: TStream): TSHA1Digest;
var
  Ctx: TSHA1Context;
  Buf: array[0..8191] of Byte;
  BytesRead: LongInt;
begin
  SHA1Init(Ctx);
  repeat
    BytesRead := Stream.Read(Buf, SizeOf(Buf));
    if BytesRead > 0 then
      SHA1Update(Ctx, Buf, BytesRead);
  until BytesRead <= 0;
  SHA1Final(Ctx, Result);
end;

function SHA1DigestToHex(const Digest: TSHA1Digest): string;
const
  HexChars: array[0..15] of Char = '0123456789abcdef';
var
  I: Integer;
begin
  SetLength(Result, 40);
  for I := 0 to 19 do
  begin
    Result[I * 2 + 1] := HexChars[(Digest[I] shr 4) and $0F];
    Result[I * 2 + 2] := HexChars[Digest[I] and $0F];
  end;
end;

function SHA1DigestToObjectId(const Digest: TSHA1Digest): TObjectId;
begin
  Result.Algorithm := haSHA1;
  FillChar(Result.Digest, SizeOf(Result.Digest), 0);
  Move(Digest[0], Result.Digest[0], 20);
end;

end.
