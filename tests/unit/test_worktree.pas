{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Unit verification suite for ignore patterns, worktree status, and checkout.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit test_worktree;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_index, anvil_index_entry, anvil_ref, anvil_ignore, anvil_worktree,
  anvil_checkout, anvil_utils;

procedure RunWorktreeTests(var PassedTests, TotalTests: Integer);

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

procedure RunWorktreeTests(var PassedTests, TotalTests: Integer);
var
  TestDir, GitDir: string;
  Ignore: TIgnoreMatcher;
  ODB: TObjectDatabase;
  Index: TIndex;
  RefMgr: TRefManager;
  Scanner: TWorktreeScanner;
  Status: TWorktreeStatus;
  CheckoutMgr: TCheckoutManager;
  Options: TCheckoutOptions;
  CheckRes: TCheckoutResult;

  Blob1, Blob2, Blob3: TBlobObject;
  Tree1, Tree2: TTreeObject;
  TreeId1, TreeId2: TObjectId;
  Commit1, Commit2: TCommitObject;
  CommitId1, CommitId2: TObjectId;
  Committer: TIdentity;
begin
  Writeln('=== Running Working Tree, Ignore, and Checkout Test Suite ===');

  { --- 1. Ignore Matcher Tests --- }
  Ignore := TIgnoreMatcher.Create;
  try
    Ignore.AddRules('*.o'#10'build/'#10'*.log'#10'!important.log'#10'**/temp/*.tmp');

    AssertTrue(Ignore.IsIgnored('main.o', False), 'main.o matches *.o pattern', PassedTests, TotalTests);
    AssertTrue(not Ignore.IsIgnored('main.c', False), 'main.c is not ignored', PassedTests, TotalTests);
    AssertTrue(Ignore.IsIgnored('debug.log', False), 'debug.log matches *.log pattern', PassedTests, TotalTests);
    AssertTrue(not Ignore.IsIgnored('important.log', False), 'important.log un-ignored by negated rule', PassedTests, TotalTests);
    AssertTrue(Ignore.IsIgnored('build', True), 'build/ matches directory "build"', PassedTests, TotalTests);
    AssertTrue(not Ignore.IsIgnored('build', False), 'build/ does not match file "build"', PassedTests, TotalTests);
    AssertTrue(Ignore.IsIgnored('src/sub/temp/test.tmp', False), 'Globstar **/temp/*.tmp matches nested path', PassedTests, TotalTests);
  finally
    Ignore.Free;
  end;

  { --- 2. Working Tree Status Scanner Tests --- }
  TestDir := JoinPaths(GetTempDir, 'anvil_wt_test_' + IntToStr(Random(1000000)));
  GitDir := JoinPaths(TestDir, '.anvil');
  EnsureDirectoryExists(GitDir);

  ODB := TObjectDatabase.Create(GitDir);
  Index := TIndex.Create(JoinPaths(GitDir, 'index'));
  RefMgr := TRefManager.Create(GitDir);
  try
    { Write initial file to disk and stage it }
    WriteEntireFileString(JoinPaths(TestDir, 'file1.txt'), 'content one'#10);
    WriteEntireFileString(JoinPaths(TestDir, 'file2.txt'), 'content two'#10);

    Blob1 := TBlobObject.CreateWithString('content one'#10);
    ODB.WriteObject(Blob1);
    Blob2 := TBlobObject.CreateWithString('content two'#10);
    ODB.WriteObject(Blob2);

    Index.AddFile('file1.txt', Blob1.ObjectId, fmRegular, 12);
    Index.AddFile('file2.txt', Blob2.ObjectId, fmRegular, 12);
    Index.WriteToFile;

    Tree1 := TTreeObject.Create;
    Tree1.AddEntry(fmRegular, 'file1.txt', Blob1.ObjectId);
    Tree1.AddEntry(fmRegular, 'file2.txt', Blob2.ObjectId);
    TreeId1 := Tree1.ObjectId;
    ODB.WriteObject(Tree1);
    Tree1.Free;

    Committer.Name := 'Tester';
    Committer.Email := 'tester@test.local';
    Committer.When.Seconds := 1000;
    Committer.When.OffsetMinutes := 0;

    Commit1 := TCommitObject.Create;
    Commit1.TreeId := TreeId1;
    Commit1.Author := Committer;
    Commit1.Message := 'Initial';
    CommitId1 := Commit1.ObjectId;
    ODB.WriteObject(Commit1);
    Commit1.Free;

    RefMgr.SetReference('refs/heads/main', CommitId1);
    RefMgr.SetSymbolicReference('HEAD', 'refs/heads/main');

    { Clean status check }
    Scanner := TWorktreeScanner.Create(TestDir, GitDir, ODB, Index);
    try
      Status := Scanner.ComputeStatus(TreeId1);
      AssertTrue(Status.IsClean, 'Working tree is completely clean initially', PassedTests, TotalTests);
      AssertEquals(0, Length(Status.Untracked), 'Zero untracked files', PassedTests, TotalTests);
      AssertEquals(0, Length(Status.UnstagedModified), 'Zero unstaged modified files', PassedTests, TotalTests);

      { Add untracked file }
      WriteEntireFileString(JoinPaths(TestDir, 'untracked.txt'), 'hello'#10);
      Status := Scanner.ComputeStatus(TreeId1);
      AssertTrue(not Status.IsClean, 'Status is not clean after adding untracked file', PassedTests, TotalTests);
      AssertEquals(1, Length(Status.Untracked), 'Exactly 1 untracked file', PassedTests, TotalTests);
      AssertEqualsStr('untracked.txt', Status.Untracked[0], 'Untracked path matches untracked.txt', PassedTests, TotalTests);

      { Add .gitignore to ignore untracked.txt }
      WriteEntireFileString(JoinPaths(TestDir, '.gitignore'), 'untracked.txt'#10);
      Status := Scanner.ComputeStatus(TreeId1);
      AssertTrue(not Status.IsClean, 'Status reports untracked .gitignore', PassedTests, TotalTests);
      AssertEquals(1, Length(Status.Untracked), 'untracked.txt is now ignored; only .gitignore is untracked', PassedTests, TotalTests);
      AssertEqualsStr('.gitignore', Status.Untracked[0], 'Untracked file is .gitignore', PassedTests, TotalTests);

      DeleteFile(JoinPaths(TestDir, '.gitignore'));
      DeleteFile(JoinPaths(TestDir, 'untracked.txt'));

      { Modify tracked file }
      WriteEntireFileString(JoinPaths(TestDir, 'file1.txt'), 'modified content'#10);
      Status := Scanner.ComputeStatus(TreeId1);
      AssertEquals(1, Length(Status.UnstagedModified), 'Detected 1 unstaged modified file', PassedTests, TotalTests);
      AssertEqualsStr('file1.txt', Status.UnstagedModified[0], 'Modified file is file1.txt', PassedTests, TotalTests);

      { Restore file1.txt }
      WriteEntireFileString(JoinPaths(TestDir, 'file1.txt'), 'content one'#10);

      { Delete tracked file from disk }
      DeleteFile(JoinPaths(TestDir, 'file2.txt'));
      Status := Scanner.ComputeStatus(TreeId1);
      AssertEquals(1, Length(Status.UnstagedDeleted), 'Detected 1 unstaged deleted file', PassedTests, TotalTests);
      AssertEqualsStr('file2.txt', Status.UnstagedDeleted[0], 'Deleted file is file2.txt', PassedTests, TotalTests);

      { Restore file2.txt }
      WriteEntireFileString(JoinPaths(TestDir, 'file2.txt'), 'content two'#10);
    finally
      Scanner.Free;
    end;

    { --- 3. Checkout Manager Tests --- }
    { Create Commit2 with file3.txt added and file2.txt removed }
    Blob3 := TBlobObject.CreateWithString('content three'#10);
    ODB.WriteObject(Blob3);

    Tree2 := TTreeObject.Create;
    Tree2.AddEntry(fmRegular, 'file1.txt', Blob1.ObjectId);
    Tree2.AddEntry(fmRegular, 'file3.txt', Blob3.ObjectId);
    TreeId2 := Tree2.ObjectId;
    ODB.WriteObject(Tree2);
    Tree2.Free;

    Commit2 := TCommitObject.Create;
    Commit2.TreeId := TreeId2;
    Commit2.AddParent(CommitId1);
    Commit2.Author := Committer;
    Commit2.Message := 'Second commit';
    CommitId2 := Commit2.ObjectId;
    ODB.WriteObject(Commit2);
    Commit2.Free;

    RefMgr.SetReference('refs/heads/feature', CommitId2);

    CheckoutMgr := TCheckoutManager.Create(TestDir, GitDir, ODB, Index, RefMgr);
    try
      { Safe checkout of Commit2 }
      FillChar(Options, SizeOf(Options), 0);
      Options.Force := False;
      Options.BranchName := 'feature';

      CheckRes := CheckoutMgr.CheckoutCommit(CommitId2, Options);
      AssertTrue(CheckRes.Success, 'Safe checkout of feature branch succeeds', PassedTests, TotalTests);
      AssertTrue(FileExists(JoinPaths(TestDir, 'file3.txt')), 'file3.txt created on disk', PassedTests, TotalTests);
      AssertTrue(not FileExists(JoinPaths(TestDir, 'file2.txt')), 'file2.txt removed from disk', PassedTests, TotalTests);
      AssertEquals(2, Index.Count, 'Index now contains 2 entries (file1.txt, file3.txt)', PassedTests, TotalTests);

      { Verify HEAD points to refs/heads/feature }
      AssertEqualsStr('ref: refs/heads/feature'#10, ReadEntireFileString(JoinPaths(GitDir, 'HEAD')), 'HEAD updated to refs/heads/feature', PassedTests, TotalTests);

      { Test dirty file protection }
      WriteEntireFileString(JoinPaths(TestDir, 'file1.txt'), 'dirty unsaved work'#10);
      Options.BranchName := 'main';
      CheckRes := CheckoutMgr.CheckoutCommit(CommitId1, Options);
      AssertTrue(not CheckRes.Success, 'Checkout fails when local modifications would be overwritten', PassedTests, TotalTests);
      AssertTrue(Pos('unstaged modifications', CheckRes.ErrorMessage) > 0, 'Error message reports unstaged modifications', PassedTests, TotalTests);

      { Force checkout overrides dirty check }
      Options.Force := True;
      CheckRes := CheckoutMgr.CheckoutCommit(CommitId1, Options);
      AssertTrue(CheckRes.Success, 'Force checkout succeeds over dirty files', PassedTests, TotalTests);
      AssertEqualsStr('content one'#10, ReadEntireFileString(JoinPaths(TestDir, 'file1.txt')), 'file1.txt restored to clean content from commit 1', PassedTests, TotalTests);
    finally
      CheckoutMgr.Free;
    end;

    Blob1.Free;
    Blob2.Free;
    Blob3.Free;
  finally
    RefMgr.Free;
    Index.Free;
    ODB.Free;
    DeleteDirectoryRecursive(TestDir);
  end;
end;

end.
