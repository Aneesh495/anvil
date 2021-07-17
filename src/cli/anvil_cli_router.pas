{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Top-level command line dispatcher and router.
  Maps subcommands to their respective execution engines.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_cli_router;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types,
  anvil_cat_file, anvil_hash_object, anvil_ls_tree,
  anvil_write_tree, anvil_read_tree, anvil_commit_tree,
  anvil_rev_parse, anvil_rev_list, anvil_fsck,
  anvil_cmd_init, anvil_cmd_status, anvil_cmd_add, anvil_cmd_rm,
  anvil_cmd_commit, anvil_cmd_diff, anvil_cmd_log, anvil_cmd_branch,
  anvil_cmd_checkout, anvil_cmd_merge, anvil_cmd_rebase,
  anvil_cmd_cherry_pick, anvil_cmd_tag, anvil_cmd_reset,
  anvil_cmd_blame, anvil_cmd_gc;

const
  ANVIL_VERSION = '1.0.0';

function DispatchCliCommand(const CommandName: string; const Args: TStringArray): Integer;
procedure PrintMainHelp;

implementation

procedure PrintMainHelp;
begin
  Writeln('usage: anvil [--version] [--help] <command> [<args>]');
  Writeln;
  Writeln('These are common Anvil commands used in various situations:');
  Writeln;
  Writeln('start a working area:');
  Writeln('   init       Create an empty Anvil repository or reinitialize an existing one');
  Writeln;
  Writeln('work on the current change:');
  Writeln('   add        Add file contents to the index');
  Writeln('   rm         Remove files from the working tree and from the index');
  Writeln('   reset      Reset current HEAD to the specified state');
  Writeln('   status     Show the working tree status');
  Writeln('   diff       Show changes between commits, commit and working tree, etc');
  Writeln;
  Writeln('examine the history and state:');
  Writeln('   log        Show commit logs');
  Writeln('   blame      Show what revision and author last modified each line of a file');
  Writeln('   fsck       Verifies the connectivity and validity of the objects');
  Writeln;
  Writeln('grow, mark and tweak your common history:');
  Writeln('   branch     List, create, or delete branches');
  Writeln('   checkout   Switch branches or restore working tree files');
  Writeln('   commit     Record changes to the repository');
  Writeln('   merge      Join two or more development histories together');
  Writeln('   rebase     Reapply commits on top of another base tip');
  Writeln('   cherry-pick Apply the changes introduced by some existing commits');
  Writeln('   tag        Create, list, delete or verify a tag object');
  Writeln('   gc         Cleanup unnecessary files and optimize the local repository');
  Writeln;
  Writeln('low-level plumbing commands:');
  Writeln('   cat-file, hash-object, ls-tree, write-tree, read-tree, commit-tree,');
  Writeln('   rev-parse, rev-list');
  Writeln;
  Writeln('See ''anvil <command> --help'' to read about a specific subcommand.');
end;

function DispatchCliCommand(const CommandName: string; const Args: TStringArray): Integer;
begin
  if (CommandName = '--version') or (CommandName = '-v') or (CommandName = 'version') then
  begin
    Writeln('anvil version ', ANVIL_VERSION);
    Exit(0);
  end;

  if (CommandName = '--help') or (CommandName = '-h') or (CommandName = 'help') or (CommandName = '') then
  begin
    PrintMainHelp;
    Exit(0);
  end;

  case CommandName of
    { Porcelain }
    'init': Result := RunCmdInit(Args);
    'status': Result := RunCmdStatus(Args);
    'add': Result := RunCmdAdd(Args);
    'rm': Result := RunCmdRm(Args);
    'commit': Result := RunCmdCommit(Args);
    'diff': Result := RunCmdDiff(Args);
    'log': Result := RunCmdLog(Args);
    'branch': Result := RunCmdBranch(Args);
    'checkout': Result := RunCmdCheckout(Args);
    'merge': Result := RunCmdMerge(Args);
    'rebase': Result := RunCmdRebase(Args);
    'cherry-pick': Result := RunCmdCherryPick(Args);
    'tag': Result := RunCmdTag(Args);
    'reset': Result := RunCmdReset(Args);
    'blame': Result := RunCmdBlame(Args);
    'gc': Result := RunCmdGc(Args);

    { Plumbing }
    'cat-file': Result := RunCmdCatFile(Args);
    'hash-object': Result := RunCmdHashObject(Args);
    'ls-tree': Result := RunCmdLsTree(Args);
    'write-tree': Result := RunCmdWriteTree(Args);
    'read-tree': Result := RunCmdReadTree(Args);
    'commit-tree': Result := RunCmdCommitTree(Args);
    'rev-parse': Result := RunCmdRevParse(Args);
    'rev-list': Result := RunCmdRevList(Args);
    'fsck': Result := RunCmdFsck(Args);

    else
    begin
      Writeln(StdErr, 'anvil: ''', CommandName, ''' is not an anvil command. See ''anvil --help''.');
      Result := 1;
    end;
  end;
end;

end.
