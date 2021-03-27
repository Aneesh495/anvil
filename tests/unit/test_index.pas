{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Unit tests for the Index and Staging subsystem:
  binary index file serialization, entry padding, stage conflict handling,
  tree synthesis (write-tree), and tree expansion (read-tree).
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit test_index;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, anvil_types, anvil_errors, anvil_utils,
  anvil_hash, anvil_object, anvil_odb, anvil_index_entry, anvil_index;

procedure RunIndexTests(var PassedTests, TotalTests: Integer);

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

procedure RunIndexTests(var PassedTests, TotalTests: Integer);
var
  TestDir, ObjectsDir, IndexPath: string;
  Idx: TIndex;
  Id1, Id2, Id3, RootTreeId: TObjectId;
  Entry: TIndexEntry;
  Odb: TObjectDatabase;
  TreeObj: TTreeObject;
  TreeEntry: TTreeEntry;
begin
  Writeln('=== Running Staging Area (Index) Test Suite ===');

  TestDir := JoinPaths(ExtractFilePath(ParamStr(0)), 'tmp_index_test');
  ObjectsDir := JoinPaths(TestDir, 'objects');
  IndexPath := JoinPaths(TestDir, 'index');
  if DirectoryExists(TestDir) then
    DeleteDirectoryRecursive(TestDir);
  ForceDirectories(ObjectsDir);

  try
    Id1 := HexToObjectId('3b18e512dba79e4c8300dd08aeb37f8e728b8dad');
    Id2 := HexToObjectId('2fd4e1c67a2d28fced849ee1bb76e7391b93eb12');
    Id3 := HexToObjectId('da39a3ee5e6b4b0d3255bfef95601890afd80709');

    { Test 1: Staging file additions and automatic path sorting }
    Idx := TIndex.Create(IndexPath, haSHA1);
    try
      Idx.AddFile('src/engine.pas', Id1, fmRegular, 1024, 0);
      Idx.AddFile('README.md', Id2, fmRegular, 256, 0);
      Idx.AddFile('src/common/types.pas', Id3, fmRegular, 512, 0);

      AssertTrue(Idx.Count = 3, 'Index contains 3 staged entries', PassedTests, TotalTests);
      AssertEquals('README.md', Idx.GetEntry(0).Path, 'Entries are sorted: 0 is README.md', PassedTests, TotalTests);
      AssertEquals('src/common/types.pas', Idx.GetEntry(1).Path, 'Entries are sorted: 1 is src/common/types.pas', PassedTests, TotalTests);
      AssertEquals('src/engine.pas', Idx.GetEntry(2).Path, 'Entries are sorted: 2 is src/engine.pas', PassedTests, TotalTests);

      { Test 2: Binary Index Serialization and Roundtrip }
      Idx.WriteToFile;
      AssertTrue(FileExists(IndexPath), 'Binary index file written to disk', PassedTests, TotalTests);

      { Reload from disk in a fresh instance }
      Idx.Clear;
      AssertTrue(Idx.Count = 0, 'Index cleared in memory', PassedTests, TotalTests);
      Idx.LoadFromFile(IndexPath);
      AssertTrue(Idx.Count = 3, 'Reloaded index contains all 3 entries', PassedTests, TotalTests);
      AssertTrue(Idx.Find('src/engine.pas', 0, Entry), 'Found staged src/engine.pas after reload', PassedTests, TotalTests);
      AssertTrue(ObjectIdEqual(Entry.Id, Id1), 'Staged entry preserved exact ObjectId', PassedTests, TotalTests);

      { Test 3: Conflict Stages (Stages 1, 2, 3) }
      AssertTrue(not Idx.HasConflicts, 'Index initially has no merge conflicts', PassedTests, TotalTests);
      Idx.AddFile('conflict.txt', Id1, fmRegular, 100, 1); { Ancestor }
      Idx.AddFile('conflict.txt', Id2, fmRegular, 105, 2); { Ours }
      Idx.AddFile('conflict.txt', Id3, fmRegular, 110, 3); { Theirs }

      AssertTrue(Idx.HasConflicts, 'Index correctly reports unmerged conflicts', PassedTests, TotalTests);
      AssertTrue(Idx.Find('conflict.txt', 1, Entry), 'Found conflict stage 1 (ancestor)', PassedTests, TotalTests);
      AssertTrue(Idx.Find('conflict.txt', 2, Entry), 'Found conflict stage 2 (ours)', PassedTests, TotalTests);
      AssertTrue(Idx.Find('conflict.txt', 3, Entry), 'Found conflict stage 3 (theirs)', PassedTests, TotalTests);

      { Resolve conflict by staging resolution at stage 0 }
      Idx.RemoveAllStages('conflict.txt');
      Idx.AddFile('conflict.txt', Id1, fmRegular, 102, 0);
      AssertTrue(not Idx.HasConflicts, 'Index reports zero conflicts after resolution', PassedTests, TotalTests);

      { Test 4: WriteTree Synthesis into ODB }
      Odb := TObjectDatabase.Create(ObjectsDir, haSHA1);
      try
        { Store underlying blob objects in ODB so write-tree forms a valid repository }
        Odb.WriteObjectRaw(otBlob, PChar('readme content'), 14);
        Odb.WriteObjectRaw(otBlob, PChar('types content'), 13);
        Odb.WriteObjectRaw(otBlob, PChar('engine content'), 14);
        Odb.WriteObjectRaw(otBlob, PChar('conflict content'), 16);

        RootTreeId := Idx.WriteTree(Odb);
        AssertTrue(not IsNullObjectId(RootTreeId), 'write-tree synthesized valid root tree', PassedTests, TotalTests);
        AssertTrue(Odb.Exists(RootTreeId), 'Root tree persisted into ODB', PassedTests, TotalTests);

        { Inspect root tree structure }
        TreeObj := TTreeObject(Odb.ReadObject(RootTreeId));
        try
          AssertTrue(TreeObj.FindEntry('README.md', TreeEntry), 'Root tree contains README.md', PassedTests, TotalTests);
          AssertTrue(TreeEntry.Mode = fmRegular, 'README.md is regular file', PassedTests, TotalTests);
          AssertTrue(TreeObj.FindEntry('src', TreeEntry), 'Root tree contains src directory', PassedTests, TotalTests);
          AssertTrue(TreeEntry.Mode = fmDirectory, 'src is directory mode in tree', PassedTests, TotalTests);
        finally
          TreeObj.Free;
        end;

        { Test 5: ReadTree Expansion from ODB }
        Idx.Clear;
        AssertTrue(Idx.Count = 0, 'Index cleared before read-tree', PassedTests, TotalTests);
        Idx.ReadTree(Odb, RootTreeId);
        AssertTrue(Idx.Count = 4, 'read-tree populated all 4 leaf entries recursively', PassedTests, TotalTests);
        AssertTrue(Idx.Find('src/common/types.pas', 0, Entry), 'Expanded nested entry src/common/types.pas', PassedTests, TotalTests);

      finally
        Odb.Free;
      end;

    finally
      Idx.Free;
    end;

  finally
    if DirectoryExists(TestDir) then
      DeleteDirectoryRecursive(TestDir);
  end;
end;

end.
