{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Unit verification suite for reference, reflog, and commit-graph management.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit test_ref;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_ref, anvil_reflog, anvil_commitgraph, anvil_utils;

procedure RunRefTests(var PassedTests, TotalTests: Integer);

implementation

procedure AssertTrue(Cond: Boolean; const Msg: string; var PassCount, TotalCount: Integer);
begin
  Inc(TotalCount);
  if Cond then
  begin
    Inc(PassCount);
    Writeln('  [PASS] ', Msg);
  end
  else
    Writeln('  [FAIL] ', Msg);
end;

procedure AssertEquals(Expected, Actual: Integer; const Msg: string; var PassCount, TotalCount: Integer);
begin
  Inc(TotalCount);
  if Expected = Actual then
  begin
    Inc(PassCount);
    Writeln('  [PASS] ', Msg);
  end
  else
    Writeln(Format('  [FAIL] %s (Expected %d, got %d)', [Msg, Expected, Actual]));
end;

procedure AssertEqualsStr(const Expected, Actual: string; const Msg: string; var PassCount, TotalCount: Integer);
begin
  Inc(TotalCount);
  if Expected = Actual then
  begin
    Inc(PassCount);
    Writeln('  [PASS] ', Msg);
  end
  else
    Writeln(Format('  [FAIL] %s (Expected "%s", got "%s")', [Msg, Expected, Actual]));
end;

procedure RunRefTests(var PassedTests, TotalTests: Integer);
const
  InvalidNames: array[0..7] of string = (
    '', 'refs/heads/a//b', 'refs/heads/.hidden', 'refs/.hidden/a',
    'refs/heads/a.lock', 'refs/heads/a.lock/b', 'refs/heads/a.', '@');
var
  TestDir, GitDir, SavedHead, SavedPacked: string;
  Rejected: Boolean;
  RefMgr: TRefManager;
  ReflogMgr: TReflogManager;
  CommitGraph: TCommitGraph;
  ODB: TObjectDatabase;

  Id1, Id2, Id3, ResolvedId: TObjectId;
  Ref: TReference;
  RefList: TStringArray;

  Committer: TIdentity;
  Entries: TReflogEntryArray;
  RelEntry: TReflogEntry;
  PrunedCount, I: Integer;

  C1, C2, C3: TCommitObject;
  TreeObj: TTreeObject;
  TreeId: TObjectId;
  GraphEntry: TCommitGraphEntry;
  GraphFilePath: string;
  NewGraph: TCommitGraph;
  Tips: TObjectIdArray;
begin
  Writeln('=== Running Reference, Reflog, and Commit-Graph Test Suite ===');

  TestDir := JoinPaths(GetTempDir, 'anvil_ref_test_' + IntToStr(Random(1000000)));
  GitDir := JoinPaths(TestDir, '.anvil');
  EnsureDirectoryExists(GitDir);

  ODB := TObjectDatabase.Create(GitDir);
  RefMgr := TRefManager.Create(GitDir);
  ReflogMgr := TReflogManager.Create(GitDir);
  try
    for I := Low(InvalidNames) to High(InvalidNames) do
      AssertTrue(not IsValidRefName(InvalidNames[I]), 'Reject invalid reference name: ' + InvalidNames[I], PassedTests, TotalTests);
    AssertTrue(IsValidRefName('HEAD'), 'Allow the HEAD pseudoreference', PassedTests, TotalTests);
    AssertTrue(IsValidRefName('refs/heads/feature/topic'), 'Allow nested branch references', PassedTests, TotalTests);

    { Synthesize dummy IDs }
    Id1 := HexToObjectId('1111111111111111111111111111111111111111');
    Id2 := HexToObjectId('2222222222222222222222222222222222222222');
    Id3 := HexToObjectId('3333333333333333333333333333333333333333');

    { --- 1. Reference Manager Tests --- }
    RefMgr.SetReference('refs/heads/main', Id1);
    AssertTrue(FileExists(JoinPaths(GitDir, 'refs/heads/main')), 'Loose ref file created on disk', PassedTests, TotalTests);

    { A writer must neither overwrite nor remove another writer's lock. }
    WriteEntireFileString(JoinPaths(GitDir, 'refs/heads/main.lock'), 'other writer');
    Rejected := False;
    try
      RefMgr.SetReference('refs/heads/main', Id2);
    except
      on E: EReferenceLocked do Rejected := True;
    end;
    AssertTrue(Rejected, 'An existing reference lock rejects a second writer', PassedTests, TotalTests);
    AssertTrue(FileExists(JoinPaths(GitDir, 'refs/heads/main.lock')), 'An existing lock survives rejection', PassedTests, TotalTests);
    if FileExists(JoinPaths(GitDir, 'refs/heads/main.lock')) then
      AssertEqualsStr('other writer', ReadEntireFileString(JoinPaths(GitDir, 'refs/heads/main.lock')), 'Another writer lock content stays unchanged', PassedTests, TotalTests);
    AssertTrue(RefMgr.Resolve('refs/heads/main', ResolvedId) and ObjectIdEqual(Id1, ResolvedId), 'Rejected lock acquisition leaves the reference unchanged', PassedTests, TotalTests);
    DeleteFile(JoinPaths(GitDir, 'refs/heads/main.lock'));
    RefMgr.SetReference('refs/heads/main', Id1);

    Ref := RefMgr.GetReference('refs/heads/main');
    AssertTrue(Assigned(Ref), 'GetReference returns valid reference object', PassedTests, TotalTests);
    AssertTrue(Ref.RefType = rtDirect, 'Reference is rtDirect', PassedTests, TotalTests);
    AssertTrue(ObjectIdEqual(Id1, Ref.TargetId), 'Direct reference target matches Id1', PassedTests, TotalTests);
    Ref.Free;

    { Set symbolic HEAD }
    RefMgr.SetSymbolicReference('HEAD', 'refs/heads/main');
    Ref := RefMgr.GetReference('HEAD');
    AssertTrue(Assigned(Ref), 'GetReference HEAD returns symbolic reference', PassedTests, TotalTests);
    AssertTrue(Ref.RefType = rtSymbolic, 'HEAD is rtSymbolic', PassedTests, TotalTests);
    AssertEqualsStr('refs/heads/main', Ref.SymbolicTarget, 'HEAD symbolic target is refs/heads/main', PassedTests, TotalTests);
    Ref.Free;

    { Resolve HEAD -> resolves to Id1 }
    AssertTrue(RefMgr.Resolve('HEAD', ResolvedId), 'Resolve HEAD succeeds through symbolic chain', PassedTests, TotalTests);
    AssertTrue(ObjectIdEqual(Id1, ResolvedId), 'HEAD resolves to Id1', PassedTests, TotalTests);

    { Reference names must never address metadata outside the repository. }
    WriteEntireFileString(JoinPaths(TestDir, 'outside'), ObjectIdToHex(Id1) + #10);
    Ref := RefMgr.GetReference('../outside');
    AssertTrue(not Assigned(Ref), 'Reject an outside reference read', PassedTests, TotalTests);
    Ref.Free;
    AssertTrue(not RefMgr.DeleteReference('../outside'), 'Reject an outside reference deletion', PassedTests, TotalTests);
    AssertTrue(FileExists(JoinPaths(TestDir, 'outside')), 'Rejected reference deletion preserves the outside file', PassedTests, TotalTests);

    SavedHead := ReadEntireFileString(JoinPaths(GitDir, 'HEAD'));
    Rejected := False;
    try
      RefMgr.SetSymbolicReference('HEAD', '../outside');
    except
      on E: EInvalidReference do Rejected := True;
    end;
    AssertTrue(Rejected, 'Reject an invalid symbolic-reference target', PassedTests, TotalTests);
    AssertEqualsStr(SavedHead, ReadEntireFileString(JoinPaths(GitDir, 'HEAD')), 'Rejected symbolic target leaves HEAD unchanged', PassedTests, TotalTests);
    RefMgr.SetSymbolicReference('HEAD', 'refs/heads/main');

    { Create tags and branches }
    RefMgr.SetReference('refs/heads/feature', Id2);
    RefMgr.SetReference('refs/tags/v1.0.0', Id1);

    { An in-progress transaction is not another branch. }
    WriteEntireFileString(JoinPaths(GitDir, 'refs/heads/main.lock'), ObjectIdToHex(Id3) + #10);
    RefList := RefMgr.ListReferences('refs/heads/');
    AssertEquals(2, Length(RefList), 'ListReferences finds 2 branches', PassedTests, TotalTests);
    DeleteFile(JoinPaths(GitDir, 'refs/heads/main.lock'));

    { Pack references }
    RefMgr.PackReferences;
    AssertTrue(FileExists(JoinPaths(GitDir, 'packed-refs')), 'packed-refs file generated', PassedTests, TotalTests);

    SavedPacked := ReadEntireFileString(JoinPaths(GitDir, 'packed-refs'));
    WriteEntireFileString(JoinPaths(GitDir, 'packed-refs.lock'), 'other writer');
    Rejected := False;
    try
      RefMgr.PackReferences;
    except
      on E: EReferenceLocked do Rejected := True;
    end;
    AssertTrue(Rejected, 'Packing reports a failed packed-refs lock acquisition', PassedTests, TotalTests);
    AssertEqualsStr(SavedPacked, ReadEntireFileString(JoinPaths(GitDir, 'packed-refs')), 'A failed pack preserves the previous packed refs', PassedTests, TotalTests);
    AssertEqualsStr('other writer', ReadEntireFileString(JoinPaths(GitDir, 'packed-refs.lock')), 'A failed pack preserves the other writer lock', PassedTests, TotalTests);
    DeleteFile(JoinPaths(GitDir, 'packed-refs.lock'));

    { Delete loose ref to verify packed-refs fallback resolution }
    DeleteFile(JoinPaths(GitDir, 'refs/tags/v1.0.0'));
    AssertTrue(RefMgr.Resolve('refs/tags/v1.0.0', ResolvedId), 'Resolves tag from packed-refs after loose deletion', PassedTests, TotalTests);
    AssertTrue(ObjectIdEqual(Id1, ResolvedId), 'Packed tag resolves to Id1', PassedTests, TotalTests);

    { A deleted packed branch must remain deleted after reopening the repository. }
    WriteEntireFileString(JoinPaths(GitDir, 'packed-refs'),
      ReadEntireFileString(JoinPaths(GitDir, 'packed-refs')) + '^' + ObjectIdToHex(Id3) + #10);
    AssertTrue(RefMgr.DeleteReference('refs/heads/feature'), 'Delete a packed branch', PassedTests, TotalTests);
    RefMgr.Free;
    RefMgr := TRefManager.Create(GitDir);
    AssertTrue(not RefMgr.Resolve('refs/heads/feature', ResolvedId), 'Deleted packed branch stays absent after reopening', PassedTests, TotalTests);
    AssertTrue(RefMgr.Resolve('refs/tags/v1.0.0', ResolvedId), 'Deleting a packed branch preserves other packed refs', PassedTests, TotalTests);
    Ref := RefMgr.GetReference('refs/tags/v1.0.0');
    try
      AssertTrue(Assigned(Ref) and Ref.HasPeeled, 'Deleting another ref preserves a packed tag peeled record', PassedTests, TotalTests);
    finally
      Ref.Free;
    end;
    AssertTrue(RefMgr.DeleteReference('refs/tags/v1.0.0'), 'Delete a packed-only tag', PassedTests, TotalTests);
    RefMgr.Free;
    RefMgr := TRefManager.Create(GitDir);
    AssertTrue(not RefMgr.Resolve('refs/tags/v1.0.0', ResolvedId), 'Deleted packed-only tag stays absent after reopening', PassedTests, TotalTests);
    AssertTrue(Pos('^' + ObjectIdToHex(Id3), ReadEntireFileString(JoinPaths(GitDir, 'packed-refs'))) = 0, 'Deleting an annotated tag removes its peeled record', PassedTests, TotalTests);

    { --- 2. Reflog Manager Tests --- }
    Committer.Name := 'Test Author';
    Committer.Email := 'author@test.local';
    Committer.When.Seconds := 1700000000;
    Committer.When.OffsetMinutes := 0;

    ReflogMgr.Append('refs/heads/main', NullObjectId, Id1, Committer, 'commit (initial): first commit');

    Committer.When.Seconds := 1700001000;
    ReflogMgr.Append('refs/heads/main', Id1, Id2, Committer, 'commit: second feature');

    Entries := ReflogMgr.ReadEntries('refs/heads/main');
    AssertEquals(2, Length(Entries), 'Reflog has 2 chronological entries', PassedTests, TotalTests);
    AssertEqualsStr('commit: second feature', Entries[1].Message, 'Second entry message verified', PassedTests, TotalTests);

    { Relative syntax }
    AssertTrue(ReflogMgr.ReadRelative('refs/heads/main', 0, RelEntry), 'Read relative 0 (HEAD@{0}) succeeds', PassedTests, TotalTests);
    AssertTrue(ObjectIdEqual(Id2, RelEntry.NewId), 'Relative 0 has current tip Id2', PassedTests, TotalTests);

    AssertTrue(ReflogMgr.ReadRelative('refs/heads/main', 1, RelEntry), 'Read relative 1 (HEAD@{1}) succeeds', PassedTests, TotalTests);
    AssertTrue(ObjectIdEqual(Id1, RelEntry.NewId), 'Relative 1 has previous tip Id1', PassedTests, TotalTests);

    { Expiration / pruning }
    PrunedCount := ReflogMgr.Expire('refs/heads/main', 1700000500);
    AssertEquals(1, PrunedCount, 'Reflog pruned 1 entry older than threshold', PassedTests, TotalTests);
    Entries := ReflogMgr.ReadEntries('refs/heads/main');
    AssertEquals(1, Length(Entries), 'Reflog now has 1 remaining entry', PassedTests, TotalTests);

    { --- 3. Commit Graph Tests --- }
    TreeObj := TTreeObject.Create;
    TreeId := TreeObj.ObjectId;
    ODB.WriteObject(TreeObj);
    TreeObj.Free;

    { Create 3 commits in ODB }
    C1 := TCommitObject.Create;
    C1.TreeId := TreeId;
    C1.Author := Committer;
    C1.Message := 'C1';
    Id1 := C1.ObjectId;
    ODB.WriteObject(C1);
    C1.Free;

    C2 := TCommitObject.Create;
    C2.TreeId := TreeId;
    C2.AddParent(Id1);
    C2.Author := Committer;
    C2.Message := 'C2';
    Id2 := C2.ObjectId;
    ODB.WriteObject(C2);
    C2.Free;

    C3 := TCommitObject.Create;
    C3.TreeId := TreeId;
    C3.AddParent(Id2);
    C3.Author := Committer;
    C3.Message := 'C3';
    Id3 := C3.ObjectId;
    ODB.WriteObject(C3);
    C3.Free;

    GraphFilePath := JoinPaths(GitDir, 'objects/info/commit-graph');
    CommitGraph := TCommitGraph.Create(GraphFilePath);
    try
      SetLength(Tips, 1);
      Tips[0] := Id3;
      CommitGraph.BuildFromODB(ODB, Tips);
      AssertTrue(FileExists(GraphFilePath), 'Binary commit-graph file written to objects/info/commit-graph', PassedTests, TotalTests);
      AssertEquals(3, CommitGraph.Count, 'Commit graph contains 3 commits', PassedTests, TotalTests);
    finally
      CommitGraph.Free;
    end;

    { Reload graph from file in fresh instance }
    NewGraph := TCommitGraph.Create(GraphFilePath);
    try
      AssertTrue(NewGraph.Load, 'Binary commit-graph loads cleanly from disk', PassedTests, TotalTests);
      AssertEquals(3, NewGraph.Count, 'Loaded graph contains exactly 3 commits', PassedTests, TotalTests);

      AssertTrue(NewGraph.FindCommit(Id2, GraphEntry), 'FindCommit locates C2 in O(log N) fanout binary search', PassedTests, TotalTests);
      AssertTrue(ObjectIdEqual(TreeId, GraphEntry.TreeId), 'C2 tree ID matches TreeId', PassedTests, TotalTests);
      AssertEquals(1, Length(GraphEntry.ParentIds), 'C2 has 1 parent in graph', PassedTests, TotalTests);
      AssertTrue(ObjectIdEqual(Id1, GraphEntry.ParentIds[0]), 'C2 parent ID is C1', PassedTests, TotalTests);
    finally
      NewGraph.Free;
    end;

  finally
    ReflogMgr.Free;
    RefMgr.Free;
    ODB.Free;
    DeleteDirectoryRecursive(TestDir);
  end;
end;

end.
