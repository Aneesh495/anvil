{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Unit verification suite for merge, LCA, 3-way reconciliation, and rebase.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit test_merge;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_index, anvil_index_entry, anvil_lca, anvil_merge3, anvil_merge_tree,
  anvil_rebase, anvil_utils;

procedure RunMergeTests(var PassedTests, TotalTests: Integer);

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

procedure RunMergeTests(var PassedTests, TotalTests: Integer);
var
  TestDir: string;
  ODB: TObjectDatabase;
  Index: TIndex;
  M3Res: TMerge3Result;
  BaseStr, OursStr, TheirsStr: string;

  { LCA and DAG objects }
  C1, C2, C3, C4, C5: TCommitObject;
  Id1, Id2, Id3, Id4, Id5: TObjectId;
  Tree1: TTreeObject;
  TreeId1: TObjectId;
  LcaFinder: TLcaFinder;
  Bases: TObjectIdArray;
  BestBaseId: TObjectId;

  { Tree merge objects }
  BlobA, BlobB1, BlobB2, BlobC, BlobD_Base, BlobD_Ours, BlobD_Theirs: TBlobObject;
  TreeBase, TreeOurs, TreeTheirs: TTreeObject;
  TBaseId, TOursId, TTheirsId: TObjectId;
  MergeSum: TMergeTreeSummary;

  { Rebase objects }
  Committer: TIdentity;
  RebaseEng: TRebaseEngine;
  CpRes: TCherryPickResult;
  RebaseRes: TRebaseResult;
  RebasedCommit: TCommitObject;
  Obj: TAnvilObject;
begin
  Writeln('=== Running Merge and Reconciliation Test Suite ===');

  { --- 1. Three-Way Merge3 Tests --- }
  BaseStr := 'line1'#10'line2'#10'line3';
  OursStr := 'line1'#10'line2-ours'#10'line3';
  TheirsStr := 'line1'#10'line2'#10'line3-theirs';

  M3Res := Merge3Strings(BaseStr, OursStr, TheirsStr);
  AssertTrue(not M3Res.HasConflict, 'Clean 3-way merge with non-overlapping edits succeeds', PassedTests, TotalTests);
  AssertEquals(0, M3Res.ConflictCount, 'Zero conflicts reported on clean merge', PassedTests, TotalTests);
  AssertEqualsStr('line1'#10'line2-ours'#10'line3-theirs', M3Res.MergedText, 'Merged text reflects both distinct changes', PassedTests, TotalTests);

  { Conflicting edits on same line }
  BaseStr := 'alpha'#10'beta'#10'gamma';
  OursStr := 'alpha'#10'beta-edited-by-alice'#10'gamma';
  TheirsStr := 'alpha'#10'beta-edited-by-bob'#10'gamma';

  M3Res := Merge3Strings(BaseStr, OursStr, TheirsStr, 'alice', 'bob');
  AssertTrue(M3Res.HasConflict, 'Conflicting edits on same line detects conflict', PassedTests, TotalTests);
  AssertEquals(1, M3Res.ConflictCount, 'Exactly 1 conflict recorded', PassedTests, TotalTests);
  AssertTrue(Pos('<<<<<<< alice', M3Res.MergedText) > 0, 'Merged text has <<<<<<< alice marker', PassedTests, TotalTests);
  AssertTrue(Pos('=======', M3Res.MergedText) > 0, 'Merged text has ======= separator marker', PassedTests, TotalTests);
  AssertTrue(Pos('>>>>>>> bob', M3Res.MergedText) > 0, 'Merged text has >>>>>>> bob marker', PassedTests, TotalTests);

  { Diff3 style conflict with ancestor base lines }
  M3Res := Merge3Strings(BaseStr, OursStr, TheirsStr, 'alice', 'bob', True);
  AssertTrue(Pos('||||||| base', M3Res.MergedText) > 0, 'Diff3 style includes ||||||| base marker', PassedTests, TotalTests);
  AssertTrue(Pos('beta', M3Res.MergedText) > 0, 'Base section includes original line "beta"', PassedTests, TotalTests);

  { --- 2. Lowest Common Ancestor (LCA) Tests --- }
  TestDir := JoinPaths(GetTempDir, 'anvil_merge_test_' + IntToStr(Random(1000000)));
  EnsureDirectoryExists(TestDir);
  ODB := TObjectDatabase.Create(TestDir);
  Index := TIndex.Create(JoinPaths(TestDir, 'index'));
  try
    { Create a root tree }
    Tree1 := TTreeObject.Create;
    try
      TreeId1 := Tree1.ObjectId;
      ODB.WriteObject(Tree1);
    finally
      Tree1.Free;
    end;

    { Build DAG:
        C1 (root)
        |
        C2 (fork)
       /  \
      C3   C4
    }
    Committer.Name := 'Author';
    Committer.Email := 'author@test.local';
    Committer.When.Seconds := 1000;
    Committer.When.OffsetMinutes := 0;

    C1 := TCommitObject.Create;
    C1.TreeId := TreeId1;
    C1.Author := Committer;
    C1.Message := 'Initial commit';
    Id1 := C1.ObjectId;
    ODB.WriteObject(C1);
    C1.Free;

    Committer.When.Seconds := 2000;
    C2 := TCommitObject.Create;
    C2.TreeId := TreeId1;
    C2.AddParent(Id1);
    C2.Author := Committer;
    C2.Message := 'Fork point';
    Id2 := C2.ObjectId;
    ODB.WriteObject(C2);
    C2.Free;

    Committer.Name := 'Alice';
    Committer.When.Seconds := 3000;
    C3 := TCommitObject.Create;
    C3.TreeId := TreeId1;
    C3.AddParent(Id2);
    C3.Author := Committer;
    C3.Message := 'Branch A work';
    Id3 := C3.ObjectId;
    ODB.WriteObject(C3);
    C3.Free;

    Committer.Name := 'Bob';
    Committer.When.Seconds := 3500;
    C4 := TCommitObject.Create;
    C4.TreeId := TreeId1;
    C4.AddParent(Id2);
    C4.Author := Committer;
    C4.Message := 'Branch B work';
    Id4 := C4.ObjectId;
    ODB.WriteObject(C4);
    C4.Free;

    LcaFinder := TLcaFinder.Create(ODB);
    try
      { LCA between C3 and C4 must be C2 }
      AssertTrue(LcaFinder.FindBestMergeBase(Id3, Id4, BestBaseId), 'LCA finder finds merge base', PassedTests, TotalTests);
      AssertTrue(ObjectIdEqual(Id2, BestBaseId), 'LCA of C3 and C4 is fork commit C2', PassedTests, TotalTests);

      { LCA between C1 and C3 must be C1 }
      LcaFinder.FindBestMergeBase(Id1, Id3, BestBaseId);
      AssertTrue(ObjectIdEqual(Id1, BestBaseId), 'LCA of ancestor C1 and descendant C3 is C1', PassedTests, TotalTests);
    finally
      LcaFinder.Free;
    end;

    { --- 3. Tree Merge Tests --- }
    { Create blobs }
    BlobA := TBlobObject.CreateWithString('fileA constant'#10);
    ODB.WriteObject(BlobA);

    BlobB1 := TBlobObject.CreateWithString('fileB version 1'#10);
    ODB.WriteObject(BlobB1);

    BlobB2 := TBlobObject.CreateWithString('fileB version 2 modified'#10);
    ODB.WriteObject(BlobB2);

    BlobC := TBlobObject.CreateWithString('fileC new on branch B'#10);
    ODB.WriteObject(BlobC);

    { Create trees:
        TreeBase:  fileA, fileB1
        TreeOurs:   fileA, fileB2 (modified fileB)
        TreeTheirs: fileA, fileB1, fileC (added fileC)
    }
    TreeBase := TTreeObject.Create;
    TreeBase.AddEntry(fmRegular, 'fileA', BlobA.ObjectId);
    TreeBase.AddEntry(fmRegular, 'fileB', BlobB1.ObjectId);
    TBaseId := TreeBase.ObjectId;
    ODB.WriteObject(TreeBase);

    TreeOurs := TTreeObject.Create;
    TreeOurs.AddEntry(fmRegular, 'fileA', BlobA.ObjectId);
    TreeOurs.AddEntry(fmRegular, 'fileB', BlobB2.ObjectId);
    TOursId := TreeOurs.ObjectId;
    ODB.WriteObject(TreeOurs);

    TreeTheirs := TTreeObject.Create;
    TreeTheirs.AddEntry(fmRegular, 'fileA', BlobA.ObjectId);
    TreeTheirs.AddEntry(fmRegular, 'fileB', BlobB1.ObjectId);
    TreeTheirs.AddEntry(fmRegular, 'fileC', BlobC.ObjectId);
    TTheirsId := TreeTheirs.ObjectId;
    ODB.WriteObject(TreeTheirs);

    { Execute 3-way tree merge }
    MergeSum := MergeTrees(ODB, Index, TBaseId, TOursId, TTheirsId);
    AssertTrue(MergeSum.Success, 'Clean tree merge succeeds without conflict', PassedTests, TotalTests);
    AssertEquals(0, MergeSum.ConflictCount, 'Zero conflicts in clean tree merge', PassedTests, TotalTests);
    AssertTrue(not IsNullObjectId(MergeSum.ResultTreeId), 'Result tree synthesized in ODB', PassedTests, TotalTests);
    AssertEquals(3, Index.Count, 'Index contains 3 files (fileA, fileB, fileC)', PassedTests, TotalTests);

    TreeBase.Free;
    TreeOurs.Free;
    TreeTheirs.Free;
    BlobA.Free;
    BlobB1.Free;
    BlobB2.Free;
    BlobC.Free;

    { --- 4. Rebase and Cherry-pick Tests --- }
    Committer.Name := 'Anvil Rebaser';
    Committer.Email := 'rebase@anvil.local';
    Committer.When.Seconds := 5000;
    Committer.When.OffsetMinutes := 0;

    RebaseEng := TRebaseEngine.Create(ODB, Index, Committer);
    try
      { Cherry-pick C3 onto C4 }
      CpRes := RebaseEng.CherryPick(Id3, Id4);
      AssertTrue(CpRes.Success, 'Cherry-pick commit C3 onto C4 succeeds cleanly', PassedTests, TotalTests);
      AssertTrue(not IsNullObjectId(CpRes.NewCommitId), 'Cherry-picked commit ID generated', PassedTests, TotalTests);

      { Verify cherry-picked commit properties }
      Obj := ODB.ReadObject(CpRes.NewCommitId);
      AssertTrue(Assigned(Obj) and (Obj is TCommitObject), 'Cherry-picked commit is TCommitObject in ODB', PassedTests, TotalTests);
      RebasedCommit := TCommitObject(Obj);
      try
        AssertEquals(1, Length(RebasedCommit.ParentIds), 'Replayed commit has exactly 1 parent', PassedTests, TotalTests);
        AssertTrue(ObjectIdEqual(Id4, RebasedCommit.ParentIds[0]), 'Replayed commit parent is C4', PassedTests, TotalTests);
        AssertEqualsStr('Alice', RebasedCommit.Author.Name, 'Replayed commit preserved original author', PassedTests, TotalTests);
        AssertEqualsStr('Anvil Rebaser', RebasedCommit.Committer.Name, 'Replayed commit updated committer', PassedTests, TotalTests);
        AssertEqualsStr('Branch A work', RebasedCommit.Message, 'Replayed commit preserved message', PassedTests, TotalTests);
      finally
        RebasedCommit.Free;
      end;

      { Linear rebase of branch C3 onto upstream C4 }
      RebaseRes := RebaseEng.RebaseBranch(Id4, Id3);
      AssertTrue(RebaseRes.Success, 'RebaseBranch C3 onto upstream C4 succeeds', PassedTests, TotalTests);
      AssertEquals(1, RebaseRes.ReplayedCount, 'Rebased 1 commit successfully', PassedTests, TotalTests);
      AssertTrue(not IsNullObjectId(RebaseRes.NewTipCommitId), 'New branch tip returned', PassedTests, TotalTests);
    finally
      RebaseEng.Free;
    end;

  finally
    Index.Free;
    ODB.Free;
    DeleteDirectoryRecursive(TestDir);
  end;
end;

end.
