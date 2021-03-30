{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Unit tests for the Difference and Patch subsystem:
  Myers O(ND) diff, Patience diff, tree-to-tree diff,
  rename/copy detection, and unified diff hunk formatting.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit test_diff;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, anvil_types, anvil_utils, anvil_object, anvil_odb,
  anvil_myers, anvil_patience, anvil_diff_tree, anvil_rename, anvil_patch;

procedure RunDiffTests(var PassedTests, TotalTests: Integer);

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

procedure RunDiffTests(var PassedTests, TotalTests: Integer);
var
  DocA, DocB, PatchText: string;
  MyersResult, PatienceResult: TDiffLineArray;
  TestDir, ObjectsDir: string;
  Odb: TObjectDatabase;
  TreeA, TreeB: TTreeObject;
  IdA, IdB, IdC, TreeIdA, TreeIdB: TObjectId;
  TreeDiffObj: TTreeDiff;
  Deltas, RenamedDeltas: TTreeDeltaArray;
  RenameDetector: TRenameDetector;
  PatchGen: TPatchGenerator;
  I, InsCount, DelCount, KeepCount: Integer;
begin
  Writeln('=== Running Difference and Patch Test Suite ===');

  { Test 1: Myers Diff on Basic Line Mutations }
  DocA := 'apple'#10'banana'#10'cherry'#10'dates';
  DocB := 'apple'#10'blueberry'#10'cherry'#10'dates'#10'elderberry';

  MyersResult := MyersDiffStrings(DocA, DocB);
  InsCount := 0;
  DelCount := 0;
  KeepCount := 0;

  for I := 0 to High(MyersResult) do
  begin
    case MyersResult[I].Op of
      eoKeep:   Inc(KeepCount);
      eoInsert: Inc(InsCount);
      eoDelete: Inc(DelCount);
    end;
  end;

  AssertTrue(KeepCount = 3, 'Myers diff identifies 3 common lines (apple, cherry, dates)', PassedTests, TotalTests);
  AssertTrue(DelCount = 1, 'Myers diff identifies 1 deletion (banana)', PassedTests, TotalTests);
  AssertTrue(InsCount = 2, 'Myers diff identifies 2 insertions (blueberry, elderberry)', PassedTests, TotalTests);

  { Test 2: Patience Diff on Reordered Blocks }
  DocA := 'procedure Init;'#10'begin'#10'  Writeln(''Init'');'#10'end;'#10#10 +
          'procedure Process;'#10'begin'#10'  Writeln(''Process'');'#10'end;';
  DocB := 'procedure Setup;'#10'begin'#10'  Writeln(''Setup'');'#10'end;'#10#10 +
          'procedure Process;'#10'begin'#10'  Writeln(''Process'');'#10'end;';

  PatienceResult := PatienceDiffStrings(DocA, DocB);
  AssertTrue(Length(PatienceResult) > 0, 'Patience diff executes successfully on function block replace', PassedTests, TotalTests);

  { Verify that "procedure Process;" is kept as an anchor }
  KeepCount := 0;
  for I := 0 to High(PatienceResult) do
  begin
    if (PatienceResult[I].Op = eoKeep) and (Pos('procedure Process;', PatienceResult[I].Text) > 0) then
      KeepCount := 1;
  end;
  AssertTrue(KeepCount = 1, 'Patience diff anchors on untouched procedure Process', PassedTests, TotalTests);

  { Test 3: Tree-to-Tree Difference Engine }
  TestDir := JoinPaths(ExtractFilePath(ParamStr(0)), 'tmp_diff_test');
  ObjectsDir := JoinPaths(TestDir, 'objects');
  if DirectoryExists(TestDir) then
    DeleteDirectoryRecursive(TestDir);
  ForceDirectories(ObjectsDir);

  try
    Odb := TObjectDatabase.Create(ObjectsDir, haSHA1);
    try
      IdA := Odb.WriteObjectRaw(otBlob, PChar('alpha content'), 13);
      IdB := Odb.WriteObjectRaw(otBlob, PChar('beta content'), 12);
      IdC := Odb.WriteObjectRaw(otBlob, PChar('gamma content'), 13);

      { Tree A: file1 (IdA), file2 (IdB) }
      TreeA := TTreeObject.Create;
      TreeA.AddEntry(fmRegular, 'file1.txt', IdA);
      TreeA.AddEntry(fmRegular, 'file2.txt', IdB);
      TreeIdA := Odb.WriteObject(TreeA);
      TreeA.Free;

      { Tree B: file1 (IdC, modified), file2 deleted, file3 (IdB, renamed from file2) }
      TreeB := TTreeObject.Create;
      TreeB.AddEntry(fmRegular, 'file1.txt', IdC);
      TreeB.AddEntry(fmRegular, 'file3.txt', IdB);
      TreeIdB := Odb.WriteObject(TreeB);
      TreeB.Free;

      TreeDiffObj := TTreeDiff.Create(Odb);
      try
        Deltas := TreeDiffObj.Diff(TreeIdA, TreeIdB);
        AssertTrue(Length(Deltas) = 3, 'TreeDiff identifies 3 raw changes', PassedTests, TotalTests);

        { Test 4: Rename and Copy Detection }
        RenameDetector := TRenameDetector.Create(Odb, 50);
        try
          RenamedDeltas := RenameDetector.DetectRenames(Deltas);
          AssertTrue(Length(RenamedDeltas) = 2, 'Rename detector pairs file2.txt -> file3.txt as 1 rename delta', PassedTests, TotalTests);

          for I := 0 to High(RenamedDeltas) do
          begin
            if RenamedDeltas[I].Status = dsRenamed then
            begin
              AssertEquals('file2.txt', RenamedDeltas[I].OldPath, 'Rename delta old path is file2.txt', PassedTests, TotalTests);
              AssertEquals('file3.txt', RenamedDeltas[I].NewPath, 'Rename delta new path is file3.txt', PassedTests, TotalTests);
              AssertTrue(RenamedDeltas[I].Similarity = 100, 'Identical blob content gives 100% similarity score', PassedTests, TotalTests);
            end;
          end;
        finally
          RenameDetector.Free;
        end;

        { Test 5: Unified Diff Patch Formatting }
        PatchGen := TPatchGenerator.Create(3);
        try
          PatchText := PatchGen.FormatFileDiff(Deltas[0], MyersResult);
          AssertTrue(Pos('diff --git', PatchText) = 1, 'Patch text starts with standard diff --git header', PassedTests, TotalTests);
          AssertTrue(Pos('@@ -', PatchText) > 0, 'Patch contains unified diff hunk header', PassedTests, TotalTests);
          AssertTrue(Pos('+blueberry', PatchText) > 0, 'Patch contains inserted line +blueberry', PassedTests, TotalTests);
          AssertTrue(Pos('-banana', PatchText) > 0, 'Patch contains deleted line -banana', PassedTests, TotalTests);
        finally
          PatchGen.Free;
        end;

      finally
        TreeDiffObj.Free;
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
