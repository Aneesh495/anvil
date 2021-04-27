{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Reference log (reflog) management engine.
  Maintains sequential audit logs of branch tip mutations and HEAD movements
  enabling time-travel recovery and relative syntax queries (e.g. HEAD at revision 2).
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_reflog;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_utils;

type
  { Single reflog event entry }
  TReflogEntry = record
    OldId: TObjectId;
    NewId: TObjectId;
    Committer: TIdentity;
    Message: string;
  end;
  TReflogEntryArray = array of TReflogEntry;

  { Reference log manager }
  TReflogManager = class
  private
    FGitDir: string;
    FAlgo: THashAlgorithm;
    function GetReflogFilePath(const RefName: string): string;
    function ParseReflogLine(const Line: string; out Entry: TReflogEntry): Boolean;
    function FormatReflogLine(const Entry: TReflogEntry): string;
  public
    constructor Create(const AGitDir: string; Algo: THashAlgorithm = haSHA1);

    { Append a new transition event to a reference log }
    procedure Append(const RefName: string; const OldId, NewId: TObjectId;
                     const Committer: TIdentity; const Message: string);

    { Read all log entries for a reference (chronological order) }
    function ReadEntries(const RefName: string): TReflogEntryArray;

    { Read relative entry indexed backwards from tip (0 = most recent) }
    function ReadRelative(const RefName: string; StepsBack: Integer; out Entry: TReflogEntry): Boolean;

    { Read entry closest to given epoch timestamp }
    function ReadAtTimestamp(const RefName: string; Timestamp: Int64; out Entry: TReflogEntry): Boolean;

    { Prune entries older than ExpireTimestamp, returns count of pruned entries }
    function Expire(const RefName: string; ExpireTimestamp: Int64): Integer;

    { Delete entire log for a reference }
    function DeleteLog(const RefName: string): Boolean;
  end;

implementation

constructor TReflogManager.Create(const AGitDir: string; Algo: THashAlgorithm);
begin
  inherited Create;
  FGitDir := AGitDir;
  FAlgo := Algo;
end;

function TReflogManager.GetReflogFilePath(const RefName: string): string;
begin
  Result := JoinPaths(JoinPaths(FGitDir, 'logs'), RefName);
end;

function TReflogManager.ParseReflogLine(const Line: string; out Entry: TReflogEntry): Boolean;
var
  Space1, Space2, TabPos: Integer;
  OldHex, NewHex: string;
  IdentPart, MsgPart: string;
begin
  Result := False;
  FillChar(Entry, SizeOf(Entry), 0);

  Space1 := Pos(' ', Line);
  if Space1 <= 0 then Exit;

  OldHex := Copy(Line, 1, Space1 - 1);
  if not TryHexToObjectId(OldHex, Entry.OldId, FAlgo) then Exit;

  Space2 := Pos(' ', Copy(Line, Space1 + 1, Length(Line) - Space1));
  if Space2 <= 0 then Exit;
  Space2 := Space1 + Space2;

  NewHex := Copy(Line, Space1 + 1, Space2 - Space1 - 1);
  if not TryHexToObjectId(NewHex, Entry.NewId, FAlgo) then Exit;

  TabPos := Pos(#9, Line);
  if TabPos > 0 then
  begin
    IdentPart := Copy(Line, Space2 + 1, TabPos - Space2 - 1);
    MsgPart := Copy(Line, TabPos + 1, Length(Line) - TabPos);
  end
  else
  begin
    IdentPart := Copy(Line, Space2 + 1, Length(Line) - Space2);
    MsgPart := '';
  end;

  if not ParseIdentity(IdentPart, Entry.Committer) then Exit;
  Entry.Message := MsgPart;
  Result := True;
end;

function TReflogManager.FormatReflogLine(const Entry: TReflogEntry): string;
begin
  Result := ObjectIdToHex(Entry.OldId) + ' ' +
            ObjectIdToHex(Entry.NewId) + ' ' +
            FormatIdentity(Entry.Committer) + #9 +
            Entry.Message + #10;
end;

procedure TReflogManager.Append(const RefName: string; const OldId, NewId: TObjectId;
                               const Committer: TIdentity; const Message: string);
var
  FilePath, Dir: string;
  Entry: TReflogEntry;
  Line: string;
  FS: TFileStream;
begin
  FilePath := GetReflogFilePath(RefName);
  Dir := ExtractFileDir(FilePath);
  EnsureDirectoryExists(Dir);

  Entry.OldId := OldId;
  Entry.NewId := NewId;
  Entry.Committer := Committer;
  Entry.Message := Message;

  Line := FormatReflogLine(Entry);

  if FileExists(FilePath) then
    FS := TFileStream.Create(FilePath, fmOpenWrite or fmShareDenyWrite)
  else
    FS := TFileStream.Create(FilePath, fmCreate or fmShareDenyWrite);

  try
    FS.Seek(0, soFromEnd);
    if Length(Line) > 0 then
      FS.WriteBuffer(Line[1], Length(Line));
  finally
    FS.Free;
  end;
end;

function TReflogManager.ReadEntries(const RefName: string): TReflogEntryArray;
var
  FilePath: string;
  Content: string;
  Lines: TStringArray;
  I, Count: Integer;
  Entry: TReflogEntry;
begin
  SetLength(Result, 0);
  FilePath := GetReflogFilePath(RefName);
  if not FileExists(FilePath) then
    Exit;

  Content := ReadEntireFileString(FilePath);
  Lines := SplitStringByChar(Content, #10);

  SetLength(Result, Length(Lines));
  Count := 0;

  for I := 0 to Length(Lines) - 1 do
  begin
    if Trim(Lines[I]) <> '' then
    begin
      if ParseReflogLine(Lines[I], Entry) then
      begin
        Result[Count] := Entry;
        Inc(Count);
      end;
    end;
  end;

  SetLength(Result, Count);
end;

function TReflogManager.ReadRelative(const RefName: string; StepsBack: Integer; out Entry: TReflogEntry): Boolean;
var
  Entries: TReflogEntryArray;
  TargetIdx: Integer;
begin
  Result := False;
  FillChar(Entry, SizeOf(Entry), 0);

  Entries := ReadEntries(RefName);
  if Length(Entries) = 0 then
    Exit;

  TargetIdx := Length(Entries) - 1 - StepsBack;
  if (TargetIdx >= 0) and (TargetIdx < Length(Entries)) then
  begin
    Entry := Entries[TargetIdx];
    Result := True;
  end;
end;

function TReflogManager.ReadAtTimestamp(const RefName: string; Timestamp: Int64; out Entry: TReflogEntry): Boolean;
var
  Entries: TReflogEntryArray;
  I, BestIdx: Integer;
  BestDiff, Diff: Int64;
begin
  Result := False;
  FillChar(Entry, SizeOf(Entry), 0);

  Entries := ReadEntries(RefName);
  if Length(Entries) = 0 then
    Exit;

  BestIdx := -1;
  BestDiff := High(Int64);

  for I := 0 to Length(Entries) - 1 do
  begin
    Diff := Abs(Entries[I].Committer.When.Seconds - Timestamp);
    if Diff < BestDiff then
    begin
      BestDiff := Diff;
      BestIdx := I;
    end;
  end;

  if BestIdx >= 0 then
  begin
    Entry := Entries[BestIdx];
    Result := True;
  end;
end;

function TReflogManager.Expire(const RefName: string; ExpireTimestamp: Int64): Integer;
var
  Entries: TReflogEntryArray;
  I: Integer;
  NewContent: string;
  FilePath: string;
begin
  Result := 0;
  Entries := ReadEntries(RefName);
  if Length(Entries) = 0 then
    Exit;

  NewContent := '';
  for I := 0 to Length(Entries) - 1 do
  begin
    if Entries[I].Committer.When.Seconds >= ExpireTimestamp then
      NewContent := NewContent + FormatReflogLine(Entries[I])
    else
      Inc(Result);
  end;

  FilePath := GetReflogFilePath(RefName);
  if NewContent = '' then
    DeleteFile(FilePath)
  else
    WriteEntireFileString(FilePath, NewContent);
end;

function TReflogManager.DeleteLog(const RefName: string): Boolean;
var
  FilePath: string;
begin
  FilePath := GetReflogFilePath(RefName);
  if FileExists(FilePath) then
    Result := DeleteFile(FilePath)
  else
    Result := True;
end;

end.
