{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Unit verification suite for Git smart wire protocol, pkt-line framing,
  sideband-64k multiplexing, and client/server loopback synchronization.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit test_protocol;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_ref, anvil_pktline, anvil_wire_server, anvil_wire_client, anvil_utils;

procedure RunProtocolTests(var PassedTests, TotalTests: Integer);

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

procedure RunProtocolTests(var PassedTests, TotalTests: Integer);
var
  MS: TMemoryStream;
  PktStream: TPktLineStream;
  Pkt: TPktLine;
  S: string;
  RawBytes: array[0..3] of Byte;
  TestServerDir, TestClientDir: string;
  SrvGitDir, CliGitDir: string;
  SrvODB, CliODB: TObjectDatabase;
  SrvRefMgr, CliRefMgr: TRefManager;
  Server: TWireServer;
  Client: TWireClient;
  SrvTree, CliTree: TTreeObject;
  SrvCommit, CliCommit: TCommitObject;
  BlobData: string;
  BlobId, TreeId, CommitId, NewCommitId: TObjectId;
  ClientToSrv, SrvToClient, DummyOut: TMemoryStream;
  ClientRes: TWireClientResult;
  Caps: string;
  DiscoveredRefs: TRemoteRefArray;
  ReadObjType: TObjectType;
  ReadRawData: TByteArray;
  I: Integer;
  FoundMain: Boolean;
begin
  Writeln('=== Running Git Smart Wire Protocol & Pkt-Line Test Suite ===');

  { Test 1: Pkt-line format helper functions }
  S := FormatPktString('hello'#10);
  AssertEqualsStr('000ahello'#10, S, 'FormatPktString produces 4-hex prefixed line', PassedTests, TotalTests);
  AssertEqualsStr('0000', FormatPktFlush, 'FormatPktFlush produces 0000', PassedTests, TotalTests);
  AssertEqualsStr('0001', FormatPktDelim, 'FormatPktDelim produces 0001', PassedTests, TotalTests);

  { Test 2: Pkt-line stream sequential read and write }
  MS := TMemoryStream.Create;
  try
    PktStream := TPktLineStream.Create(MS, False);
    try
      PktStream.WriteString('git-upload-pack /project.git'#0'host=example.com'#0);
      PktStream.WriteFlush;
      PktStream.WriteDelimiter;
      PktStream.WriteResponseEnd;
      PktStream.WriteString('want e0f4b32189d273a749103c80');

      { Rewind stream for reading }
      MS.Position := 0;

      AssertTrue(PktStream.ReadPacket(Pkt), 'ReadPacket reads initial command', PassedTests, TotalTests);
      AssertTrue(Pkt.Kind = pkData, 'Packet kind is pkData', PassedTests, TotalTests);
      AssertEqualsStr('git-upload-pack /project.git'#0'host=example.com'#0, Pkt.Text, 'Command line matches payload', PassedTests, TotalTests);

      AssertTrue(PktStream.ReadPacket(Pkt), 'ReadPacket reads flush packet', PassedTests, TotalTests);
      AssertTrue(Pkt.Kind = pkFlush, 'Packet kind is pkFlush', PassedTests, TotalTests);

      AssertTrue(PktStream.ReadPacket(Pkt), 'ReadPacket reads delimiter packet', PassedTests, TotalTests);
      AssertTrue(Pkt.Kind = pkDelimiter, 'Packet kind is pkDelimiter', PassedTests, TotalTests);

      AssertTrue(PktStream.ReadPacket(Pkt), 'ReadPacket reads response end packet', PassedTests, TotalTests);
      AssertTrue(Pkt.Kind = pkResponseEnd, 'Packet kind is pkResponseEnd', PassedTests, TotalTests);

      AssertTrue(PktStream.ReadPacket(Pkt), 'ReadPacket reads want command', PassedTests, TotalTests);
      AssertEqualsStr('want e0f4b32189d273a749103c80', Pkt.Text, 'Want command text matches', PassedTests, TotalTests);

      AssertTrue(not PktStream.ReadPacket(Pkt), 'ReadPacket at EOF returns False', PassedTests, TotalTests);
    finally
      PktStream.Free;
    end;
  finally
    MS.Free;
  end;

  { Test 3: Sideband-64k encoding and demultiplexing }
  MS := TMemoryStream.Create;
  try
    PktStream := TPktLineStream.Create(MS, False);
    try
      { Channel 1: Packfile payload bytes }
      RawBytes[0] := $50; RawBytes[1] := $41; RawBytes[2] := $43; RawBytes[3] := $4B; { "PACK" }
      PktStream.WriteSideband(SIDEBAND_CHANNEL_PACK, @RawBytes[0], 4);

      { Channel 2: Progress message }
      PktStream.WriteSidebandString(SIDEBAND_CHANNEL_PROGRESS, 'Compressing objects: 100%'#10);

      { Channel 3: Error alert }
      PktStream.WriteSidebandString(SIDEBAND_CHANNEL_ERROR, 'Repository locked'#10);

      MS.Position := 0;

      { Verify channel 1 }
      AssertTrue(PktStream.ReadPacket(Pkt), 'Read sideband packet 1', PassedTests, TotalTests);
      AssertEquals(5, Length(Pkt.Payload), 'Payload has 1-byte channel prefix + 4 bytes data', PassedTests, TotalTests);
      AssertEquals(SIDEBAND_CHANNEL_PACK, Pkt.Payload[0], 'Channel 1 is pack payload', PassedTests, TotalTests);
      AssertEquals(Ord('P'), Pkt.Payload[1], 'Byte 0 is P', PassedTests, TotalTests);
      AssertEquals(Ord('A'), Pkt.Payload[2], 'Byte 1 is A', PassedTests, TotalTests);

      { Verify channel 2 }
      AssertTrue(PktStream.ReadPacket(Pkt), 'Read sideband packet 2', PassedTests, TotalTests);
      AssertEquals(SIDEBAND_CHANNEL_PROGRESS, Pkt.Payload[0], 'Channel 2 is progress message', PassedTests, TotalTests);
      AssertEqualsStr('Compressing objects: 100%', Copy(Pkt.Text, 2, Length(Pkt.Text) - 1), 'Progress text matches', PassedTests, TotalTests);

      { Verify channel 3 }
      AssertTrue(PktStream.ReadPacket(Pkt), 'Read sideband packet 3', PassedTests, TotalTests);
      AssertEquals(SIDEBAND_CHANNEL_ERROR, Pkt.Payload[0], 'Channel 3 is error message', PassedTests, TotalTests);
      AssertEqualsStr('Repository locked', Copy(Pkt.Text, 2, Length(Pkt.Text) - 1), 'Error message matches', PassedTests, TotalTests);
    finally
      PktStream.Free;
    end;
  finally
    MS.Free;
  end;

  { Test 4: Full Loopback Fetch - Server creates commit, Client fetches into tracking ref }
  TestServerDir := '/tmp/anvil_test_srv_' + IntToStr(Random(1000000));
  TestClientDir := '/tmp/anvil_test_cli_' + IntToStr(Random(1000000));
  SrvGitDir := JoinPaths(TestServerDir, '.anvil');
  CliGitDir := JoinPaths(TestClientDir, '.anvil');

  EnsureDirectoryExists(JoinPaths(SrvGitDir, 'objects'));
  EnsureDirectoryExists(JoinPaths(SrvGitDir, 'refs/heads'));
  EnsureDirectoryExists(JoinPaths(CliGitDir, 'objects'));
  EnsureDirectoryExists(JoinPaths(CliGitDir, 'refs/heads'));

  try
    SrvODB := TObjectDatabase.Create(JoinPaths(SrvGitDir, 'objects'), haSHA1);
    SrvRefMgr := TRefManager.Create(SrvGitDir, haSHA1);
    CliODB := TObjectDatabase.Create(JoinPaths(CliGitDir, 'objects'), haSHA1);
    CliRefMgr := TRefManager.Create(CliGitDir, haSHA1);
    try
      { Build sample commit on server }
      BlobData := 'println("Distributed Version Control Engine");'#10;
      BlobId := SrvODB.WriteObjectRaw(otBlob, @BlobData[1], Length(BlobData));

      SrvTree := TTreeObject.Create;
      try
        SrvTree.AddEntry(fmRegular, 'main.pas', BlobId);
        TreeId := SrvODB.WriteObject(SrvTree);
      finally
        SrvTree.Free;
      end;

      SrvCommit := TCommitObject.Create;
      try
        SrvCommit.TreeId := TreeId;
        SrvCommit.Author := MakeIdentity('Aneesh Krishna', 'aneesh@engine.internal', 1700000000, 0);
        SrvCommit.Committer := SrvCommit.Author;
        SrvCommit.Message := 'feat: initial server commit'#10;
        CommitId := SrvODB.WriteObject(SrvCommit);
      finally
        SrvCommit.Free;
      end;

      { Point server HEAD and refs/heads/main to CommitId }
      SrvRefMgr.SetReference('refs/heads/main', CommitId);
      SrvRefMgr.SetSymbolicReference('HEAD', 'refs/heads/main');

      Server := TWireServer.Create(SrvGitDir, SrvODB, SrvRefMgr, haSHA1);
      Client := TWireClient.Create(CliGitDir, CliODB, CliRefMgr, haSHA1);
      try
        { Step 4A: Reference discovery }
        ClientToSrv := TMemoryStream.Create;
        SrvToClient := TMemoryStream.Create;
        try
          Server.ServiceUploadPack(ClientToSrv, SrvToClient);
          SrvToClient.Position := 0;

          DiscoveredRefs := Client.DiscoverReferences(SrvToClient, ClientToSrv, Caps);
          AssertTrue(Length(DiscoveredRefs) > 0, 'Client discovered server advertised references', PassedTests, TotalTests);

          FoundMain := False;
          for I := 0 to Length(DiscoveredRefs) - 1 do
          begin
            if DiscoveredRefs[I].Name = 'refs/heads/main' then
            begin
              FoundMain := True;
              AssertTrue(ObjectIdEqual(CommitId, DiscoveredRefs[I].Id), 'Discovered reference points to CommitId', PassedTests, TotalTests);
            end;
          end;
          AssertTrue(FoundMain, 'Advertised references include refs/heads/main', PassedTests, TotalTests);
        finally
          ClientToSrv.Free;
          SrvToClient.Free;
        end;

        { Step 4B: Client fetches main into refs/remotes/origin/main }
        ClientToSrv := TMemoryStream.Create;
        SrvToClient := TMemoryStream.Create;
        DummyOut := TMemoryStream.Create;
        try
          { Prepare client request with want and done }
          PktStream := TPktLineStream.Create(ClientToSrv, False);
          try
            PktStream.WriteString('want ' + ObjectIdToHex(CommitId));
            PktStream.WriteFlush;
            PktStream.WriteString('done');
            PktStream.WriteFlush;
          finally
            PktStream.Free;
          end;

          { Server executes ServiceUploadPack:
            It writes ref advertisement, reads want/done, writes NAK, writes sideband pack, writes flush }
          ClientToSrv.Position := 0;
          SrvToClient.Size := 0;
          Server.ServiceUploadPack(ClientToSrv, SrvToClient);

          { Client consumes server stream and installs bundle }
          SrvToClient.Position := 0;
          ClientRes := Client.Fetch(SrvToClient, DummyOut, 'main', 'refs/remotes/origin/main');
          AssertTrue(ClientRes.Success, 'Client.Fetch succeeded', PassedTests, TotalTests);
          AssertTrue(ClientRes.BytesTransferred > 0, 'Packfile bytes transferred > 0', PassedTests, TotalTests);

          { Verify client now has the commit and file in its local database }
          AssertTrue(CliODB.Exists(CommitId), 'Commit object exists in client ODB', PassedTests, TotalTests);
          AssertTrue(CliODB.Exists(TreeId), 'Tree object exists in client ODB', PassedTests, TotalTests);
          AssertTrue(CliODB.Exists(BlobId), 'Blob object exists in client ODB', PassedTests, TotalTests);

          { Read blob data from client database }
          AssertTrue(CliODB.ReadObjectRaw(BlobId, ReadObjType, ReadRawData), 'Client read raw blob', PassedTests, TotalTests);
          AssertEquals(Ord(otBlob), Ord(ReadObjType), 'Object type is otBlob', PassedTests, TotalTests);

          { Verify tracking reference was updated }
          AssertTrue(CliRefMgr.Resolve('refs/remotes/origin/main', NewCommitId), 'Tracking ref resolved', PassedTests, TotalTests);
          AssertTrue(ObjectIdEqual(CommitId, NewCommitId), 'Tracking ref points to fetched commit', PassedTests, TotalTests);

        finally
          ClientToSrv.Free;
          SrvToClient.Free;
          DummyOut.Free;
        end;

        { Step 4C: Full Loopback Push - Client creates new commit and pushes to server }
        BlobData := 'const ENGINE_VERSION = "1.0.0";'#10;
        BlobId := CliODB.WriteObjectRaw(otBlob, @BlobData[1], Length(BlobData));

        CliTree := TTreeObject.Create;
        try
          CliTree.AddEntry(fmRegular, 'version.pas', BlobId);
          TreeId := CliODB.WriteObject(CliTree);
        finally
          CliTree.Free;
        end;

        CliCommit := TCommitObject.Create;
        try
          CliCommit.TreeId := TreeId;
          CliCommit.AddParent(CommitId);
          CliCommit.Author := MakeIdentity('Aneesh Krishna', 'aneesh@engine.internal', 1700000100, 0);
          CliCommit.Committer := CliCommit.Author;
          CliCommit.Message := 'feat(client): add version header'#10;
          NewCommitId := CliODB.WriteObject(CliCommit);
        finally
          CliCommit.Free;
        end;

        CliRefMgr.SetReference('refs/heads/feature', NewCommitId);

        { Phase 1: Server advertises its refs into SrvToClient }
        ClientToSrv := TMemoryStream.Create;
        SrvToClient := TMemoryStream.Create;
        try
          Server.ServiceReceivePack(ClientToSrv, SrvToClient);

          { Phase 2: Client consumes advertisement, prepares push commands + bundle to ClientToSrv }
          SrvToClient.Position := 0;
          ClientToSrv.Size := 0;
          ClientRes := Client.Push(SrvToClient, ClientToSrv, 'refs/heads/feature', 'refs/heads/feature');
          AssertTrue(ClientRes.BytesTransferred > 0, 'Pushed bundle bytes transferred > 0', PassedTests, TotalTests);

          { Phase 3: Server executes receive pack, reading commands + bundle from ClientToSrv }
          ClientToSrv.Position := 0;
          SrvToClient.Size := 0;
          Server.ServiceReceivePack(ClientToSrv, SrvToClient);

          { Phase 4: Verify server received everything }
          AssertTrue(SrvODB.Exists(NewCommitId), 'Server ODB has pushed commit', PassedTests, TotalTests);
          AssertTrue(SrvODB.Exists(TreeId), 'Server ODB has pushed tree', PassedTests, TotalTests);
          AssertTrue(SrvODB.Exists(BlobId), 'Server ODB has pushed blob', PassedTests, TotalTests);

          AssertTrue(SrvRefMgr.Resolve('refs/heads/feature', CommitId), 'Server resolved pushed branch', PassedTests, TotalTests);
          AssertTrue(ObjectIdEqual(NewCommitId, CommitId), 'Server branch matches pushed commit ID', PassedTests, TotalTests);

        finally
          ClientToSrv.Free;
          SrvToClient.Free;
        end;

      finally
        Server.Free;
        Client.Free;
      end;
    finally
      SrvODB.Free;
      SrvRefMgr.Free;
      CliODB.Free;
      CliRefMgr.Free;
    end;
  finally
    DeleteDirectoryRecursive(TestServerDir);
    DeleteDirectoryRecursive(TestClientDir);
  end;
end;

end.
