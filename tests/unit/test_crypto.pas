{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Unit tests for cryptographic primitives: SHA-1, SHA-256, and CRC-32.
  Validates against official NIST / FIPS test vectors.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit test_crypto;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, anvil_types, anvil_sha1, anvil_sha256, anvil_crc32, anvil_hash;

procedure RunCryptoTests(var PassedTests, TotalTests: Integer);

implementation

procedure AssertTrue(Condition: Boolean; const TestName: string; var PassedTests, TotalTests: Integer);
begin
  Inc(TotalTests);
  if Condition then
  begin
    Inc(PassedTests);
    Writeln('  [PASS] ', TestName);
  end
  else
  begin
    Writeln('  [FAIL] ', TestName);
  end;
end;

procedure AssertEquals(const Expected, Actual, TestName: string; var PassedTests, TotalTests: Integer);
begin
  Inc(TotalTests);
  if Expected = Actual then
  begin
    Inc(PassedTests);
    Writeln('  [PASS] ', TestName);
  end
  else
  begin
    Writeln('  [FAIL] ', TestName, ' - Expected: "', Expected, '", Got: "', Actual, '"');
  end;
end;

procedure RunCryptoTests(var PassedTests, TotalTests: Integer);
var
  Digest1: TSHA1Digest;
  Digest256: TSHA256Digest;
  Hex: string;
  CrcVal: LongWord;
  SetObj: TObjectIdSet;
  MapObj: TObjectIdMap;
  Id1, Id2, Id3: TObjectId;
  DummyVal: Pointer;
begin
  Writeln('=== Running Cryptographic Test Suite ===');

  { Test 1: SHA-1 Empty String }
  Digest1 := SHA1String('');
  Hex := SHA1DigestToHex(Digest1);
  AssertEquals('da39a3ee5e6b4b0d3255bfef95601890afd80709', Hex,
    'SHA-1 empty string digest matches NIST vector', PassedTests, TotalTests);

  { Test 2: SHA-1 Quick Brown Fox }
  Digest1 := SHA1String('The quick brown fox jumps over the lazy dog');
  Hex := SHA1DigestToHex(Digest1);
  AssertEquals('2fd4e1c67a2d28fced849ee1bb76e7391b93eb12', Hex,
    'SHA-1 quick brown fox matches reference vector', PassedTests, TotalTests);

  { Test 3: SHA-256 Empty String }
  Digest256 := SHA256String('');
  Hex := SHA256DigestToHex(Digest256);
  AssertEquals('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', Hex,
    'SHA-256 empty string matches FIPS 180-4 vector', PassedTests, TotalTests);

  { Test 4: SHA-256 Quick Brown Fox }
  Digest256 := SHA256String('The quick brown fox jumps over the lazy dog');
  Hex := SHA256DigestToHex(Digest256);
  AssertEquals('d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592', Hex,
    'SHA-256 quick brown fox matches reference vector', PassedTests, TotalTests);

  { Test 5: CRC-32 IEEE 802.3 Checksum }
  CrcVal := CRC32String('123456789');
  AssertEquals('$CBF43926', '$' + IntToHex(CrcVal, 8),
    'CRC32 IEEE standard polynomial check on "123456789"', PassedTests, TotalTests);

  { Test 6: CRC-32C Castagnoli Checksum }
  CrcVal := CRC32CBuffer(Pointer(PChar('123456789'))^, 9);
  AssertEquals('$E3069283', '$' + IntToHex(CrcVal, 8),
    'CRC32C Castagnoli polynomial check on "123456789"', PassedTests, TotalTests);

  { Test 7: Git Object Header Hashing }
  { A blob containing "hello world\n" should match Git standard: blob 12\0hello world\n }
  Id1 := HashGitObject(otBlob, PChar('hello world'#10), 12, haSHA1);
  Hex := ObjectIdToHex(Id1);
  AssertEquals('3b18e512dba79e4c8300dd08aeb37f8e728b8dad', Hex,
    'Git blob "hello world\n" hashes to canonical Git blob object id', PassedTests, TotalTests);

  { Test 8: TObjectIdSet Add, Contains, Remove }
  SetObj := TObjectIdSet.Create(32);
  try
    Id1 := HexToObjectId('3b18e512dba79e4c8300dd08aeb37f8e728b8dad');
    Id2 := HexToObjectId('2fd4e1c67a2d28fced849ee1bb76e7391b93eb12');
    Id3 := HexToObjectId('da39a3ee5e6b4b0d3255bfef95601890afd80709');

    AssertTrue(SetObj.Add(Id1), 'Set adds Id1 successfully', PassedTests, TotalTests);
    AssertTrue(SetObj.Add(Id2), 'Set adds Id2 successfully', PassedTests, TotalTests);
    AssertTrue(not SetObj.Add(Id1), 'Set correctly detects duplicate Id1', PassedTests, TotalTests);
    AssertTrue(SetObj.Contains(Id1), 'Set contains Id1', PassedTests, TotalTests);
    AssertTrue(SetObj.Contains(Id2), 'Set contains Id2', PassedTests, TotalTests);
    AssertTrue(not SetObj.Contains(Id3), 'Set does not contain unadded Id3', PassedTests, TotalTests);

    AssertTrue(SetObj.Remove(Id1), 'Set removes Id1 successfully', PassedTests, TotalTests);
    AssertTrue(not SetObj.Contains(Id1), 'Set no longer contains removed Id1', PassedTests, TotalTests);
  finally
    SetObj.Free;
  end;

  { Test 9: TObjectIdMap Put and Find }
  MapObj := TObjectIdMap.Create(32);
  try
    DummyVal := Pointer(PtrUInt($1337));
    MapObj.Put(Id2, DummyVal);
    AssertTrue(MapObj.Find(Id2, DummyVal) and (PtrUInt(DummyVal) = $1337),
      'Map correctly retrieves associated pointer value', PassedTests, TotalTests);
  finally
    MapObj.Free;
  end;
end;

end.
