{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Rebase and Cherry-pick execution engine.
  Sequentially replays a range of commits on top of a new upstream base using
  3-way tree merge, preserving author metadata and updating committer records.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_rebase;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_index, anvil_lca, anvil_merge_tree;

type
  { Cherry-pick step result }
  TCherryPickResult = record
    Success: Boolean;
    HasConflict: Boolean;
    ConflictCount: Integer;
    NewCommitId: TObjectId;
    ConflictedPaths: TStringArray;
    ErrorMessage: string;
  end;

  { Rebase summary result }
  TRebaseResult = record
    Success: Boolean;
    HasConflict: Boolean;
    ReplayedCount: Integer;
    TotalCommits: Integer;
    NewTipCommitId: TObjectId;
    FailedCommitId: TObjectId;
    ConflictedPaths: TStringArray;
    ErrorMessage: string;
  end;

  { Rebase and cherry-pick engine }
  TRebaseEngine = class
  private
    FODB: TObjectDatabase;
    FIndex: TIndex;
    FCommitter: TIdentity;
    function ReadCommit(const Id: TObjectId): TCommitObject;
  public
    constructor Create(AODB: TObjectDatabase; AIndex: TIndex; const ACommitter: TIdentity);

    { Cherry-pick a single commit onto an existing parent commit }
    function CherryPick(const SourceCommitId, OntoCommitId: TObjectId): TCherryPickResult;

    { Rebase a linear branch from Upstream to BranchTip }
    function RebaseBranch(const UpstreamCommitId, BranchTipCommitId: TObjectId): TRebaseResult;
  end;

implementation

constructor TRebaseEngine.Create(AODB: TObjectDatabase; AIndex: TIndex; const ACommitter: TIdentity);
begin
  inherited Create;
  FODB := AODB;
  FIndex := AIndex;
  FCommitter := ACommitter;
end;

function TRebaseEngine.ReadCommit(const Id: TObjectId): TCommitObject;
var
  Obj: TAnvilObject;
begin
  Obj := FODB.ReadObject(Id);
  if not Assigned(Obj) then
    raise EObjectNotFound.CreateForObject(Id);
  if not (Obj is TCommitObject) then
  begin
    Obj.Free;
    raise ECorruptObject.Create('Object is not a commit: ' + ObjectIdToHex(Id));
  end;
  Result := TCommitObject(Obj);
end;

function TRebaseEngine.CherryPick(const SourceCommitId, OntoCommitId: TObjectId): TCherryPickResult;
var
  SourceCommit, OntoCommit: TCommitObject;
  BaseTreeId: TObjectId;
  MergeSum: TMergeTreeSummary;
  NewCommit: TCommitObject;
  ParentCommit: TCommitObject;
begin
  Result.Success := False;
  Result.HasConflict := False;
  Result.ConflictCount := 0;
  Result.NewCommitId := NullObjectId;
  SetLength(Result.ConflictedPaths, 0);
  Result.ErrorMessage := '';

  SourceCommit := ReadCommit(SourceCommitId);
  try
    OntoCommit := ReadCommit(OntoCommitId);
    try
      { Determine base tree from source's parent }
      if Length(SourceCommit.ParentIds) > 0 then
      begin
        ParentCommit := ReadCommit(SourceCommit.ParentIds[0]);
        try
          BaseTreeId := ParentCommit.TreeId;
        finally
          ParentCommit.Free;
        end;
      end
      else
        BaseTreeId := NullObjectId;

      { Execute 3-way tree merge }
      MergeSum := MergeTrees(FODB, FIndex, BaseTreeId, OntoCommit.TreeId, SourceCommit.TreeId,
                             'HEAD', ObjectIdToHex(SourceCommitId));

      if not MergeSum.Success then
      begin
        Result.HasConflict := True;
        Result.ConflictCount := MergeSum.ConflictCount;
        Result.ConflictedPaths := MergeSum.ConflictedPaths;
        Result.ErrorMessage := Format('Conflict during cherry-pick of %s', [ObjectIdToHex(SourceCommitId)]);
        Exit;
      end;

      { Create new replayed commit object }
      NewCommit := TCommitObject.Create;
      try
        NewCommit.TreeId := MergeSum.ResultTreeId;
        NewCommit.AddParent(OntoCommitId);
        NewCommit.Author := SourceCommit.Author; { Preserve original author }
        NewCommit.Committer := FCommitter;       { Committer updated to current user/time }
        NewCommit.Message := SourceCommit.Message;
        NewCommit.Encoding := SourceCommit.Encoding;

        FODB.WriteObject(NewCommit);
        Result.NewCommitId := NewCommit.ObjectId;
        Result.Success := True;
      finally
        NewCommit.Free;
      end;
    finally
      OntoCommit.Free;
    end;
  finally
    SourceCommit.Free;
  end;
end;

function TRebaseEngine.RebaseBranch(const UpstreamCommitId, BranchTipCommitId: TObjectId): TRebaseResult;
var
  LcaFinder: TLcaFinder;
  MergeBaseId: TObjectId;
  CommitsToReplay: TObjectIdArray;
  CurrId: TObjectId;
  CurrCommit: TCommitObject;
  I: Integer;
  StepRes: TCherryPickResult;
  NewParentId: TObjectId;
begin
  Result.Success := False;
  Result.HasConflict := False;
  Result.ReplayedCount := 0;
  Result.TotalCommits := 0;
  Result.NewTipCommitId := NullObjectId;
  Result.FailedCommitId := NullObjectId;
  SetLength(Result.ConflictedPaths, 0);
  Result.ErrorMessage := '';

  { Fast-forward check }
  if ObjectIdEqual(UpstreamCommitId, BranchTipCommitId) then
  begin
    Result.Success := True;
    Result.NewTipCommitId := BranchTipCommitId;
    Exit;
  end;

  LcaFinder := TLcaFinder.Create(FODB);
  try
    if not LcaFinder.FindBestMergeBase(UpstreamCommitId, BranchTipCommitId, MergeBaseId) then
    begin
      Result.ErrorMessage := 'No common ancestor found between upstream and branch';
      Exit;
    end;
  finally
    LcaFinder.Free;
  end;

  { If branch tip is already an ancestor of upstream: already up-to-date }
  if ObjectIdEqual(MergeBaseId, BranchTipCommitId) then
  begin
    Result.Success := True;
    Result.NewTipCommitId := UpstreamCommitId;
    Exit;
  end;

  { Collect commits from MergeBaseId to BranchTipCommitId (exclusive of MergeBaseId) }
  SetLength(CommitsToReplay, 0);
  CurrId := BranchTipCommitId;

  while not ObjectIdEqual(CurrId, MergeBaseId) and not IsNullObjectId(CurrId) do
  begin
    SetLength(CommitsToReplay, Length(CommitsToReplay) + 1);
    CommitsToReplay[Length(CommitsToReplay) - 1] := CurrId;

    CurrCommit := ReadCommit(CurrId);
    try
      if Length(CurrCommit.ParentIds) > 0 then
        CurrId := CurrCommit.ParentIds[0]
      else
        CurrId := NullObjectId;
    finally
      CurrCommit.Free;
    end;
  end;

  { Reverse to get chronological order (oldest to newest) }
  for I := 0 to (Length(CommitsToReplay) div 2) - 1 do
  begin
    CurrId := CommitsToReplay[I];
    CommitsToReplay[I] := CommitsToReplay[Length(CommitsToReplay) - 1 - I];
    CommitsToReplay[Length(CommitsToReplay) - 1 - I] := CurrId;
  end;

  Result.TotalCommits := Length(CommitsToReplay);
  NewParentId := UpstreamCommitId;

  { Replay each commit sequentially onto NewParentId }
  for I := 0 to Length(CommitsToReplay) - 1 do
  begin
    StepRes := CherryPick(CommitsToReplay[I], NewParentId);
    if not StepRes.Success then
    begin
      Result.HasConflict := True;
      Result.FailedCommitId := CommitsToReplay[I];
      Result.ConflictedPaths := StepRes.ConflictedPaths;
      Result.ErrorMessage := StepRes.ErrorMessage;
      Exit;
    end;

    NewParentId := StepRes.NewCommitId;
    Inc(Result.ReplayedCount);
  end;

  Result.Success := True;
  Result.NewTipCommitId := NewParentId;
end;

end.
