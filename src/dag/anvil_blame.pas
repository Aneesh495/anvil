{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Line-by-line blame provenance tracker.
  Walks commit history backwards and uses Myers difference analysis to attribute
  each line of a source file to the exact commit, author, and timestamp that introduced it.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_blame;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_myers, anvil_dag, anvil_utils;

type
  { Blame metadata for a single line }
  TBlameLine = record
    LineNo: Integer;
    CommitId: TObjectId;
    Author: TIdentity;
    Text: string;
  end;
  TBlameLineArray = array of TBlameLine;

  { Blame provenance engine }
  TBlameEngine = class
  private
    FODB: TObjectDatabase;
    FFilePath: string;
    FStartCommitId: TObjectId;

    function ReadFileAtCommit(const CommitId: TObjectId; const Path: string; out Text: string): Boolean;
    function GetTreePathBlobId(const TreeId: TObjectId; const Path: string): TObjectId;
  public
    constructor Create(AODB: TObjectDatabase; const AFilePath: string; const AStartCommitId: TObjectId);

    { Execute provenance walk and return line attribution array }
    function Execute: TBlameLineArray;

    { Format standard terminal blame representation }
    function FormatOutput(const BlameLines: TBlameLineArray): string;
  end;

function BlameFile(AODB: TObjectDatabase; const FilePath: string; const StartCommitId: TObjectId): TBlameLineArray;

implementation

constructor TBlameEngine.Create(AODB: TObjectDatabase; const AFilePath: string; const AStartCommitId: TObjectId);
begin
  inherited Create;
  FODB := AODB;
  FFilePath := AFilePath;
  FStartCommitId := AStartCommitId;
end;

function TBlameEngine.GetTreePathBlobId(const TreeId: TObjectId; const Path: string): TObjectId;
var
  Obj: TAnvilObject;
  Tree: TTreeObject;
  Segments: TStringArray;
  CurrTreeId: TObjectId;
  I, J: Integer;
  Entry: TTreeEntry;
  Found: Boolean;
begin
  Result := NullObjectId;
  if IsNullObjectId(TreeId) or (Path = '') then Exit;

  Segments := SplitStringByChar(Path, '/');
  CurrTreeId := TreeId;

  for I := 0 to Length(Segments) - 1 do
  begin
    Obj := FODB.ReadObject(CurrTreeId);
    if not Assigned(Obj) or not (Obj is TTreeObject) then
    begin
      if Assigned(Obj) then Obj.Free;
      Exit;
    end;

    Tree := TTreeObject(Obj);
    try
      Found := False;
      for J := 0 to Tree.Count - 1 do
      begin
        Entry := Tree.GetEntry(J);
        if Entry.Name = Segments[I] then
        begin
          Found := True;
          if I = Length(Segments) - 1 then
          begin
            Result := Entry.Id;
            Exit;
          end
          else if Entry.Mode = fmDirectory then
          begin
            CurrTreeId := Entry.Id;
            Break;
          end
          else
            Exit;
        end;
      end;

      if not Found then Exit;
    finally
      Tree.Free;
    end;
  end;
end;

function TBlameEngine.ReadFileAtCommit(const CommitId: TObjectId; const Path: string; out Text: string): Boolean;
var
  Obj: TAnvilObject;
  Commit: TCommitObject;
  BlobId: TObjectId;
  BlobObj: TAnvilObject;
  Blob: TBlobObject;
begin
  Result := False;
  Text := '';

  Obj := FODB.ReadObject(CommitId);
  if not Assigned(Obj) or not (Obj is TCommitObject) then
  begin
    if Assigned(Obj) then Obj.Free;
    Exit;
  end;

  Commit := TCommitObject(Obj);
  try
    BlobId := GetTreePathBlobId(Commit.TreeId, Path);
    if IsNullObjectId(BlobId) then Exit;

    BlobObj := FODB.ReadObject(BlobId);
    if not Assigned(BlobObj) or not (BlobObj is TBlobObject) then
    begin
      if Assigned(BlobObj) then BlobObj.Free;
      Exit;
    end;

    Blob := TBlobObject(BlobObj);
    try
      Text := Blob.AsString;
      Result := True;
    finally
      Blob.Free;
    end;
  finally
    Commit.Free;
  end;
end;

type
  TOriginMapEntry = record
    OrigLineIdx: Integer; { Index into Result }
    CurrLineNo: Integer;  { Line number in CurrText }
  end;
  TOriginMapArray = array of TOriginMapEntry;

function TBlameEngine.Execute: TBlameLineArray;
var
  InitialText: string;
  Lines: TStringArray;
  I: Integer;
  Walker: TCommitWalker;
  CurrCommit: TCommitObject;
  ParentText, CurrText: string;
  ParentCommitId: TObjectId;
  DiffLines: TDiffLineArray;
  DIdx: Integer;
  UnblamedRemaining: Integer;
  OriginMap: TOriginMapArray;
  NextOriginMap: TOriginMapArray;
  NewMapCount: Integer;
  DiffLine: TDiffLine;
begin
  SetLength(Result, 0);

  if not ReadFileAtCommit(FStartCommitId, FFilePath, InitialText) then
    Exit;

  Lines := SplitStringByChar(InitialText, #10);
  if (Length(Lines) > 0) and (Lines[Length(Lines) - 1] = '') and
     (Length(InitialText) > 0) and (InitialText[Length(InitialText)] = #10) then
  begin
    SetLength(Lines, Length(Lines) - 1);
  end;

  SetLength(Result, Length(Lines));
  SetLength(OriginMap, Length(Lines));

  for I := 0 to Length(Lines) - 1 do
  begin
    Result[I].LineNo := I + 1;
    Result[I].CommitId := NullObjectId;
    FillChar(Result[I].Author, SizeOf(Result[I].Author), 0);
    Result[I].Text := Lines[I];

    OriginMap[I].OrigLineIdx := I;
    OriginMap[I].CurrLineNo := I + 1;
  end;

  UnblamedRemaining := Length(Lines);

  Walker := TCommitWalker.Create(FODB, csoChronological);
  try
    Walker.Push(FStartCommitId);

    while (UnblamedRemaining > 0) and Walker.NextCommit(CurrCommit) do
    begin
      try
        if not ReadFileAtCommit(CurrCommit.ObjectId, FFilePath, CurrText) then
          Continue;

        if Length(CurrCommit.ParentIds) = 0 then
        begin
          { Root commit: all remaining unblamed lines belong here }
          for I := 0 to Length(OriginMap) - 1 do
          begin
            if IsNullObjectId(Result[OriginMap[I].OrigLineIdx].CommitId) then
            begin
              Result[OriginMap[I].OrigLineIdx].CommitId := CurrCommit.ObjectId;
              Result[OriginMap[I].OrigLineIdx].Author := CurrCommit.Author;
              Dec(UnblamedRemaining);
            end;
          end;
          Break;
        end;

        ParentCommitId := CurrCommit.ParentIds[0];
        if not ReadFileAtCommit(ParentCommitId, FFilePath, ParentText) then
        begin
          { File did not exist in parent: this commit introduced all remaining lines }
          for I := 0 to Length(OriginMap) - 1 do
          begin
            if IsNullObjectId(Result[OriginMap[I].OrigLineIdx].CommitId) then
            begin
              Result[OriginMap[I].OrigLineIdx].CommitId := CurrCommit.ObjectId;
              Result[OriginMap[I].OrigLineIdx].Author := CurrCommit.Author;
              Dec(UnblamedRemaining);
            end;
          end;
          Break;
        end;

        { Diff ParentText -> CurrText }
        DiffLines := MyersDiffStrings(ParentText, CurrText);

        SetLength(NextOriginMap, Length(OriginMap));
        NewMapCount := 0;

        { Track line correspondences }
        for I := 0 to Length(OriginMap) - 1 do
        begin
          { Find what happened to CurrLineNo in DiffLines }
          for DIdx := 0 to Length(DiffLines) - 1 do
          begin
            DiffLine := DiffLines[DIdx];
            if (DiffLine.NewLineNo = OriginMap[I].CurrLineNo) then
            begin
              if DiffLine.Op = eoKeep then
              begin
                { Line was untouched between Parent and Curr: pass blame to Parent }
                NextOriginMap[NewMapCount].OrigLineIdx := OriginMap[I].OrigLineIdx;
                NextOriginMap[NewMapCount].CurrLineNo := DiffLine.OldLineNo;
                Inc(NewMapCount);
              end
              else if DiffLine.Op = eoInsert then
              begin
                { Line was inserted in CurrCommit: blame CurrCommit! }
                if IsNullObjectId(Result[OriginMap[I].OrigLineIdx].CommitId) then
                begin
                  Result[OriginMap[I].OrigLineIdx].CommitId := CurrCommit.ObjectId;
                  Result[OriginMap[I].OrigLineIdx].Author := CurrCommit.Author;
                  Dec(UnblamedRemaining);
                end;
              end;
              Break;
            end;
          end;
        end;

        SetLength(NextOriginMap, NewMapCount);
        OriginMap := NextOriginMap;
      finally
        CurrCommit.Free;
      end;
    end;
  finally
    Walker.Free;
  end;
end;

function TBlameEngine.FormatOutput(const BlameLines: TBlameLineArray): string;
var
  I: Integer;
  ShortSha: string;
  AuthorName: string;
  Line: string;
begin
  Result := '';
  for I := 0 to Length(BlameLines) - 1 do
  begin
    ShortSha := Copy(ObjectIdToHex(BlameLines[I].CommitId), 1, 8);
    AuthorName := BlameLines[I].Author.Name;
    if AuthorName = '' then AuthorName := 'unknown';

    Line := Format('%s (%-15s %4d) %s'#10, [
      ShortSha,
      Copy(AuthorName, 1, 15),
      BlameLines[I].LineNo,
      BlameLines[I].Text
    ]);
    Result := Result + Line;
  end;
end;

function BlameFile(AODB: TObjectDatabase; const FilePath: string; const StartCommitId: TObjectId): TBlameLineArray;
var
  Eng: TBlameEngine;
begin
  Eng := TBlameEngine.Create(AODB, FilePath, StartCommitId);
  try
    Result := Eng.Execute;
  finally
    Eng.Free;
  end;
end;

end.
