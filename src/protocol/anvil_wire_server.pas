{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Git smart wire protocol server daemon engine.
  Implements git-upload-pack (clone/fetch server) and git-receive-pack (push server)
  with reference advertisement, want/have negotiation, and sideband-64k streaming.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_wire_server;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_pack, anvil_pack_writer, anvil_ref, anvil_dag, anvil_pktline, anvil_utils;

const
  SERVER_CAPABILITIES = 'multi_ack thin-pack side-band-64k ofs-delta agent=anvil/1.0';

type
  { Remote reference command during push }
  TPushCommand = record
    OldId: TObjectId;
    NewId: TObjectId;
    RefName: string;
    StatusOk: Boolean;
    ErrorMessage: string;
  end;
  TPushCommandArray = array of TPushCommand;

  { Git smart protocol server }
  TWireServer = class
  private
    FGitDir: string;
    FODB: TObjectDatabase;
    FRefMgr: TRefManager;
    FAlgo: THashAlgorithm;

    procedure AdvertiseRefs(Pkt: TPktLineStream; ForPush: Boolean);
    function ParseCommandLine(const Line: string; out Cmd: TPushCommand): Boolean;
    procedure StreamBundleOverSideband(Pkt: TPktLineStream; const PackData, IdxData: TByteArray);
  public
    constructor Create(const AGitDir: string; AODB: TObjectDatabase; ARefMgr: TRefManager;
                       Algo: THashAlgorithm = haSHA1);

    { Execute git-upload-pack service: handles clone and fetch requests }
    procedure ServiceUploadPack(InStream, OutStream: TStream);

    { Execute git-receive-pack service: handles push requests }
    procedure ServiceReceivePack(InStream, OutStream: TStream);
  end;

{ Helper routines for collecting reachable objects and extracting wire bundles }
procedure CollectTreeReachableObjects(Odb: TObjectDatabase; PackWriter: TPackWriter;
                                     const TreeId: TObjectId; Visited: TObjectIdMap);
procedure CollectCommitReachableObjects(Odb: TObjectDatabase; PackWriter: TPackWriter;
                                       const CommitId: TObjectId; Visited: TObjectIdMap);
function UnpackBundleToDirectory(const GitDir: string; const BundleBytes: TByteArray;
                                 out ChecksumHex: string): Boolean;

implementation

function BytesToHex(P: PByte; Len: Integer): string;
const
  HexChars: array[0..15] of Char = '0123456789abcdef';
var
  I: Integer;
begin
  SetLength(Result, Len * 2);
  for I := 0 to Len - 1 do
  begin
    Result[I * 2 + 1] := HexChars[(P[I] shr 4) and $0F];
    Result[I * 2 + 2] := HexChars[P[I] and $0F];
  end;
end;

{ Tree traversal for object database packing }
procedure CollectTreeReachableObjects(Odb: TObjectDatabase; PackWriter: TPackWriter;
                                     const TreeId: TObjectId; Visited: TObjectIdMap);
var
  RawData: TByteArray;
  ObjType: TObjectType;
  TreeObj: TTreeObject;
  I: Integer;
  Entry: TTreeEntry;
  Dummy: Pointer;
begin
  if IsNullObjectId(TreeId) then Exit;
  if Visited.Find(TreeId, Dummy) then Exit;
  Visited.Put(TreeId, Pointer(1));

  if not Odb.ReadObjectRaw(TreeId, ObjType, RawData) then Exit;
  PackWriter.AddObject(TreeId, ObjType, @RawData[0], Length(RawData));

  TreeObj := TTreeObject.Create;
  try
    TreeObj.Deserialize(@RawData[0], Length(RawData), Odb.Algorithm);
    for I := 0 to TreeObj.Count - 1 do
    begin
      Entry := TreeObj.GetEntry(I);
      if Visited.Find(Entry.Id, Dummy) then Continue;

      if Entry.Mode = fmDirectory then
        CollectTreeReachableObjects(Odb, PackWriter, Entry.Id, Visited)
      else
      begin
        Visited.Put(Entry.Id, Pointer(1));
        if Odb.ReadObjectRaw(Entry.Id, ObjType, RawData) then
          PackWriter.AddObject(Entry.Id, ObjType, @RawData[0], Length(RawData));
      end;
    end;
  finally
    TreeObj.Free;
  end;
end;

{ Commit and DAG reachability traversal for pack generation }
procedure CollectCommitReachableObjects(Odb: TObjectDatabase; PackWriter: TPackWriter;
                                       const CommitId: TObjectId; Visited: TObjectIdMap);
var
  RawData: TByteArray;
  ObjType: TObjectType;
  CommitObj: TCommitObject;
  Dummy: Pointer;
begin
  if IsNullObjectId(CommitId) then Exit;
  if Visited.Find(CommitId, Dummy) then Exit;
  Visited.Put(CommitId, Pointer(1));

  if not Odb.ReadObjectRaw(CommitId, ObjType, RawData) then Exit;
  PackWriter.AddObject(CommitId, ObjType, @RawData[0], Length(RawData));

  CommitObj := TCommitObject.Create;
  try
    CommitObj.Deserialize(@RawData[0], Length(RawData));
    CollectTreeReachableObjects(Odb, PackWriter, CommitObj.TreeId, Visited);
  finally
    CommitObj.Free;
  end;
end;

{ Unpack wire bundle payload into .pack and .idx files within objects/pack }
function UnpackBundleToDirectory(const GitDir: string; const BundleBytes: TByteArray;
                                 out ChecksumHex: string): Boolean;
var
  PackLen, IdxLen: Integer;
  PackBytes, IdxBytes: TByteArray;
  PackDir, PackPath, IdxPath: string;
  FS: TFileStream;
begin
  Result := False;
  ChecksumHex := '';
  if Length(BundleBytes) < 8 then Exit;

  PackLen := (Integer(BundleBytes[0]) shl 24) or (Integer(BundleBytes[1]) shl 16) or
             (Integer(BundleBytes[2]) shl 8) or Integer(BundleBytes[3]);
  IdxLen := (Integer(BundleBytes[4]) shl 24) or (Integer(BundleBytes[5]) shl 16) or
            (Integer(BundleBytes[6]) shl 8) or Integer(BundleBytes[7]);

  if Length(BundleBytes) < 8 + PackLen + IdxLen then Exit;

  SetLength(PackBytes, PackLen);
  if PackLen > 0 then
    Move(BundleBytes[8], PackBytes[0], PackLen);

  SetLength(IdxBytes, IdxLen);
  if IdxLen > 0 then
    Move(BundleBytes[8 + PackLen], IdxBytes[0], IdxLen);

  { Extract trailing 20-byte pack SHA-1 for canonical pack naming }
  if PackLen >= 20 then
    ChecksumHex := BytesToHex(@PackBytes[PackLen - 20], 20)
  else
    ChecksumHex := IntToStr(Random(1000000));

  PackDir := JoinPaths(GitDir, JoinPaths('objects', 'pack'));
  EnsureDirectoryExists(PackDir);

  PackPath := JoinPaths(PackDir, 'pack-' + ChecksumHex + '.pack');
  IdxPath := JoinPaths(PackDir, 'pack-' + ChecksumHex + '.idx');

  if PackLen > 0 then
  begin
    FS := TFileStream.Create(PackPath, fmCreate);
    try
      FS.WriteBuffer(PackBytes[0], PackLen);
    finally
      FS.Free;
    end;
  end;

  if IdxLen > 0 then
  begin
    FS := TFileStream.Create(IdxPath, fmCreate);
    try
      FS.WriteBuffer(IdxBytes[0], IdxLen);
    finally
      FS.Free;
    end;
  end;

  Result := True;
end;

constructor TWireServer.Create(const AGitDir: string; AODB: TObjectDatabase; ARefMgr: TRefManager;
                               Algo: THashAlgorithm);
begin
  inherited Create;
  FGitDir := AGitDir;
  FODB := AODB;
  FRefMgr := ARefMgr;
  FAlgo := Algo;
end;

procedure TWireServer.AdvertiseRefs(Pkt: TPktLineStream; ForPush: Boolean);
var
  RefList: TStringArray;
  I: Integer;
  RefName: string;
  TargetId, HeadId: TObjectId;
  FirstLine: Boolean;
  Line: string;
begin
  FirstLine := True;
  RefList := FRefMgr.ListReferences('');

  { Determine HEAD target }
  if FRefMgr.Resolve('HEAD', HeadId) then
  begin
    Line := ObjectIdToHex(HeadId) + ' HEAD' + #0 + SERVER_CAPABILITIES;
    Pkt.WriteString(Line);
    FirstLine := False;
  end;

  for I := 0 to Length(RefList) - 1 do
  begin
    RefName := RefList[I];
    if RefName = 'HEAD' then Continue;

    if FRefMgr.Resolve(RefName, TargetId) then
    begin
      if FirstLine then
      begin
        Line := ObjectIdToHex(TargetId) + ' ' + RefName + #0 + SERVER_CAPABILITIES;
        FirstLine := False;
      end
      else
        Line := ObjectIdToHex(TargetId) + ' ' + RefName;

      Pkt.WriteString(Line);
    end;
  end;

  if FirstLine then
  begin
    { Empty repository advertisement }
    Pkt.WriteString(ObjectIdToHex(NullObjectId(FAlgo)) + ' capabilities^{}' + #0 + SERVER_CAPABILITIES);
  end;

  Pkt.WriteFlush;
end;

function TWireServer.ParseCommandLine(const Line: string; out Cmd: TPushCommand): Boolean;
var
  Space1, Space2: Integer;
  OldHex, NewHex: string;
begin
  Result := False;
  FillChar(Cmd, SizeOf(Cmd), 0);

  Space1 := Pos(' ', Line);
  if Space1 <= 0 then Exit;

  OldHex := Copy(Line, 1, Space1 - 1);
  if not TryHexToObjectId(OldHex, Cmd.OldId, FAlgo) then Exit;

  Space2 := Pos(' ', Copy(Line, Space1 + 1, Length(Line) - Space1));
  if Space2 <= 0 then Exit;
  Space2 := Space1 + Space2;

  NewHex := Copy(Line, Space1 + 1, Space2 - Space1 - 1);
  if not TryHexToObjectId(NewHex, Cmd.NewId, FAlgo) then Exit;

  Cmd.RefName := Copy(Line, Space2 + 1, Length(Line) - Space2);
  Cmd.StatusOk := True;
  Cmd.ErrorMessage := '';
  Result := True;
end;

procedure TWireServer.StreamBundleOverSideband(Pkt: TPktLineStream; const PackData, IdxData: TByteArray);
var
  TotalLen, Sent: Integer;
  ChunkSize: Integer;
  Header: array[0..7] of Byte;
  Combined: TByteArray;
  PackLen, IdxLen: Integer;
begin
  PackLen := Length(PackData);
  IdxLen := Length(IdxData);
  SetLength(Combined, 8 + PackLen + IdxLen);

  Header[0] := Byte((PackLen shr 24) and $FF);
  Header[1] := Byte((PackLen shr 16) and $FF);
  Header[2] := Byte((PackLen shr 8) and $FF);
  Header[3] := Byte(PackLen and $FF);

  Header[4] := Byte((IdxLen shr 24) and $FF);
  Header[5] := Byte((IdxLen shr 16) and $FF);
  Header[6] := Byte((IdxLen shr 8) and $FF);
  Header[7] := Byte(IdxLen and $FF);

  Move(Header[0], Combined[0], 8);
  if PackLen > 0 then
    Move(PackData[0], Combined[8], PackLen);
  if IdxLen > 0 then
    Move(IdxData[0], Combined[8 + PackLen], IdxLen);

  Pkt.WriteSidebandString(SIDEBAND_CHANNEL_PROGRESS, 'Counting objects: 100%'#10);
  Pkt.WriteSidebandString(SIDEBAND_CHANNEL_PROGRESS, 'Compressing objects: 100%'#10);

  TotalLen := Length(Combined);
  Sent := 0;

  while Sent < TotalLen do
  begin
    ChunkSize := TotalLen - Sent;
    if ChunkSize > 65500 then
      ChunkSize := 65500;

    Pkt.WriteSideband(SIDEBAND_CHANNEL_PACK, @Combined[Sent], ChunkSize);
    Inc(Sent, ChunkSize);
  end;

  Pkt.WriteSidebandString(SIDEBAND_CHANNEL_PROGRESS, Format('Total %d bytes transmitted'#10, [TotalLen]));
end;

procedure TWireServer.ServiceUploadPack(InStream, OutStream: TStream);
var
  InPkt, OutPkt: TPktLineStream;
  Pkt: TPktLine;
  WantIds, HaveIds: TObjectIdArray;
  TargetId: TObjectId;
  Line: string;
  SpacePos: Integer;
  Walker: TCommitWalker;
  CommitId: TObjectId;
  PackWriter: TPackWriter;
  Visited: TObjectIdMap;
  PackBytes, IdxBytes: TByteArray;
  I: Integer;
  HasCommon: Boolean;
  TmpBase, TmpPackPath, TmpIdxPath: string;
  PackChecksum: TObjectId;
begin
  InPkt := TPktLineStream.Create(InStream, False);
  OutPkt := TPktLineStream.Create(OutStream, False);
  try
    { 1. Advertise references }
    AdvertiseRefs(OutPkt, False);

    { 2. Read want commands }
    SetLength(WantIds, 0);
    while InPkt.ReadPacket(Pkt) and (Pkt.Kind <> pkFlush) do
    begin
      Line := Pkt.Text;
      if Copy(Line, 1, 5) = 'want ' then
      begin
        SpacePos := Pos(' ', Copy(Line, 6, Length(Line) - 5));
        if SpacePos > 0 then
          Line := Copy(Line, 6, SpacePos - 1)
        else
          Line := Copy(Line, 6, Length(Line) - 5);

        if TryHexToObjectId(Line, TargetId, FAlgo) then
        begin
          SetLength(WantIds, Length(WantIds) + 1);
          WantIds[Length(WantIds) - 1] := TargetId;
        end;
      end;
    end;

    if Length(WantIds) = 0 then
      Exit; { Nothing wanted }

    { 3. Read have commands }
    SetLength(HaveIds, 0);
    while InPkt.ReadPacket(Pkt) and (Pkt.Kind <> pkFlush) do
    begin
      Line := Pkt.Text;
      if Copy(Line, 1, 5) = 'have ' then
      begin
        if TryHexToObjectId(Copy(Line, 6, Length(Line) - 5), TargetId, FAlgo) then
        begin
          SetLength(HaveIds, Length(HaveIds) + 1);
          HaveIds[Length(HaveIds) - 1] := TargetId;
        end;
      end
      else if Line = 'done' then
        Break;
    end;

    { 4. Acknowledge common objects }
    HasCommon := Length(HaveIds) > 0;
    if HasCommon then
      OutPkt.WriteString('ACK ' + ObjectIdToHex(HaveIds[0]))
    else
      OutPkt.WriteString('NAK');

    { 5. Determine objects to send and build packfile }
    Walker := TCommitWalker.Create(FODB, csoChronological);
    try
      for I := 0 to Length(WantIds) - 1 do
        Walker.Push(WantIds[I]);
      for I := 0 to Length(HaveIds) - 1 do
        Walker.Hide(HaveIds[I]);

      PackWriter := TPackWriter.Create(10, 50);
      Visited := TObjectIdMap.Create(1024);
      try
        while Walker.Next(CommitId) do
          CollectCommitReachableObjects(FODB, PackWriter, CommitId, Visited);

        TmpBase := JoinPaths(FGitDir, 'tmp_srv_' + IntToStr(Random(10000000)));
        PackWriter.WritePack(TmpBase, TmpPackPath, TmpIdxPath, PackChecksum);
        try
          PackBytes := ReadEntireFile(TmpPackPath);
          IdxBytes := ReadEntireFile(TmpIdxPath);
          StreamBundleOverSideband(OutPkt, PackBytes, IdxBytes);
          OutPkt.WriteFlush;
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

  finally
    InPkt.Free;
    OutPkt.Free;
  end;
end;

procedure TWireServer.ServiceReceivePack(InStream, OutStream: TStream);
var
  InPkt, OutPkt: TPktLineStream;
  Pkt: TPktLine;
  Commands: TPushCommandArray;
  CmdCount: Integer;
  Cmd: TPushCommand;
  I: Integer;
  ExistingId: TObjectId;
  Line: string;
  BundleBytes: TByteArray;
  ChecksumHex: string;
  Buf: array[0..8191] of Byte;
  BytesRead: Integer;
  MS: TMemoryStream;
begin
  InPkt := TPktLineStream.Create(InStream, False);
  OutPkt := TPktLineStream.Create(OutStream, False);
  try
    { 1. Advertise references }
    AdvertiseRefs(OutPkt, True);

    { 2. Read push commands }
    SetLength(Commands, 8);
    CmdCount := 0;

    while InPkt.ReadPacket(Pkt) and (Pkt.Kind <> pkFlush) do
    begin
      Line := Pkt.Text;
      if ParseCommandLine(Line, Cmd) then
      begin
        if CmdCount >= Length(Commands) then
          SetLength(Commands, Length(Commands) * 2);
        Commands[CmdCount] := Cmd;
        Inc(CmdCount);
      end;
    end;

    if CmdCount = 0 then
      Exit;

    { 3. Read incoming bundle stream }
    MS := TMemoryStream.Create;
    try
      repeat
        BytesRead := InStream.Read(Buf[0], SizeOf(Buf));
        if BytesRead > 0 then
          MS.WriteBuffer(Buf[0], BytesRead);
      until BytesRead = 0;

      SetLength(BundleBytes, MS.Size);
      if MS.Size > 0 then
      begin
        MS.Position := 0;
        MS.ReadBuffer(BundleBytes[0], MS.Size);
      end;
    finally
      MS.Free;
    end;

    { 4. If bundle was provided, unpack into objects/pack and reload ODB }
    if Length(BundleBytes) >= 8 then
    begin
      if UnpackBundleToDirectory(FGitDir, BundleBytes, ChecksumHex) then
        FODB.DiscoverPacks
      else
      begin
        for I := 0 to CmdCount - 1 do
        begin
          Commands[I].StatusOk := False;
          Commands[I].ErrorMessage := 'Corrupt or incomplete wire bundle payload';
        end;
      end;
    end;

    { 5. Execute reference updates }
    for I := 0 to CmdCount - 1 do
    begin
      if not Commands[I].StatusOk then Continue;

      { Verify expected old ID }
      if not IsNullObjectId(Commands[I].OldId) then
      begin
        if not FRefMgr.Resolve(Commands[I].RefName, ExistingId) or
           not ObjectIdEqual(ExistingId, Commands[I].OldId) then
        begin
          Commands[I].StatusOk := False;
          Commands[I].ErrorMessage := 'Non-fast-forward or reference mismatch';
          Continue;
        end;
      end;

      { Delete or update reference }
      if IsNullObjectId(Commands[I].NewId) then
        FRefMgr.DeleteReference(Commands[I].RefName)
      else
        FRefMgr.SetReference(Commands[I].RefName, Commands[I].NewId);
    end;

    { 6. Report status back to client }
    OutPkt.WriteString('unpack ok');
    for I := 0 to CmdCount - 1 do
    begin
      if Commands[I].StatusOk then
        OutPkt.WriteString('ok ' + Commands[I].RefName)
      else
        OutPkt.WriteString('ng ' + Commands[I].RefName + ' ' + Commands[I].ErrorMessage);
    end;
    OutPkt.WriteFlush;

  finally
    InPkt.Free;
    OutPkt.Free;
  end;
end;

end.
