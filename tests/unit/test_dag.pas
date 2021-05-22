{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Unit verification suite for revision parsing, DAG walking, blame, and ASCII graph.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit test_dag;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_ref, anvil_reflog, anvil_revision, anvil_dag, anvil_blame,
  anvil_graph_view, anvil_utils;

procedure RunDagTests(var PassedTests, TotalTests: Integer);

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

procedure RunDagTests(var PassedTests, TotalTests: Integer);
var
  TestDir, GitDir: string;
  ODB: TObjectDatabase;
  RefMgr: TRefManager;
  ReflogMgr: TReflogManager;
  RevParser: TRevisionParser;
  Walker: TCommitWalker;
  BlameRes: TBlameLineArray;
  Renderer: TGraphRenderer;
  GraphLines: TGraphLineArray;

  Blob1, Blob2, Blob3, BlobUntouched: TBlobObject;
  Tree1, Tree2, Tree3: TTreeObject;
  TreeId1, TreeId2, TreeId3: TObjectId;
  C1, C2, C3: TCommitObject;
  Id1, Id2, Id3: TObjectId;
  ResolvedId: TObjectId;
  IncIds, ExcIds: TObjectIdArray;

  AuthorAlice, AuthorBob, AuthorCharlie: TIdentity;
  WalkedIds: TObjectIdArray;
  WalkId: TObjectId;
  ShortSha: string;
  GraphOutput: string;
begin
  Writeln('=== Running DAG Traversal, Revision, Blame, and Graph Test Suite ===');

  TestDir := JoinPaths(GetTempDir, 'anvil_dag_test_' + IntToStr(Random(1000000)));
  GitDir := JoinPaths(TestDir, '.anvil');
  EnsureDirectoryExists(GitDir);

  ODB := TObjectDatabase.Create(GitDir);
  RefMgr := TRefManager.Create(GitDir);
  ReflogMgr := TReflogManager.Create(GitDir);
  try
    { Setup 3 authors }
    AuthorAlice.Name := 'Alice';
    AuthorAlice.Email := 'alice@test.local';
    AuthorAlice.When.Seconds := 1000;
    AuthorAlice.When.OffsetMinutes := 0;

    AuthorBob.Name := 'Bob';
    AuthorBob.Email := 'bob@test.local';
    AuthorBob.When.Seconds := 2000;
    AuthorBob.When.OffsetMinutes := 0;

    AuthorCharlie.Name := 'Charlie';
    AuthorCharlie.Email := 'charlie@test.local';
    AuthorCharlie.When.Seconds := 3000;
    AuthorCharlie.When.OffsetMinutes := 0;

    { C1: Alice creates code.pas with 3 lines:
        line1
        line2
        line3
    }
    Blob1 := TBlobObject.CreateWithString('line1'#10'line2'#10'line3'#10);
    ODB.WriteObject(Blob1);

    BlobUntouched := TBlobObject.CreateWithString('other content'#10);
    ODB.WriteObject(BlobUntouched);

    Tree1 := TTreeObject.Create;
    Tree1.AddEntry(fmRegular, 'code.pas', Blob1.ObjectId);
    Tree1.AddEntry(fmRegular, 'other.txt', BlobUntouched.ObjectId);
    TreeId1 := Tree1.ObjectId;
    ODB.WriteObject(Tree1);
    Tree1.Free;

    C1 := TCommitObject.Create;
    C1.TreeId := TreeId1;
    C1.Author := AuthorAlice;
    C1.Message := 'Initial commit by Alice';
    Id1 := C1.ObjectId;
    ODB.WriteObject(C1);
    C1.Free;

    { C2: Bob modifies only other.txt (code.pas remains untouched) }
    Tree2 := TTreeObject.Create;
    Tree2.AddEntry(fmRegular, 'code.pas', Blob1.ObjectId);
    Tree2.AddEntry(fmRegular, 'other.txt', Blob1.ObjectId); { changed other.txt }
    TreeId2 := Tree2.ObjectId;
    ODB.WriteObject(Tree2);
    Tree2.Free;

    C2 := TCommitObject.Create;
    C2.TreeId := TreeId2;
    C2.AddParent(Id1);
    C2.Author := AuthorBob;
    C2.Message := 'Bob updates other.txt';
    Id2 := C2.ObjectId;
    ODB.WriteObject(C2);
    C2.Free;

    { C3: Charlie modifies line 2 of code.pas:
        line1
        line2-edited-by-charlie
        line3
        line4-added
    }
    Blob3 := TBlobObject.CreateWithString('line1'#10'line2-edited-by-charlie'#10'line3'#10'line4-added'#10);
    ODB.WriteObject(Blob3);

    Tree3 := TTreeObject.Create;
    Tree3.AddEntry(fmRegular, 'code.pas', Blob3.ObjectId);
    Tree3.AddEntry(fmRegular, 'other.txt', Blob1.ObjectId);
    TreeId3 := Tree3.ObjectId;
    ODB.WriteObject(Tree3);
    Tree3.Free;

    C3 := TCommitObject.Create;
    C3.TreeId := TreeId3;
    C3.AddParent(Id2);
    C3.Author := AuthorCharlie;
    C3.Message := 'Charlie edits code.pas';
    Id3 := C3.ObjectId;
    ODB.WriteObject(C3);
    C3.Free;

    RefMgr.SetReference('refs/heads/main', Id3);
    RefMgr.SetSymbolicReference('HEAD', 'refs/heads/main');

    ReflogMgr.Append('refs/heads/main', Id2, Id3, AuthorCharlie, 'commit: Charlie edits code.pas');
    ReflogMgr.Append('refs/heads/main', Id1, Id2, AuthorBob, 'commit: Bob updates other.txt');

    { --- 1. Revision Parsing Tests --- }
    RevParser := TRevisionParser.Create(RefMgr, ReflogMgr, ODB);
    try
      { Full hex SHA }
      AssertTrue(RevParser.Resolve(ObjectIdToHex(Id1), ResolvedId), 'Resolve full hex SHA succeeds', PassedTests, TotalTests);
      AssertTrue(ObjectIdEqual(Id1, ResolvedId), 'Full hex SHA resolves to C1', PassedTests, TotalTests);

      { Short hex prefix }
      ShortSha := Copy(ObjectIdToHex(Id2), 1, 7);
      AssertTrue(RevParser.Resolve(ShortSha, ResolvedId), 'Resolve short 7-char prefix succeeds', PassedTests, TotalTests);
      AssertTrue(ObjectIdEqual(Id2, ResolvedId), 'Short prefix resolves to C2', PassedTests, TotalTests);

      { Branch name }
      AssertTrue(RevParser.Resolve('main', ResolvedId), 'Resolve branch name "main" succeeds', PassedTests, TotalTests);
      AssertTrue(ObjectIdEqual(Id3, ResolvedId), 'Branch "main" resolves to C3', PassedTests, TotalTests);

      { Parent operators: HEAD^, HEAD~1, HEAD~2 }
      AssertTrue(RevParser.Resolve('HEAD^', ResolvedId), 'Resolve HEAD^ succeeds', PassedTests, TotalTests);
      AssertTrue(ObjectIdEqual(Id2, ResolvedId), 'HEAD^ is C2', PassedTests, TotalTests);

      AssertTrue(RevParser.Resolve('HEAD~1', ResolvedId), 'Resolve HEAD~1 succeeds', PassedTests, TotalTests);
      AssertTrue(ObjectIdEqual(Id2, ResolvedId), 'HEAD~1 is C2', PassedTests, TotalTests);

      AssertTrue(RevParser.Resolve('HEAD~2', ResolvedId), 'Resolve HEAD~2 succeeds', PassedTests, TotalTests);
      AssertTrue(ObjectIdEqual(Id1, ResolvedId), 'HEAD~2 is C1', PassedTests, TotalTests);

      { Compound: HEAD~1^ }
      AssertTrue(RevParser.Resolve('HEAD~1^', ResolvedId), 'Resolve compound HEAD~1^ succeeds', PassedTests, TotalTests);
      AssertTrue(ObjectIdEqual(Id1, ResolvedId), 'HEAD~1^ is C1', PassedTests, TotalTests);

      { Reflog relative notation: main@{0} }
      AssertTrue(RevParser.Resolve('main@{0}', ResolvedId), 'Resolve reflog relative main@{0} succeeds', PassedTests, TotalTests);

      { Range parsing }
      AssertTrue(RevParser.ParseRange('HEAD~2..HEAD', IncIds, ExcIds), 'ParseRange HEAD~2..HEAD succeeds', PassedTests, TotalTests);
      AssertEquals(1, Length(IncIds), '1 include ID in range', PassedTests, TotalTests);
      AssertEquals(1, Length(ExcIds), '1 exclude ID in range', PassedTests, TotalTests);
      AssertTrue(ObjectIdEqual(Id3, IncIds[0]), 'Range include ID is C3', PassedTests, TotalTests);
      AssertTrue(ObjectIdEqual(Id1, ExcIds[0]), 'Range exclude ID is C1', PassedTests, TotalTests);
    finally
      RevParser.Free;
    end;

    { --- 2. Commit Walker Tests --- }
    Walker := TCommitWalker.Create(ODB, csoChronological);
    try
      Walker.Push(Id3);
      SetLength(WalkedIds, 0);
      while Walker.Next(WalkId) do
      begin
        SetLength(WalkedIds, Length(WalkedIds) + 1);
        WalkedIds[Length(WalkedIds) - 1] := WalkId;
      end;

      AssertEquals(3, Length(WalkedIds), 'Full walk yields exactly 3 commits', PassedTests, TotalTests);
      AssertTrue(ObjectIdEqual(Id3, WalkedIds[0]), 'First yielded is C3', PassedTests, TotalTests);
      AssertTrue(ObjectIdEqual(Id2, WalkedIds[1]), 'Second yielded is C2', PassedTests, TotalTests);
      AssertTrue(ObjectIdEqual(Id1, WalkedIds[2]), 'Third yielded is C1', PassedTests, TotalTests);

      { Walk with exclusion range: Push(C3), Hide(C1) }
      Walker.Reset;
      Walker.Push(Id3);
      Walker.Hide(Id1);
      SetLength(WalkedIds, 0);
      while Walker.Next(WalkId) do
      begin
        SetLength(WalkedIds, Length(WalkedIds) + 1);
        WalkedIds[Length(WalkedIds) - 1] := WalkId;
      end;
      AssertEquals(2, Length(WalkedIds), 'Range walk (C1..C3) yields exactly 2 commits (C3, C2)', PassedTests, TotalTests);
      AssertTrue(ObjectIdEqual(Id3, WalkedIds[0]), 'First is C3', PassedTests, TotalTests);
      AssertTrue(ObjectIdEqual(Id2, WalkedIds[1]), 'Second is C2', PassedTests, TotalTests);

      { Path-limited walk: only commits modifying "code.pas" }
      Walker.Reset;
      Walker.Push(Id3);
      Walker.SetPathFilter('code.pas');
      SetLength(WalkedIds, 0);
      while Walker.Next(WalkId) do
      begin
        SetLength(WalkedIds, Length(WalkedIds) + 1);
        WalkedIds[Length(WalkedIds) - 1] := WalkId;
      end;
      AssertEquals(2, Length(WalkedIds), 'Path filter code.pas skips C2 and yields 2 commits (C3, C1)', PassedTests, TotalTests);
      AssertTrue(ObjectIdEqual(Id3, WalkedIds[0]), 'Path filter first commit is C3', PassedTests, TotalTests);
      AssertTrue(ObjectIdEqual(Id1, WalkedIds[1]), 'Path filter second commit is C1', PassedTests, TotalTests);
    finally
      Walker.Free;
    end;

    { --- 3. Blame Engine Tests --- }
    BlameRes := BlameFile(ODB, 'code.pas', Id3);
    AssertEquals(4, Length(BlameRes), 'Blame returns 4 lines for code.pas', PassedTests, TotalTests);

    { Line 1: untouched since C1 -> Alice }
    AssertTrue(ObjectIdEqual(Id1, BlameRes[0].CommitId), 'Line 1 attributed to C1', PassedTests, TotalTests);
    AssertEqualsStr('Alice', BlameRes[0].Author.Name, 'Line 1 author is Alice', PassedTests, TotalTests);

    { Line 2: edited in C3 -> Charlie }
    AssertTrue(ObjectIdEqual(Id3, BlameRes[1].CommitId), 'Line 2 attributed to C3', PassedTests, TotalTests);
    AssertEqualsStr('Charlie', BlameRes[1].Author.Name, 'Line 2 author is Charlie', PassedTests, TotalTests);

    { Line 3: untouched since C1 -> Alice }
    AssertTrue(ObjectIdEqual(Id1, BlameRes[2].CommitId), 'Line 3 attributed to C1', PassedTests, TotalTests);
    AssertEqualsStr('Alice', BlameRes[2].Author.Name, 'Line 3 author is Alice', PassedTests, TotalTests);

    { Line 4: added in C3 -> Charlie }
    AssertTrue(ObjectIdEqual(Id3, BlameRes[3].CommitId), 'Line 4 attributed to C3', PassedTests, TotalTests);
    AssertEqualsStr('Charlie', BlameRes[3].Author.Name, 'Line 4 author is Charlie', PassedTests, TotalTests);

    { --- 4. ASCII Graph Renderer Tests --- }
    Renderer := TGraphRenderer.Create(ODB, RefMgr);
    try
      GraphLines := Renderer.RenderHistory(Id3);
      AssertEquals(3, Length(GraphLines), 'Graph renderer generated 3 rows', PassedTests, TotalTests);
      AssertTrue(Pos('*', GraphLines[0].Glyphs) > 0, 'First row has * graph glyph', PassedTests, TotalTests);
      AssertTrue(Pos('main', GraphLines[0].Decorations) > 0, 'First row has main branch decoration', PassedTests, TotalTests);

      GraphOutput := Renderer.FormatGraphString(GraphLines);
      AssertTrue(Pos('Charlie edits code.pas', GraphOutput) > 0, 'Formatted graph string includes commit message', PassedTests, TotalTests);
    finally
      Renderer.Free;
    end;

    Blob1.Free;
    Blob3.Free;
    BlobUntouched.Free;
  finally
    ReflogMgr.Free;
    RefMgr.Free;
    ODB.Free;
    DeleteDirectoryRecursive(TestDir);
  end;
end;

end.
