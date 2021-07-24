{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Integration test suite verifying end-to-end repository lifecycle
  and CLI command workflows.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit test_cli_workflow;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_cli_router, anvil_utils;

procedure RunCliWorkflowTests(var PassedTests, TotalTests: Integer);

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

function RunCli(const Cmd: string; const Args: array of string): Integer;
var
  ArgsArr: TStringArray;
  I: Integer;
begin
  SetLength(ArgsArr, Length(Args));
  for I := 0 to Length(Args) - 1 do
    ArgsArr[I] := Args[I];
  Result := DispatchCliCommand(Cmd, ArgsArr);
end;

procedure RunCliWorkflowTests(var PassedTests, TotalTests: Integer);
var
  OriginalDir, TestDir: string;
  Code: Integer;
begin
  Writeln('=== Running End-to-End CLI Integration Workflow ===');

  OriginalDir := GetCurrentDir;
  TestDir := '/tmp/anvil_cli_test_' + IntToStr(Random(1000000));
  EnsureDirectoryExists(TestDir);

  try
    SetCurrentDir(TestDir);

    { 1. anvil init }
    Code := RunCli('init', []);
    AssertEquals(0, Code, 'anvil init creates repository', PassedTests, TotalTests);
    AssertTrue(DirectoryExists(JoinPaths(TestDir, '.anvil')), '.anvil directory exists', PassedTests, TotalTests);
    AssertTrue(FileExists(JoinPaths(TestDir, '.anvil/HEAD')), '.anvil/HEAD exists', PassedTests, TotalTests);

    { 2. Create initial source files }
    WriteEntireFileString(JoinPaths(TestDir, 'app.pas'),
      'program App;'#10 +
      'begin'#10 +
      '  Writeln(''Hello Anvil'');'#10 +
      'end.'#10);

    WriteEntireFileString(JoinPaths(TestDir, 'math.pas'),
      'unit Math;'#10 +
      'interface'#10 +
      'function Add(A, B: Integer): Integer;'#10 +
      'implementation'#10 +
      'function Add(A, B: Integer): Integer; begin Result := A + B; end;'#10 +
      'end.'#10);

    { 3. anvil status }
    Code := RunCli('status', []);
    AssertEquals(0, Code, 'anvil status on untracked files', PassedTests, TotalTests);

    { 4. anvil add . }
    Code := RunCli('add', ['.']);
    AssertEquals(0, Code, 'anvil add . stages files', PassedTests, TotalTests);
    AssertTrue(FileExists(JoinPaths(TestDir, '.anvil/index')), 'Index file written after add', PassedTests, TotalTests);

    { 5. anvil commit }
    Code := RunCli('commit', ['-m', 'feat: initial project structure']);
    AssertEquals(0, Code, 'anvil commit succeeds', PassedTests, TotalTests);
    AssertTrue(FileExists(JoinPaths(TestDir, '.anvil/refs/heads/main')), 'Branch refs/heads/main exists', PassedTests, TotalTests);

    { 6. anvil branch feature }
    Code := RunCli('branch', ['feature']);
    AssertEquals(0, Code, 'anvil branch feature creates new branch', PassedTests, TotalTests);
    AssertTrue(FileExists(JoinPaths(TestDir, '.anvil/refs/heads/feature')), 'refs/heads/feature created', PassedTests, TotalTests);

    { 7. anvil checkout feature }
    Code := RunCli('checkout', ['feature']);
    AssertEquals(0, Code, 'anvil checkout feature switches branch', PassedTests, TotalTests);

    { 8. Add file in feature branch }
    WriteEntireFileString(JoinPaths(TestDir, 'utils.pas'),
      'unit Utils;'#10 +
      'interface'#10 +
      'procedure Log(const S: string);'#10 +
      'implementation'#10 +
      'procedure Log(const S: string); begin Writeln(S); end;'#10 +
      'end.'#10);

    Code := RunCli('add', ['utils.pas']);
    AssertEquals(0, Code, 'anvil add utils.pas in feature branch', PassedTests, TotalTests);

    Code := RunCli('commit', ['-m', 'feat(utils): add logger utility']);
    AssertEquals(0, Code, 'anvil commit in feature branch succeeds', PassedTests, TotalTests);

    { 9. anvil checkout main }
    Code := RunCli('checkout', ['main']);
    AssertEquals(0, Code, 'anvil checkout main switches back', PassedTests, TotalTests);
    AssertTrue(not FileExists(JoinPaths(TestDir, 'utils.pas')), 'utils.pas not in main working tree', PassedTests, TotalTests);

    { 10. anvil merge feature }
    Code := RunCli('merge', ['feature']);
    AssertEquals(0, Code, 'anvil merge feature succeeds via fast-forward', PassedTests, TotalTests);
    AssertTrue(FileExists(JoinPaths(TestDir, 'utils.pas')), 'utils.pas present after merge', PassedTests, TotalTests);

    { 11. anvil log }
    Code := RunCli('log', ['--oneline']);
    AssertEquals(0, Code, 'anvil log --oneline succeeds', PassedTests, TotalTests);

    { 12. anvil tag v1.0.0 }
    Code := RunCli('tag', ['v1.0.0']);
    AssertEquals(0, Code, 'anvil tag v1.0.0 creates tag', PassedTests, TotalTests);
    AssertTrue(FileExists(JoinPaths(TestDir, '.anvil/refs/tags/v1.0.0')), 'refs/tags/v1.0.0 created', PassedTests, TotalTests);

    { 13. anvil blame app.pas }
    Code := RunCli('blame', ['app.pas']);
    AssertEquals(0, Code, 'anvil blame app.pas succeeds', PassedTests, TotalTests);

    { 14. anvil gc }
    Code := RunCli('gc', []);
    AssertEquals(0, Code, 'anvil gc repacks loose objects', PassedTests, TotalTests);

    { 15. anvil fsck }
    Code := RunCli('fsck', []);
    AssertEquals(0, Code, 'anvil fsck verifies repository integrity', PassedTests, TotalTests);

  finally
    SetCurrentDir(OriginalDir);
    DeleteDirectoryRecursive(TestDir);
  end;
end;

end.
