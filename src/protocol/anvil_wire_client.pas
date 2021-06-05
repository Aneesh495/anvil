{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Git smart wire protocol client engine.
  Handles reference discovery, want/have negotiation, sideband packfile receipt,
  bundle installation into local ODB, and push command execution.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_wire_client;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_pack, anvil_pack_writer, anvil_ref, anvil_dag, anvil_pktline, anvil_utils,
  anvil_wire_server;

type
  { Remote discovered reference }
  TRemoteRef = record
    Name: string;
    Id: TObjectId;
  end;
  TRemoteRefArray = array of TRemoteRef;

  { Client operation result }
  TWireClientResult = record
    Success: Boolean;
    ObjectsReceived: Integer;
    BytesTransferred: Int64;
    ErrorMessage: string;
  end;

  { Git smart protocol client }
  TWireClient = class
  private
    FGitDir: string;
    FODB: TObjectDatabase;
    FRefMgr: TRefManager;
    FAlgo: THashAlgorithm;

    function ParseRefAdvertisement(Pkt: TPktLineStream; out Capabilities: string): TRemoteRefArray;
  public
    constructor Create(const AGitDir: string; AODB: TObjectDatabase; ARefMgr: TRefManager;
                       Algo: THashAlgorithm = haSHA1);

    { Discover references advertised by remote server }
    function DiscoverReferences(InStream, OutStream: TStream; out Capabilities: string): TRemoteRefArray;

    { Fetch remote reference into local tracking branch }
    function Fetch(InStream, OutStream: TStream;
                   const RemoteRefName, LocalTrackingRefName: string): TWireClientResult;

    { Push local reference to remote branch }
    function Push(InStream, OutStream: TStream;
                  const LocalRefName, RemoteRefName: string; Force: Boolean = False): TWireClientResult;
  end;

implementation

constructor TWireClient.Create(const AGitDir: string; AODB: TObjectDatabase; ARefMgr: TRefManager;
                               Algo: THashAlgorithm);
begin
  inherited Create;
  FGitDir := AGitDir;
  FODB := AODB;
  FRefMgr := ARefMgr;
  FAlgo := Algo;
end;

function TWireClient.ParseRefAdvertisement(Pkt: TPktLineStream; out Capabilities: string): TRemoteRefArray;
var
  Packet: TPktLine;
  Line: string;
  NullPos, SpacePos: Integer;
  HexStr, RefName: string;
  TargetId: TObjectId;
  Count: Integer;
begin
  Result := nil;
  SetLength(Result, 16);
  Count := 0;
  Capabilities := '';

  while Pkt.ReadPacket(Packet) and (Packet.Kind <> pkFlush) do
  begin
    Line := Packet.Text;
    if Line = '' then Continue;

    { First line contains null-separated capabilities }
    NullPos := Pos(#0, Line);
    if (NullPos > 0) and (Capabilities = '') then
    begin
      Capabilities := Copy(Line, NullPos + 1, Length(Line) - NullPos);
      Line := Copy(Line, 1, NullPos - 1);
    end;

    SpacePos := Pos(' ', Line);
    if SpacePos > 0 then
    begin
      HexStr := Copy(Line, 1, SpacePos - 1);
      RefName := Copy(Line, SpacePos + 1, Length(Line) - SpacePos);

      if TryHexToObjectId(HexStr, TargetId, FAlgo) then
      begin
        if Count >= Length(Result) then
          SetLength(Result, Length(Result) * 2);
        Result[Count].Name := RefName;
        Result[Count].Id := TargetId;
        Inc(Count);
      end;
    end;
  end;

  SetLength(Result, Count);
end;

function TWireClient.DiscoverReferences(InStream, OutStream: TStream; out Capabilities: string): TRemoteRefArray;
var
  InPkt: TPktLineStream;
begin
  InPkt := TPktLineStream.Create(InStream, False);
  try
    Result := ParseRefAdvertisement(InPkt, Capabilities);
  finally
    InPkt.Free;
  end;
end;

function TWireClient.Fetch(InStream, OutStream: TStream;
                           const RemoteRefName, LocalTrackingRefName: string): TWireClientResult;
var
  InPkt, OutPkt: TPktLineStream;
  Caps: string;
  RemoteRefs: TRemoteRefArray;
  I: Integer;
  TargetRemoteId: TObjectId;
  FoundRemote: Boolean;
  LocalId: TObjectId;
  Pkt: TPktLine;
  Channel: Byte;
  TotalBytes: Int64;
  BundleBytes: TByteArray;
  ChecksumHex: string;
  MS: TMemoryStream;
begin
  Result.Success := False;
  Result.ObjectsReceived := 0;
  Result.BytesTransferred := 0;
  Result.ErrorMessage := '';

  InPkt := TPktLineStream.Create(InStream, False);
  OutPkt := TPktLineStream.Create(OutStream, False);
  try
    { 1. Discover remote references }
    RemoteRefs := ParseRefAdvertisement(InPkt, Caps);

    TargetRemoteId := NullObjectId(FAlgo);
    FoundRemote := False;
    for I := 0 to Length(RemoteRefs) - 1 do
    begin
      if (RemoteRefs[I].Name = RemoteRefName) or
         (RemoteRefs[I].Name = 'refs/heads/' + RemoteRefName) then
      begin
        TargetRemoteId := RemoteRefs[I].Id;
        FoundRemote := True;
        Break;
      end;
    end;

    if not FoundRemote then
    begin
      Result.ErrorMessage := 'Remote reference not found: ' + RemoteRefName;
      Exit;
    end;

    { 2. Send want command }
    OutPkt.WriteString('want ' + ObjectIdToHex(TargetRemoteId) + ' ' + Caps);
    OutPkt.WriteFlush;

    { 3. Send have commands if local tracking ref exists }
    if FRefMgr.Resolve(LocalTrackingRefName, LocalId) then
      OutPkt.WriteString('have ' + ObjectIdToHex(LocalId));
    OutPkt.WriteString('done');

    { 4. Read server ACK / NAK }
    if not InPkt.ReadPacket(Pkt) then
    begin
      Result.ErrorMessage := 'Connection closed before server response';
      Exit;
    end;

    { 5. Read incoming sideband-64k packets and buffer bundle }
    MS := TMemoryStream.Create;
    TotalBytes := 0;
    try
      while InPkt.ReadPacket(Pkt) and (Pkt.Kind <> pkFlush) do
      begin
        if Length(Pkt.Payload) > 1 then
        begin
          Channel := Pkt.Payload[0];
          case Channel of
            SIDEBAND_CHANNEL_PACK:
            begin
              MS.WriteBuffer(Pkt.Payload[1], Length(Pkt.Payload) - 1);
              Inc(TotalBytes, Length(Pkt.Payload) - 1);
            end;
            SIDEBAND_CHANNEL_ERROR:
            begin
              Result.ErrorMessage := 'Remote error: ' + Copy(Pkt.Text, 2, Length(Pkt.Text) - 1);
              Exit;
            end;
          end;
        end;
      end;

      SetLength(BundleBytes, MS.Size);
      if MS.Size > 0 then
      begin
        MS.Position := 0;
        MS.ReadBuffer(BundleBytes[0], MS.Size);
      end;
    finally
      MS.Free;
    end;

    Result.BytesTransferred := TotalBytes;

    { 6. Install received bundle into local objects/pack and reload ODB }
    if Length(BundleBytes) >= 8 then
    begin
      if not UnpackBundleToDirectory(FGitDir, BundleBytes, ChecksumHex) then
      begin
        Result.ErrorMessage := 'Failed to unpack bundle payload into repository';
        Exit;
      end;
      FODB.DiscoverPacks;
    end;

    { 7. Update local tracking reference }
    FRefMgr.SetReference(LocalTrackingRefName, TargetRemoteId);
    Result.Success := True;

  finally
    InPkt.Free;
    OutPkt.Free;
  end;
end;

function TWireClient.Push(InStream, OutStream: TStream;
                          const LocalRefName, RemoteRefName: string; Force: Boolean): TWireClientResult;
var
  InPkt, OutPkt: TPktLineStream;
  Caps: string;
  RemoteRefs: TRemoteRefArray;
  I: Integer;
  RemoteOldId, LocalNewId: TObjectId;
  CmdLine: string;
  Walker: TCommitWalker;
  CommitId: TObjectId;
  PackWriter: TPackWriter;
  Visited: TObjectIdMap;
  PackBytes, IdxBytes: TByteArray;
  Pkt: TPktLine;
  Line: string;
  TmpBase, TmpPackPath, TmpIdxPath: string;
  PackChecksum: TObjectId;
  Header: array[0..7] of Byte;
  PackLen, IdxLen: Integer;
begin
  Result.Success := False;
  Result.ObjectsReceived := 0;
  Result.BytesTransferred := 0;
  Result.ErrorMessage := '';

  InPkt := TPktLineStream.Create(InStream, False);
  OutPkt := TPktLineStream.Create(OutStream, False);
  try
    { 1. Discover remote references }
    RemoteRefs := ParseRefAdvertisement(InPkt, Caps);

    RemoteOldId := NullObjectId(FAlgo);
    for I := 0 to Length(RemoteRefs) - 1 do
    begin
      if RemoteRefs[I].Name = RemoteRefName then
      begin
        RemoteOldId := RemoteRefs[I].Id;
        Break;
      end;
    end;

    { 2. Resolve local reference }
    if not FRefMgr.Resolve(LocalRefName, LocalNewId) then
    begin
      Result.ErrorMessage := 'Local reference not found: ' + LocalRefName;
      Exit;
    end;

    { 3. Send push command }
    CmdLine := ObjectIdToHex(RemoteOldId) + ' ' + ObjectIdToHex(LocalNewId) + ' ' + RemoteRefName;
    OutPkt.WriteString(CmdLine);
    OutPkt.WriteFlush;

    { 4. Build bundle of commits reachable from LocalNewId }
    Walker := TCommitWalker.Create(FODB, csoChronological);
    try
      Walker.Push(LocalNewId);
      if not IsNullObjectId(RemoteOldId) then
        Walker.Hide(RemoteOldId);

      PackWriter := TPackWriter.Create(10, 50);
      Visited := TObjectIdMap.Create(1024);
      try
        while Walker.Next(CommitId) do
          CollectCommitReachableObjects(FODB, PackWriter, CommitId, Visited);

        TmpBase := JoinPaths(FGitDir, 'tmp_cli_' + IntToStr(Random(10000000)));
        PackWriter.WritePack(TmpBase, TmpPackPath, TmpIdxPath, PackChecksum);
        try
          PackBytes := ReadEntireFile(TmpPackPath);
          IdxBytes := ReadEntireFile(TmpIdxPath);

          PackLen := Length(PackBytes);
          IdxLen := Length(IdxBytes);

          Header[0] := Byte((PackLen shr 24) and $FF);
          Header[1] := Byte((PackLen shr 16) and $FF);
          Header[2] := Byte((PackLen shr 8) and $FF);
          Header[3] := Byte(PackLen and $FF);

          Header[4] := Byte((IdxLen shr 24) and $FF);
          Header[5] := Byte((IdxLen shr 16) and $FF);
          Header[6] := Byte((IdxLen shr 8) and $FF);
          Header[7] := Byte(IdxLen and $FF);

          OutStream.WriteBuffer(Header[0], 8);
          if PackLen > 0 then
            OutStream.WriteBuffer(PackBytes[0], PackLen);
          if IdxLen > 0 then
            OutStream.WriteBuffer(IdxBytes[0], IdxLen);

          Result.BytesTransferred := 8 + PackLen + IdxLen;
        finally
          if FileExists(TmpPackPath) then DeleteFile(TmpPackPath);
          if FileExists(TmpIdxPath) then DeleteFile(TmpIdxPath);
        end;
      finally
        Visited.Free;
        PackWriter.Free;
      end;
    finally
      Walker.Free;
    end;

    { 5. Read status report from server }
    while InPkt.ReadPacket(Pkt) and (Pkt.Kind <> pkFlush) do
    begin
      Line := Pkt.Text;
      if Copy(Line, 1, 3) = 'ok ' then
      begin
        Result.Success := True;
        Exit;
      end
      else if Copy(Line, 1, 3) = 'ng ' then
      begin
        Result.ErrorMessage := Line;
        Exit;
      end;
    end;

  finally
    InPkt.Free;
    OutPkt.Free;
  end;
end;

end.
