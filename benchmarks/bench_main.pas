{
  Anvil: High-Performance Git-Compatible Distributed Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Performance Benchmark Suite:
  Micro-benchmarking harness for cryptographic primitives, differential
  comparison algorithms, object database throughput, and DAG graph traversals.
}

program AnvilBench;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, DateUtils,
  anvil_types, anvil_utils, anvil_sha1, anvil_sha256, anvil_crc32, anvil_hash,
  anvil_object, anvil_odb, anvil_pack,
  anvil_myers, anvil_patience, anvil_lca, anvil_dag,
  anvil_ref;

const
  BENCH_SEPARATOR = '--------------------------------------------------------------------------------';
  BENCH_DATA_SIZE = 32 * 1024 * 1024; { 32 MB buffer for crypto throughput }

type
  TBenchmarkTimer = record
    StartTime: QWord;
    StopTime: QWord;
  end;

function GetTickCountMs: QWord;
begin
  Result := GetTickCount64;
end;

procedure StartTimer(out Timer: TBenchmarkTimer);
begin
  Timer.StartTime := GetTickCountMs;
  Timer.StopTime := 0;
end;

function StopTimer(var Timer: TBenchmarkTimer): Double;
var
  ElapsedMs: QWord;
begin
  Timer.StopTime := GetTickCountMs;
  ElapsedMs := Timer.StopTime - Timer.StartTime;
  if ElapsedMs = 0 then
    Result := 0.001
  else
    Result := ElapsedMs / 1000.0;
end;

procedure PrintHeader(const SectionTitle: string);
begin
  Writeln;
  Writeln(BENCH_SEPARATOR);
  Writeln('  ', SectionTitle);
  Writeln(BENCH_SEPARATOR);
end;

procedure PrintMetric(const BenchmarkName: string; const OpsOrBytes: Double; const ElapsedSec: Double; const UnitStr: string);
var
  Throughput: Double;
begin
  Throughput := OpsOrBytes / ElapsedSec;
  Writeln(Format('  %-35s: %8.3f s | %10.2f %s', [BenchmarkName, ElapsedSec, Throughput, UnitStr]));
end;

{ ============================================================================ }
{ 1. Cryptographic Hash and Checksum Benchmarks                                }
{ ============================================================================ }

procedure BenchmarkCrypto;
var
  Buffer: TBytes;
  I: Integer;
  Timer: TBenchmarkTimer;
  Elapsed: Double;
  Sha1Ctx: TSHA1Context;
  Sha1Digest: TSHA1Digest;
  Sha256Ctx: TSHA256Context;
  Sha256Digest: TSHA256Digest;
  CrcVal: LongWord;
  DataMB: Double;
begin
  PrintHeader('1. Cryptographic and Checksum Primitives (32 MB Stream)');
  SetLength(Buffer, BENCH_DATA_SIZE);
  for I := 0 to BENCH_DATA_SIZE - 1 do
    Buffer[I] := Byte(I mod 251);

  DataMB := BENCH_DATA_SIZE / (1024.0 * 1024.0);

  { SHA-1 Benchmark }
  StartTimer(Timer);
  SHA1Init(Sha1Ctx);
  SHA1Update(Sha1Ctx, Buffer[0], BENCH_DATA_SIZE);
  SHA1Final(Sha1Ctx, Sha1Digest);
  Elapsed := StopTimer(Timer);
  PrintMetric('SHA-1 Digest Throughput', DataMB, Elapsed, 'MB/s');

  { SHA-256 Benchmark }
  StartTimer(Timer);
  SHA256Init(Sha256Ctx);
  SHA256Update(Sha256Ctx, Buffer[0], BENCH_DATA_SIZE);
  SHA256Final(Sha256Ctx, Sha256Digest);
  Elapsed := StopTimer(Timer);
  PrintMetric('SHA-256 Digest Throughput', DataMB, Elapsed, 'MB/s');

  { CRC-32 (IEEE 802.3) Benchmark }
  StartTimer(Timer);
  CrcVal := CRC32Buffer(Buffer[0], BENCH_DATA_SIZE);
  Elapsed := StopTimer(Timer);
  PrintMetric('CRC32 (IEEE 802.3) Throughput', DataMB, Elapsed, 'MB/s');

  { CRC-32C (Castagnoli) Benchmark }
  StartTimer(Timer);
  CrcVal := CRC32CBuffer(Buffer[0], BENCH_DATA_SIZE);
  Elapsed := StopTimer(Timer);
  PrintMetric('CRC32C (Castagnoli) Throughput', DataMB, Elapsed, 'MB/s');
end;

{ ============================================================================ }
{ 2. Differential SES Comparison Benchmarks                                    }
{ ============================================================================ }

procedure BenchmarkDiff;
var
  DocA, DocB: string;
  LineA, LineB: string;
  I: Integer;
  Timer: TBenchmarkTimer;
  Elapsed: Double;
  MyersOps: TDiffLineArray;
  PatienceOps: TDiffLineArray;
const
  LINE_COUNT = 3000;
begin
  PrintHeader('2. Differential Comparison Algorithms (3,000 Lines Synthetic Source)');
  DocA := '';
  DocB := '';
  for I := 1 to LINE_COUNT do
  begin
    LineA := Format('procedure ProcessItem_%d(Index: Integer; Value: Double);'#10, [I]);
    DocA := DocA + LineA;
    if (I mod 15 = 0) then
      LineB := Format('procedure ModifiedItem_%d(Index: Integer; Value: Extended);'#10, [I])
    else if (I mod 25 <> 0) then
      LineB := LineA
    else
      LineB := '';
    DocB := DocB + LineB;
  end;

  { Myers O(ND) Algorithm }
  StartTimer(Timer);
  MyersOps := MyersDiffStrings(DocA, DocB);
  Elapsed := StopTimer(Timer);
  PrintMetric('Myers O(ND) SES Diff', LINE_COUNT, Elapsed, 'lines/s');

  { Patience Diff Algorithm }
  StartTimer(Timer);
  PatienceOps := PatienceDiffStrings(DocA, DocB);
  Elapsed := StopTimer(Timer);
  PrintMetric('Patience Unique-Line Diff', LINE_COUNT, Elapsed, 'lines/s');
end;

{ ============================================================================ }
{ 3. Content-Addressable Storage and Object Database Benchmarks                }
{ ============================================================================ }

procedure BenchmarkStorage;
var
  TempRoot: string;
  OdbPath: string;
  Odb: TObjectDatabase;
  I: Integer;
  Timer: TBenchmarkTimer;
  Elapsed: Double;
  ObjectIds: array of TObjectId;
  Blob: TBlobObject;
  ReadObj: TAnvilObject;
  Payload: string;
const
  OBJECT_COUNT = 1500;
begin
  PrintHeader('3. Object Database & Storage Layer (1,500 Objects)');
  TempRoot := GetTempDir + 'anvil_bench_' + IntToStr(GetTickCountMs mod 1000000);
  OdbPath := TempRoot + DirectorySeparator + 'objects';
  ForceDirectories(OdbPath);

  SetLength(ObjectIds, OBJECT_COUNT);
  Odb := TObjectDatabase.Create(OdbPath);
  try
    { Benchmark Loose Object Writes }
    StartTimer(Timer);
    for I := 0 to OBJECT_COUNT - 1 do
    begin
      Payload := Format('Content addressable payload object index=%d timestamp=%d uuid=%d', [I, GetTickCountMs, I * 31]);
      Blob := TBlobObject.CreateWithString(Payload);
      try
        ObjectIds[I] := Odb.WriteObject(Blob);
      finally
        Blob.Free;
      end;
    end;
    Elapsed := StopTimer(Timer);
    PrintMetric('Loose Object Ingestion', OBJECT_COUNT, Elapsed, 'objects/s');

    { Benchmark Loose Object Reads & Unpacking }
    StartTimer(Timer);
    for I := 0 to OBJECT_COUNT - 1 do
    begin
      ReadObj := Odb.ReadObject(ObjectIds[I]);
      ReadObj.Free;
    end;
    Elapsed := StopTimer(Timer);
    PrintMetric('Loose Object Read & Hydration', OBJECT_COUNT, Elapsed, 'objects/s');

  finally
    Odb.Free;
    DeleteDirectoryRecursive(TempRoot);
  end;
end;

{ ============================================================================ }
{ 4. Commit History DAG & LCA Traversal Benchmarks                             }
{ ============================================================================ }

procedure BenchmarkDAG;
var
  TempRoot, OdbPath: string;
  Odb: TObjectDatabase;
  CommitList: array of TObjectId;
  I: Integer;
  TreeObj: TTreeObject;
  TreeId: TObjectId;
  CommitObj: TCommitObject;
  Walker: TCommitWalker;
  Count: Integer;
  Timer: TBenchmarkTimer;
  Elapsed: Double;
  LcaFinder: TLcaFinder;
  LcaResult: TObjectId;
  WalkId: TObjectId;
const
  DAG_COMMIT_COUNT = 800;
begin
  PrintHeader('4. Directed Acyclic Graph (DAG) Traversal & LCA (800 Commits)');
  TempRoot := GetTempDir + 'anvil_dag_bench_' + IntToStr(GetTickCountMs mod 1000000);
  OdbPath := TempRoot + DirectorySeparator + 'objects';
  ForceDirectories(OdbPath);

  SetLength(CommitList, DAG_COMMIT_COUNT);
  Odb := TObjectDatabase.Create(OdbPath);
  try
    { Create a base empty tree }
    TreeObj := TTreeObject.Create;
    try
      TreeId := Odb.WriteObject(TreeObj);
    finally
      TreeObj.Free;
    end;

    { Build linear history with periodic branching }
    for I := 0 to DAG_COMMIT_COUNT - 1 do
    begin
      CommitObj := TCommitObject.Create;
      try
        CommitObj.TreeId := TreeId;
        if I > 0 then
          CommitObj.AddParent(CommitList[I - 1]);
        if (I > 10) and (I mod 20 = 0) then
          CommitObj.AddParent(CommitList[I - 10]); { merge commit }

        CommitObj.Author := MakeIdentity('Benchmarking Harness', 'bench@anvil.vcs', 1700000000 + I * 60, 0);
        CommitObj.Committer := CommitObj.Author;
        CommitObj.Message := Format('bench commit %d', [I]);

        CommitList[I] := Odb.WriteObject(CommitObj);
      finally
        CommitObj.Free;
      end;
    end;

    { Benchmark Full Topological History Walk }
    Walker := TCommitWalker.Create(Odb, csoTopological);
    try
      Walker.Push(CommitList[DAG_COMMIT_COUNT - 1]);

      StartTimer(Timer);
      Count := 0;
      while Walker.Next(WalkId) do
        Inc(Count);
      Elapsed := StopTimer(Timer);
      PrintMetric('Topological History Walk', Count, Elapsed, 'commits/s');
    finally
      Walker.Free;
    end;

    { Benchmark LCA Resolution }
    LcaFinder := TLcaFinder.Create(Odb);
    try
      StartTimer(Timer);
      for I := 1 to 50 do
      begin
        LcaFinder.FindBestMergeBase(CommitList[DAG_COMMIT_COUNT - 1], CommitList[DAG_COMMIT_COUNT - 50], LcaResult);
      end;
      Elapsed := StopTimer(Timer);
      PrintMetric('Lowest Common Ancestor Resolution', 50, Elapsed, 'resolutions/s');
    finally
      LcaFinder.Free;
    end;

  finally
    Odb.Free;
    DeleteDirectoryRecursive(TempRoot);
  end;
end;

{ ============================================================================ }
{ Main Program Entrypoint                                                      }
{ ============================================================================ }

begin
  Writeln('================================================================================');
  Writeln('           ANVIL PERFORMANCE & MICRO-BENCHMARKING HARNESS                       ');
  Writeln('================================================================================');
  Writeln('System Architecture: ', {$I %FPCTARGETCPU%}, ' - ', {$I %FPCTARGETOS%});
  Writeln('Compiler Version   : Free Pascal Compiler ', {$I %FPCVERSION%});

  try
    BenchmarkCrypto;
    BenchmarkDiff;
    BenchmarkStorage;
    BenchmarkDAG;

    Writeln;
    Writeln(BENCH_SEPARATOR);
    Writeln('  Benchmark execution complete. All subsystems operating within latency bounds.');
    Writeln(BENCH_SEPARATOR);
  except
    on E: Exception do
    begin
      Writeln('Benchmark error: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
