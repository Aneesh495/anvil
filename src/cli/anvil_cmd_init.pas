{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Porcelain command: anvil init.
  Initializes a new Anvil repository in the specified directory.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_cmd_init;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_cli_common, anvil_utils;

function RunCmdInit(const Args: TStringArray): Integer;

implementation

function RunCmdInit(const Args: TStringArray): Integer;
var
  TargetDir, DotDir: string;
  PosArgs: TStringArray;
  IsBare: Boolean;
  ConfigContent: string;
begin
  Result := 1;
  IsBare := HasFlag(Args, '', '--bare');
  PosArgs := GetPositionalArgs(Args);

  if Length(PosArgs) > 0 then
    TargetDir := ExpandFileName(PosArgs[0])
  else
    TargetDir := GetCurrentDir;

  if IsBare then
    DotDir := TargetDir
  else
    DotDir := JoinPaths(TargetDir, '.anvil');

  if DirectoryExists(DotDir) and FileExists(JoinPaths(DotDir, 'HEAD')) then
  begin
    Writeln('Reinitialized existing Anvil repository in ', DotDir);
    Result := 0;
    Exit;
  end;

  EnsureDirectoryExists(DotDir);
  EnsureDirectoryExists(JoinPaths(DotDir, 'objects'));
  EnsureDirectoryExists(JoinPaths(DotDir, JoinPaths('objects', 'pack')));
  EnsureDirectoryExists(JoinPaths(DotDir, JoinPaths('objects', 'info')));
  EnsureDirectoryExists(JoinPaths(DotDir, 'refs'));
  EnsureDirectoryExists(JoinPaths(DotDir, JoinPaths('refs', 'heads')));
  EnsureDirectoryExists(JoinPaths(DotDir, JoinPaths('refs', 'tags')));
  EnsureDirectoryExists(JoinPaths(DotDir, JoinPaths('refs', 'remotes')));
  EnsureDirectoryExists(JoinPaths(DotDir, 'logs'));
  EnsureDirectoryExists(JoinPaths(DotDir, JoinPaths('logs', 'refs')));
  EnsureDirectoryExists(JoinPaths(DotDir, JoinPaths('logs', JoinPaths('refs', 'heads'))));

  { Write symbolic HEAD pointing to refs/heads/main }
  WriteEntireFileString(JoinPaths(DotDir, 'HEAD'), 'ref: refs/heads/main'#10);

  { Write initial repository config }
  ConfigContent :=
    '[core]'#10 +
    #9'repositoryformatversion = 0'#10 +
    #9'filemode = true'#10 +
    #9'bare = ' + BoolToStr(IsBare, 'true', 'false') + #10 +
    #9'logallrefupdates = true'#10 +
    #9'hashalgorithm = sha1'#10;
  WriteEntireFileString(JoinPaths(DotDir, 'config'), ConfigContent);

  if IsBare then
    Writeln('Initialized empty Anvil repository in ', DotDir)
  else
    Writeln('Initialized empty Anvil repository in ', DotDir, '/');

  Result := 0;
end;

end.
