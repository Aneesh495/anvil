{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Porcelain command: anvil merge.
  Join two or more development histories together.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_cmd_merge;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DateUtils,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_ref, anvil_reflog, anvil_index, anvil_lca, anvil_merge_tree,
  anvil_checkout, anvil_cli_common, anvil_utils;

function RunCmdMerge(const Args: TStringArray): Integer;

implementation

function RunCmdMerge(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  PosArgs: TStringArray;
  BranchToMerge: string;
  OursId, TheirsId, BaseId: TObjectId;
  HasBase: Boolean;
  Lca: TLcaFinder;
  HeadRef: TReference;
  CurrentBranch: string;
  OursTreeId, TheirsTreeId, BaseTreeId: TObjectId;
  ObjType: TObjectType;
  RawData: TByteArray;
  OursCommit, TheirsCommit, BaseCommit, MergeCommit: TCommitObject;
  Merger: TTreeMerger;
  Summary: TMergeTreeSummary;
  CheckoutMgr: TCheckoutManager;
  CheckOptions: TCheckoutOptions;
  Identity: TIdentity;
  MergeCommitId: TObjectId;
  ReflogMgr: TReflogManager;
  I: Integer;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    PosArgs := GetPositionalArgs(Args);
    if Length(PosArgs) = 0 then
    begin
      PrintUsage('merge', '<branch>', 'Join two or more development histories together');
      Exit;
    end;

    BranchToMerge := PosArgs[0];

    { 1. Resolve current HEAD (Ours) }
    if not Ctx.RefMgr.Resolve('HEAD', OursId) then
    begin
      PrintError('fatal: current branch does not have any commits yet');
      Exit;
    end;

    { 2. Resolve target branch (Theirs) }
    if not Ctx.RefMgr.Resolve('refs/heads/' + BranchToMerge, TheirsId) then
    begin
      if not ResolveRevision(Ctx, BranchToMerge, TheirsId) then
      begin
        PrintError('fatal: ' + BranchToMerge + ' - not something we can merge');
        Exit;
      end;
    end;

    { 3. Check if identical }
    if ObjectIdEqual(OursId, TheirsId) then
    begin
      Writeln('Already up to date.');
      Result := 0;
      Exit;
    end;

    { 4. Find Merge Base }
    Lca := TLcaFinder.Create(Ctx.ODB);
    try
      HasBase := Lca.FindBestMergeBase(OursId, TheirsId, BaseId);
    finally
      Lca.Free;
    end;

    if HasBase and ObjectIdEqual(BaseId, TheirsId) then
    begin
      Writeln('Already up to date.');
      Result := 0;
      Exit;
    end;

    HeadRef := Ctx.RefMgr.GetReference('HEAD');
    if (HeadRef <> nil) and (HeadRef.RefType = rtSymbolic) then
      CurrentBranch := HeadRef.SymbolicTarget
    else
      CurrentBranch := 'HEAD';

    { Fast-forward check: if BaseId equals OursId, fast-forward directly }
    if HasBase and ObjectIdEqual(BaseId, OursId) then
    begin
      Writeln('Updating ', Copy(ObjectIdToHex(OursId), 1, 7), '..', Copy(ObjectIdToHex(TheirsId), 1, 7));
      Writeln('Fast-forward');

      CheckoutMgr := TCheckoutManager.Create(Ctx.RepoRoot, Ctx.GitDir, Ctx.ODB, Ctx.Index, Ctx.RefMgr);
      try
        CheckOptions.Force := False;
        CheckOptions.BranchName := '';
        CheckoutMgr.CheckoutCommit(TheirsId, CheckOptions);
      finally
        CheckoutMgr.Free;
      end;

      Ctx.RefMgr.SetReference(CurrentBranch, TheirsId);
      Result := 0;
      Exit;
    end;

    { 5. Perform true three-way recursive merge }
    { Load tree IDs }
    Ctx.ODB.ReadObjectRaw(OursId, ObjType, RawData);
    OursCommit := TCommitObject.Create;
    try
      OursCommit.Deserialize(@RawData[0], Length(RawData));
      OursTreeId := OursCommit.TreeId;
    finally
      OursCommit.Free;
    end;

    Ctx.ODB.ReadObjectRaw(TheirsId, ObjType, RawData);
    TheirsCommit := TCommitObject.Create;
    try
      TheirsCommit.Deserialize(@RawData[0], Length(RawData));
      TheirsTreeId := TheirsCommit.TreeId;
    finally
      TheirsCommit.Free;
    end;

    if HasBase and not IsNullObjectId(BaseId) then
    begin
      Ctx.ODB.ReadObjectRaw(BaseId, ObjType, RawData);
      BaseCommit := TCommitObject.Create;
      try
        BaseCommit.Deserialize(@RawData[0], Length(RawData));
        BaseTreeId := BaseCommit.TreeId;
      finally
        BaseCommit.Free;
      end;
    end
    else
      BaseTreeId := NullObjectId(Ctx.Algo);

    Merger := TTreeMerger.Create(Ctx.ODB, Ctx.Index, BaseTreeId, OursTreeId, TheirsTreeId,
                                'HEAD', BranchToMerge);
    try
      Summary := Merger.Execute;
      Ctx.Index.WriteToFile;

      if not Summary.Success then
      begin
        for I := 0 to Length(Summary.ConflictedPaths) - 1 do
          Writeln('CONFLICT (content): Merge conflict in ', Summary.ConflictedPaths[I]);
        Writeln('Automatic merge failed; fix conflicts and then commit the result.');
        Result := 1;
        Exit;
      end;

      { Clean merge: checkout merged files and create merge commit }
      CheckoutMgr := TCheckoutManager.Create(Ctx.RepoRoot, Ctx.GitDir, Ctx.ODB, Ctx.Index, Ctx.RefMgr);
      try
        CheckoutMgr.CheckoutTree(Summary.ResultTreeId, True);
      finally
        CheckoutMgr.Free;
      end;

      MergeCommit := TCommitObject.Create;
      try
        MergeCommit.TreeId := Summary.ResultTreeId;
        MergeCommit.AddParent(OursId);
        MergeCommit.AddParent(TheirsId);

        Identity := MakeIdentity('Aneesh Krishna', 'aneesh@engine.internal', DateTimeToUnix(Now), 0);
        MergeCommit.Author := Identity;
        MergeCommit.Committer := Identity;
        MergeCommit.Message := 'Merge branch ''' + BranchToMerge + ''''#10;

        MergeCommitId := Ctx.ODB.WriteObject(MergeCommit);
        Ctx.RefMgr.SetReference(CurrentBranch, MergeCommitId);

        ReflogMgr := TReflogManager.Create(Ctx.GitDir, Ctx.Algo);
        try
          ReflogMgr.Append(CurrentBranch, OursId, MergeCommitId, Identity,
            'merge ' + BranchToMerge + ': Fast-forward or clean recursive merge');
        finally
          ReflogMgr.Free;
        end;

        Writeln('Merge made by the ''recursive'' strategy.');
        Result := 0;
      finally
        MergeCommit.Free;
      end;

    finally
      Merger.Free;
    end;

  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
