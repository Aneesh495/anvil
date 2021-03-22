{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Pure Pascal implementation of the FIPS 180-4 Secure Hash Algorithm (SHA-256).
  Produces 256-bit (32-byte) cryptographic message digests for modern Git extensions.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_sha256;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, anvil_types;

type
  { SHA-256 state context }
  TSHA256Context = record
    State: array[0..7] of LongWord;
    Count: QWord;
    Buffer: array[0..63] of Byte;
  end;
  PSHA256Context = ^TSHA256Context;

  { Raw 32-byte SHA-256 digest }
  TSHA256Digest = array[0..31] of Byte;

procedure SHA256Init(var Ctx: TSHA256Context);
procedure SHA256Update(var Ctx: TSHA256Context; const Data; Len: SizeInt);
procedure SHA256Final(var Ctx: TSHA256Context; out Digest: TSHA256Digest);

function SHA256Buffer(const Data; Len: SizeInt): TSHA256Digest;
function SHA256String(const S: string): TSHA256Digest;
function SHA256Stream(Stream: TStream): TSHA256Digest;
function SHA256DigestToHex(const Digest: TSHA256Digest): string;
function SHA256DigestToObjectId(const Digest: TSHA256Digest): TObjectId;

implementation

function ROR(X: LongWord; N: Byte): LongWord; inline;
begin
  Result := (X shr N) or (X shl (32 - N));
end;

function Ch(X, Y, Z: LongWord): LongWord; inline;
begin
  Result := (X and Y) xor ((not X) and Z);
end;

function Maj(X, Y, Z: LongWord): LongWord; inline;
begin
  Result := (X and Y) xor (X and Z) xor (Y and Z);
end;

function Sigma0(X: LongWord): LongWord; inline;
begin
  Result := ROR(X, 2) xor ROR(X, 13) xor ROR(X, 22);
end;

function Sigma1(X: LongWord): LongWord; inline;
begin
  Result := ROR(X, 6) xor ROR(X, 11) xor ROR(X, 25);
end;

function Gamma0(X: LongWord): LongWord; inline;
begin
  Result := ROR(X, 7) xor ROR(X, 18) xor (X shr 3);
end;

function Gamma1(X: LongWord): LongWord; inline;
begin
  Result := ROR(X, 17) xor ROR(X, 19) xor (X shr 10);
end;

const
  K256: array[0..63] of LongWord = (
    $428A2F98, $71374491, $B5C0FBCF, $E9B5DBA5,
    $3956C25B, $59F111F1, $923F82A4, $AB1C5ED5,
    $D807AA98, $12835B01, $243185BE, $550C7DC3,
    $72BE5D74, $80DEB1FE, $9BDC06A7, $C19BF174,
    $E49B69C1, $EFBE4786, $0FC19DC6, $240CA1CC,
    $2DE92C6F, $4A7484AA, $5CB0A9DC, $76F988DA,
    $983E5152, $A831C66D, $B00327C8, $BF597FC7,
    $C6E00BF3, $D5A79147, $06CA6351, $14292967,
    $27B70A85, $2E1B2138, $4D2C6DFC, $53380D13,
    $650A7354, $766A0ABB, $81C2C92E, $92722C85,
    $A2BFE8A1, $A81A664B, $C24B8B70, $C76C51A3,
    $D192E819, $D6990624, $F40E3585, $106AA070,
    $19A4C116, $1E376C08, $2748774C, $34B0BCB5,
    $391C0CB3, $4ED8AA4A, $5B9CCA4F, $682E6FF3,
    $748F82EE, $78A5636F, $84C87814, $8CC70208,
    $90BEFFFA, $A4506CEB, $BEF9A3F7, $C67178F2
  );

procedure SHA256Transform(var State: array of LongWord; const Buffer: array of Byte);
var
  A, B, C, D, E, F, G, H: LongWord;
  T1, T2: LongWord;
  W: array[0..63] of LongWord;
  I: Integer;
begin
  for I := 0 to 15 do
  begin
    W[I] := (LongWord(Buffer[I * 4 + 0]) shl 24) or
            (LongWord(Buffer[I * 4 + 1]) shl 16) or
            (LongWord(Buffer[I * 4 + 2]) shl 8) or
             LongWord(Buffer[I * 4 + 3]);
  end;

  for I := 16 to 63 do
  begin
    W[I] := Gamma1(W[I - 2]) + W[I - 7] + Gamma0(W[I - 15]) + W[I - 16];
  end;

  A := State[0];
  B := State[1];
  C := State[2];
  D := State[3];
  E := State[4];
  F := State[5];
  G := State[6];
  H := State[7];

  for I := 0 to 63 do
  begin
    T1 := H + Sigma1(E) + Ch(E, F, G) + K256[I] + W[I];
    T2 := Sigma0(A) + Maj(A, B, C);
    H := G;
    G := F;
    F := E;
    E := D + T1;
    D := C;
    C := B;
    B := A;
    A := T1 + T2;
  end;

  Inc(State[0], A);
  Inc(State[1], B);
  Inc(State[2], C);
  Inc(State[3], D);
  Inc(State[4], E);
  Inc(State[5], F);
  Inc(State[6], G);
  Inc(State[7], H);
end;

procedure SHA256Init(var Ctx: TSHA256Context);
begin
  Ctx.State[0] := $6A09E667;
  Ctx.State[1] := $BB67AE85;
  Ctx.State[2] := $3C6EF372;
  Ctx.State[3] := $A54FF53A;
  Ctx.State[4] := $510E527F;
  Ctx.State[5] := $9B05688C;
  Ctx.State[6] := $1F83D9AB;
  Ctx.State[7] := $5BE0CD19;
  Ctx.Count := 0;
  FillChar(Ctx.Buffer, SizeOf(Ctx.Buffer), 0);
end;

procedure SHA256Update(var Ctx: TSHA256Context; const Data; Len: SizeInt);
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
    SHA256Transform(Ctx.State, Ctx.Buffer);
    Inc(P, Leftover);
    Dec(Len, Leftover);
    BufferIndex := 0;

    while Len >= 64 do
    begin
      SHA256Transform(Ctx.State, PByteArray(P)^);
      Inc(P, 64);
      Dec(Len, 64);
    end;
  end;

  if Len > 0 then
    Move(P^, Ctx.Buffer[BufferIndex], Len);
end;

procedure SHA256Final(var Ctx: TSHA256Context; out Digest: TSHA256Digest);
var
  Pad: array[0..63] of Byte;
  BitLen: array[0..7] of Byte;
  TotalBits: QWord;
  PadLen: LongWord;
  BufferIndex: LongWord;
  I: Integer;
begin
  TotalBits := Ctx.Count;

  for I := 0 to 7 do
    BitLen[7 - I] := Byte((TotalBits shr (I * 8)) and $FF);

  FillChar(Pad, SizeOf(Pad), 0);
  Pad[0] := $80;

  BufferIndex := LongWord((TotalBits shr 3) and 63);
  if BufferIndex < 56 then
    PadLen := 56 - BufferIndex
  else
    PadLen := 120 - BufferIndex;

  SHA256Update(Ctx, Pad, PadLen);
  SHA256Update(Ctx, BitLen, 8);

  for I := 0 to 7 do
  begin
    Digest[I * 4 + 0] := Byte((Ctx.State[I] shr 24) and $FF);
    Digest[I * 4 + 1] := Byte((Ctx.State[I] shr 16) and $FF);
    Digest[I * 4 + 2] := Byte((Ctx.State[I] shr 8) and $FF);
    Digest[I * 4 + 3] := Byte(Ctx.State[I] and $FF);
  end;

  FillChar(Ctx, SizeOf(Ctx), 0);
end;

function SHA256Buffer(const Data; Len: SizeInt): TSHA256Digest;
var
  Ctx: TSHA256Context;
begin
  SHA256Init(Ctx);
  SHA256Update(Ctx, Data, Len);
  SHA256Final(Ctx, Result);
end;

function SHA256String(const S: string): TSHA256Digest;
begin
  if Length(S) = 0 then
    Result := SHA256Buffer('', 0)
  else
    Result := SHA256Buffer(S[1], Length(S));
end;

function SHA256Stream(Stream: TStream): TSHA256Digest;
var
  Ctx: TSHA256Context;
  Buf: array[0..8191] of Byte;
  BytesRead: LongInt;
begin
  SHA256Init(Ctx);
  repeat
    BytesRead := Stream.Read(Buf, SizeOf(Buf));
    if BytesRead > 0 then
      SHA256Update(Ctx, Buf, BytesRead);
  until BytesRead <= 0;
  SHA256Final(Ctx, Result);
end;

function SHA256DigestToHex(const Digest: TSHA256Digest): string;
const
  HexChars: array[0..15] of Char = '0123456789abcdef';
var
  I: Integer;
begin
  SetLength(Result, 64);
  for I := 0 to 31 do
  begin
    Result[I * 2 + 1] := HexChars[(Digest[I] shr 4) and $0F];
    Result[I * 2 + 2] := HexChars[Digest[I] and $0F];
  end;
end;

function SHA256DigestToObjectId(const Digest: TSHA256Digest): TObjectId;
begin
  Result.Algorithm := haSHA256;
  Move(Digest[0], Result.Digest[0], 32);
end;

end.
