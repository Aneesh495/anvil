{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Unit tests for the Object Database (ODB) subsystem:
  loose object read/write, tree serialization, commit parsing,
  packfile v2 delta compression, and index v2 fanout lookup.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit test_odb;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, anvil_types, anvil_errors, anvil_utils,
  anvil_hash, anvil_object, anvil_loose, anvil_pack_index, anvil_pack,
  anvil_pack_writer, anvil_odb;

procedure RunOdbTests(var PassedTests, TotalTests: Integer);

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

procedure RunOdbTests(var PassedTests, TotalTests: Integer);
var
  TestDir, ObjectsDir, PackDir: string;
  Blob: TBlobObject;
  Tree: TTreeObject;
  Commit: TCommitObject;
  Id1, Id2, TreeId, CommitId: TObjectId;
  Loose: TLooseBackend;
  ReadObj: TAnvilObject;
  ReadCommit: TCommitObject;
  ReadTree: TTreeObject;
  Entry: TTreeEntry;
  Odb: TObjectDatabase;
  PackWriter: TPackWriter;
  OutPack, OutIdx: string;
  PackChecksum: TObjectId;
  Packfile: TPackfile;
  PackReadType: TObjectType;
  PackReadData: TByteArray;
begin
  Writeln('=== Running Object Database (ODB) Test Suite ===');

  TestDir := JoinPaths(ExtractFilePath(ParamStr(0)), 'tmp_odb_test');
  ObjectsDir := JoinPaths(TestDir, 'objects');
  if DirectoryExists(TestDir) then
    DeleteDirectoryRecursive(TestDir);
  ForceDirectories(ObjectsDir);

  try
    { Test 1: Blob Object Lifecycle }
    Blob := TBlobObject.CreateWithString('hello world'#10);
    try
      Id1 := Blob.ComputeId(haSHA1);
      AssertEquals('3b18e512dba79e4c8300dd08aeb37f8e728b8dad', ObjectIdToHex(Id1),
        'Blob calculates correct Git SHA-1 hash for "hello world\n"', PassedTests, TotalTests);
    finally
      Blob.Free;
    end;

    { Test 2: Loose Object Storage Write and Read }
    Loose := TLooseBackend.Create(ObjectsDir, haSHA1);
    try
      Blob := TBlobObject.CreateWithString('hello world'#10);
      try
        Id1 := Loose.WriteObject(Blob);
        AssertTrue(Loose.Exists(Id1), 'Loose object file exists after write', PassedTests, TotalTests);

        ReadObj := Loose.ReadObject(Id1);
        try
          AssertTrue(ReadObj is TBlobObject, 'Loose read returns correct TBlobObject type', PassedTests, TotalTests);
          AssertEquals('hello world'#10, TBlobObject(ReadObj).AsString,
            'Loose read reconstitutes exact blob payload', PassedTests, TotalTests);
        finally
          ReadObj.Free;
        end;
      finally
        Blob.Free;
      end;

      { Test 3: Tree Object Serialization & Deserialization }
      Tree := TTreeObject.Create;
      try
        Id2 := HexToObjectId('2fd4e1c67a2d28fced849ee1bb76e7391b93eb12');
        Tree.AddEntry(fmRegular, 'main.pas', Id1);
        Tree.AddEntry(fmExecutable, 'build.sh', Id2);
        Tree.AddEntry(fmDirectory, 'src', Id2);

        TreeId := Loose.WriteObject(Tree);
        AssertTrue(not IsNullObjectId(TreeId), 'Tree object successfully serialized and hashed', PassedTests, TotalTests);

        ReadObj := Loose.ReadObject(TreeId);
        try
          AssertTrue(ReadObj is TTreeObject, 'Loose read returns TTreeObject type', PassedTests, TotalTests);
          ReadTree := TTreeObject(ReadObj);
          AssertTrue(ReadTree.Count = 3, 'Reconstituted tree contains exactly 3 entries', PassedTests, TotalTests);

          AssertTrue(ReadTree.FindEntry('main.pas', Entry), 'Found main.pas entry in tree', PassedTests, TotalTests);
          AssertTrue(Entry.Mode = fmRegular, 'main.pas has fmRegular file mode', PassedTests, TotalTests);
          AssertTrue(ObjectIdEqual(Entry.Id, Id1), 'main.pas points to correct blob Id1', PassedTests, TotalTests);

          AssertTrue(ReadTree.FindEntry('src', Entry), 'Found src entry in tree', PassedTests, TotalTests);
          AssertTrue(Entry.Mode = fmDirectory, 'src has fmDirectory mode', PassedTests, TotalTests);
        finally
          ReadObj.Free;
        end;
      finally
        Tree.Free;
      end;

      { Test 4: Commit Object Serialization, Parsing, and Roundtrip }
      Commit := TCommitObject.Create;
      try
        Commit.TreeId := TreeId;
        Commit.AddParent(Id1);
        Commit.Author := MakeIdentity('Aneesh Krishna', 'aneesh@example.com', 1700000000, -300);
        Commit.Committer := MakeIdentity('Aneesh Krishna', 'aneesh@example.com', 1700000000, -300);
        Commit.Message := 'feat: initial commit from anvil engine'#10;

        CommitId := Loose.WriteObject(Commit);
        AssertTrue(not IsNullObjectId(CommitId), 'Commit object serialized and hashed', PassedTests, TotalTests);

        ReadObj := Loose.ReadObject(CommitId);
        try
          AssertTrue(ReadObj is TCommitObject, 'Loose read returns TCommitObject', PassedTests, TotalTests);
          ReadCommit := TCommitObject(ReadObj);
          AssertTrue(ObjectIdEqual(ReadCommit.TreeId, TreeId), 'Commit tree points to correct tree', PassedTests, TotalTests);
          AssertTrue(Length(ReadCommit.ParentIds) = 1, 'Commit has 1 parent', PassedTests, TotalTests);
          AssertTrue(ObjectIdEqual(ReadCommit.ParentIds[0], Id1), 'Commit parent matches Id1', PassedTests, TotalTests);
          AssertEquals('Aneesh Krishna', ReadCommit.Author.Name, 'Commit author name parsed correctly', PassedTests, TotalTests);
          AssertEquals('aneesh@example.com', ReadCommit.Author.Email, 'Commit author email parsed correctly', PassedTests, TotalTests);
          AssertTrue(ReadCommit.Author.When.Seconds = 1700000000, 'Commit author timestamp preserved', PassedTests, TotalTests);
          AssertTrue(ReadCommit.Author.When.OffsetMinutes = -300, 'Commit author timezone preserved', PassedTests, TotalTests);
          AssertEquals('feat: initial commit from anvil engine'#10, ReadCommit.Message,
            'Commit message roundtripped cleanly', PassedTests, TotalTests);
        finally
          ReadObj.Free;
        end;
      finally
        Commit.Free;
      end;

    finally
      Loose.Free;
    end;

    { Test 5: Packfile Writer with Delta Compression and Index v2 Reader }
    PackDir := JoinPaths(ObjectsDir, 'pack');
    ForceDirectories(PackDir);
    PackWriter := TPackWriter.Create(10, 50);
    try
      { Base version of a source file }
      Blob := TBlobObject.CreateWithString('function ComputeSum(A, B: Integer): Integer;'#10'begin'#10'  Result := A + B;'#10'end;'#10);
      Id1 := Blob.ComputeId(haSHA1);
      PackWriter.AddObject(Id1, otBlob, @Blob.Data[0], Length(Blob.Data));
      Blob.Free;

      { Modified version with minor addition (ideal for delta compression) }
      Blob := TBlobObject.CreateWithString('function ComputeSum(A, B: Integer): Integer;'#10'begin'#10'  // Added comment'#10'  Result := A + B;'#10'end;'#10);
      Id2 := Blob.ComputeId(haSHA1);
      PackWriter.AddObject(Id2, otBlob, @Blob.Data[0], Length(Blob.Data));
      Blob.Free;

      PackWriter.WritePack(JoinPaths(PackDir, 'testpack'), OutPack, OutIdx, PackChecksum);

      AssertTrue(FileExists(OutPack), 'Packfile .pack generated on disk', PassedTests, TotalTests);
      AssertTrue(FileExists(OutIdx), 'Pack index .idx generated on disk', PassedTests, TotalTests);

      { Open and verify packfile }
      Packfile := TPackfile.Create(OutPack, OutIdx);
      try
        AssertTrue(Packfile.ObjectCount = 2, 'Packfile contains 2 objects', PassedTests, TotalTests);
        AssertTrue(Packfile.ContainsObject(Id1), 'Packfile index contains Id1', PassedTests, TotalTests);
        AssertTrue(Packfile.ContainsObject(Id2), 'Packfile index contains Id2', PassedTests, TotalTests);

        { Read back Id1 }
        AssertTrue(Packfile.ReadObject(Id1, PackReadType, PackReadData), 'Read base object Id1 from pack', PassedTests, TotalTests);
        AssertTrue(PackReadType = otBlob, 'Base object is otBlob', PassedTests, TotalTests);

        { Read back delta-compressed Id2 }
        AssertTrue(Packfile.ReadObject(Id2, PackReadType, PackReadData), 'Read delta object Id2 from pack', PassedTests, TotalTests);
        AssertTrue(PackReadType = otBlob, 'Delta object is otBlob', PassedTests, TotalTests);
        AssertTrue(Pos('// Added comment', PChar(@PackReadData[0])) > 0,
          'Delta decompression correctly recovered added line', PassedTests, TotalTests);

      finally
        Packfile.Free;
      end;

    finally
      PackWriter.Free;
    end;

    { Test 6: Unified TObjectDatabase Integration }
    Odb := TObjectDatabase.Create(ObjectsDir, haSHA1);
    try
      AssertTrue(Odb.Exists(Id1), 'ODB locates object across loose and pack storage', PassedTests, TotalTests);
      AssertTrue(Odb.Exists(Id2), 'ODB locates delta object from pack storage', PassedTests, TotalTests);
      AssertTrue(Odb.Exists(CommitId), 'ODB locates commit object from loose storage', PassedTests, TotalTests);

      ReadObj := Odb.ReadObject(Id1);
      try
        AssertTrue(ReadObj is TBlobObject, 'ODB returns cached/read TBlobObject', PassedTests, TotalTests);
      finally
        ReadObj.Free;
      end;
    finally
      Odb.Free;
    end;

  finally
    if DirectoryExists(TestDir) then
      DeleteDirectoryRecursive(TestDir);
  end;
end;

end.
