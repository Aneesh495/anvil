{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Central test suite runner executing all unit, structure, and integration tests.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

program test_runner;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, test_crypto, test_odb, test_index, test_diff, test_merge;

var
  PassedTests, TotalTests: Integer;
begin
  PassedTests := 0;
  TotalTests := 0;

  Writeln('=====================================================');
  Writeln('             ANVIL VERIFICATION SUITE               ');
  Writeln('=====================================================');
  Writeln;

  { Run component suites }
  RunCryptoTests(PassedTests, TotalTests);
  RunOdbTests(PassedTests, TotalTests);
  RunIndexTests(PassedTests, TotalTests);
  RunDiffTests(PassedTests, TotalTests);
  RunMergeTests(PassedTests, TotalTests);

  Writeln;
  Writeln('=====================================================');
  Writeln(Format('Summary: %d / %d tests passed (%.1f%%)', [
    PassedTests, TotalTests, (PassedTests / TotalTests) * 100.0
  ]));
  Writeln('=====================================================');

  if PassedTests < TotalTests then
    Halt(1)
  else
    Halt(0);
end.
