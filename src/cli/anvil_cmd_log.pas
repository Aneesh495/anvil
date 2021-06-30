{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Porcelain command: anvil log.
  Shows the commit logs, with optional one-line summary and ASCII branch graph.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_cmd_log;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DateUtils,
  anvil_types, anvil_errors, anvil_hash, anvil_object, anvil_odb,
  anvil_ref, anvil_dag, anvil_graph_view, anvil_cli_common, anvil_utils;

function RunCmdLog(const Args: TStringArray): Integer;

implementation

function RunCmdLog(const Args: TStringArray): Integer;
var
  Ctx: TRepoContext;
  IsOneLine, ShowGraph: Boolean;
  CountStr: string;
  MaxCount: Integer;
  StartRev: string;
  StartId, CommitId: TObjectId;
  PosArgs: TStringArray;
  Walker: TCommitWalker;
  CommitCount: Integer;
  ObjType: TObjectType;
  RawData: TByteArray;
  CommitObj: TCommitObject;
  ShortSha: string;
  FirstLineMsg: string;
  DateStr: string;
  Renderer: TGraphRenderer;
  GraphLines: TGraphLineArray;
  GraphOutput: string;
  I: Integer;
begin
  Result := 1;
  if not OpenRepoContext(Ctx) then Exit;
  try
    IsOneLine := HasFlag(Args, '', '--oneline');
    ShowGraph := HasFlag(Args, '', '--graph');

    MaxCount := MaxInt;
    if GetOptionValue(Args, '-n', '--max-count', CountStr) then
      MaxCount := StrToIntDef(CountStr, MaxInt);

    PosArgs := GetPositionalArgs(Args);
    if Length(PosArgs) > 0 then
      StartRev := PosArgs[0]
    else
      StartRev := 'HEAD';

    if not ResolveRevision(Ctx, StartRev, StartId) then
    begin
      PrintError('fatal: your current branch does not have any commits yet');
      Exit;
    end;

    if ShowGraph then
    begin
      Renderer := TGraphRenderer.Create(Ctx.ODB, Ctx.RefMgr, False);
      try
        GraphLines := Renderer.RenderHistory(StartId, MaxCount);
        GraphOutput := Renderer.FormatGraphString(GraphLines);
        Write(GraphOutput);
        Result := 0;
        Exit;
      finally
        Renderer.Free;
      end;
    end;

    Walker := TCommitWalker.Create(Ctx.ODB, csoTopological);
    try
      Walker.Push(StartId);
      CommitCount := 0;

      while (CommitCount < MaxCount) and Walker.Next(CommitId) do
      begin
        if not Ctx.ODB.ReadObjectRaw(CommitId, ObjType, RawData) or (ObjType <> otCommit) then
          Continue;

        CommitObj := TCommitObject.Create;
        try
          CommitObj.Deserialize(@RawData[0], Length(RawData));
          ShortSha := Copy(ObjectIdToHex(CommitId), 1, 7);
          FirstLineMsg := CommitObj.Message;
          if Pos(#10, FirstLineMsg) > 0 then
            FirstLineMsg := Copy(FirstLineMsg, 1, Pos(#10, FirstLineMsg) - 1);

          if IsOneLine then
          begin
            Writeln(ShortSha, ' ', FirstLineMsg);
          end
          else
          begin
            if CommitCount > 0 then Writeln;
            Writeln('commit ', ObjectIdToHex(CommitId));
            if Length(CommitObj.ParentIds) > 1 then
            begin
              Write('Merge:');
              for I := 0 to Length(CommitObj.ParentIds) - 1 do
                Write(' ', Copy(ObjectIdToHex(CommitObj.ParentIds[I]), 1, 7));
              Writeln;
            end;
            Writeln('Author: ', FormatIdentity(CommitObj.Author));
            DateStr := FormatDateTimeGit(CommitObj.Author.When.Seconds, CommitObj.Author.When.OffsetMinutes);
            Writeln('Date:   ', DateStr);
            Writeln;
            Writeln('    ', FirstLineMsg);
          end;

          Inc(CommitCount);
        finally
          CommitObj.Free;
        end;
      end;

      Result := 0;
    finally
      Walker.Free;
    end;

  finally
    CloseRepoContext(Ctx);
  end;
end;

end.
