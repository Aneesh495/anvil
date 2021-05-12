{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Ignore pattern matcher conforming to Git ignore specifications.
  Handles glob wildcards, recursive globstars (**), negated patterns (!),
  directory-only markers, and hierarchical directory inheritance.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_ignore;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_utils;

type
  { Match evaluation outcome }
  TIgnoreResult = (
    irNoMatch,
    irIgnored,
    irIncluded
  );

  { Single parsed ignore rule }
  TIgnoreRule = record
    Pattern: string;
    Prefix: string;
    Negated: Boolean;
    DirectoryOnly: Boolean;
    HasSlash: Boolean;
  end;
  TIgnoreRuleArray = array of TIgnoreRule;

  { Ignore matcher }
  TIgnoreMatcher = class
  private
    FRules: TIgnoreRuleArray;
    FRootDir: string;
    function GetRuleCount: Integer;
    function MatchWildcard(const Pattern, Text: string): Boolean;
    function MatchGlobstar(const Pattern, Text: string): Boolean;
  public
    constructor Create(const ARootDir: string = '');

    { Add ignore rules from raw text (e.g. read from .gitignore) }
    procedure AddRules(const Content: string; const Prefix: string = '');

    { Load rules from a specific ignore file on disk }
    function LoadFile(const FilePath: string; const Prefix: string = ''): Boolean;

    { Test whether a given relative path is ignored }
    function CheckPath(const RelPath: string; IsDirectory: Boolean): TIgnoreResult;
    function IsIgnored(const RelPath: string; IsDirectory: Boolean): Boolean;

    property RuleCount: Integer read GetRuleCount;
  end;

function FastGlobMatch(const Pattern, Text: string): Boolean;

implementation

function TIgnoreMatcher.GetRuleCount: Integer;
begin
  Result := Length(FRules);
end;

function FastGlobMatch(const Pattern, Text: string): Boolean;
var
  PIdx, TIdx: Integer;
  PChar, TChar: Char;
  NextP, NextT: Integer;
begin
  PIdx := 1;
  TIdx := 1;
  NextP := 0;
  NextT := 0;

  while (TIdx <= Length(Text)) or (PIdx <= Length(Pattern)) do
  begin
    if PIdx <= Length(Pattern) then
    begin
      PChar := Pattern[PIdx];
      if PChar = '*' then
      begin
        NextP := PIdx;
        NextT := TIdx + 1;
        Inc(PIdx);
        Continue;
      end;

      if TIdx <= Length(Text) then
      begin
        TChar := Text[TIdx];
        if (PChar = '?') or (PChar = TChar) then
        begin
          Inc(PIdx);
          Inc(TIdx);
          Continue;
        end;
      end;
    end;

    if (NextT > 0) and (NextT <= Length(Text) + 1) then
    begin
      PIdx := NextP + 1;
      TIdx := NextT;
      Inc(NextT);
      Continue;
    end;

    Exit(False);
  end;

  Result := True;
end;

constructor TIgnoreMatcher.Create(const ARootDir: string);
begin
  inherited Create;
  FRootDir := ARootDir;
  SetLength(FRules, 0);
end;

procedure TIgnoreMatcher.AddRules(const Content: string; const Prefix: string);
var
  Lines: TStringArray;
  I: Integer;
  Line, Pat: string;
  Rule: TIgnoreRule;
  NormPrefix: string;
begin
  NormPrefix := Prefix;
  if (NormPrefix <> '') and (NormPrefix[Length(NormPrefix)] <> '/') then
    NormPrefix := NormPrefix + '/';

  Lines := SplitStringByChar(Content, #10);
  for I := 0 to Length(Lines) - 1 do
  begin
    Line := Trim(Lines[I]);
    { Skip empty lines and comment lines }
    if (Line = '') or (Line[1] = '#') then
      Continue;

    Rule.Negated := False;
    Rule.DirectoryOnly := False;
    Rule.Prefix := NormPrefix;

    if Line[1] = '!' then
    begin
      Rule.Negated := True;
      Pat := Copy(Line, 2, Length(Line) - 1);
    end
    else
      Pat := Line;

    if (Pat <> '') and (Pat[Length(Pat)] = '/') then
    begin
      Rule.DirectoryOnly := True;
      Pat := Copy(Pat, 1, Length(Pat) - 1);
    end;

    if (Pat <> '') and (Pat[1] = '/') then
      Pat := Copy(Pat, 2, Length(Pat) - 1);

    Rule.HasSlash := Pos('/', Pat) > 0;
    Rule.Pattern := Pat;

    SetLength(FRules, Length(FRules) + 1);
    FRules[Length(FRules) - 1] := Rule;
  end;
end;

function TIgnoreMatcher.LoadFile(const FilePath: string; const Prefix: string): Boolean;
var
  Content: string;
begin
  Result := False;
  if not FileExists(FilePath) then
    Exit;

  Content := ReadEntireFileString(FilePath);
  AddRules(Content, Prefix);
  Result := True;
end;

function TIgnoreMatcher.MatchWildcard(const Pattern, Text: string): Boolean;
begin
  Result := FastGlobMatch(Pattern, Text);
end;

function TIgnoreMatcher.MatchGlobstar(const Pattern, Text: string): Boolean;
var
  PatParts, TextParts: TStringArray;
  P, T: Integer;
begin
  { Handle ** recursive patterns }
  if Pos('**', Pattern) = 0 then
    Exit(MatchWildcard(Pattern, Text));

  PatParts := SplitStringByChar(Pattern, '/');
  TextParts := SplitStringByChar(Text, '/');

  P := 0;
  T := 0;

  while (P < Length(PatParts)) and (T < Length(TextParts)) do
  begin
    if PatParts[P] = '**' then
    begin
      if P = Length(PatParts) - 1 then
        Exit(True); { Trailing ** matches everything }

      { Try skipping segments in Text until remainder matches }
      while T < Length(TextParts) do
      begin
        if MatchWildcard(PatParts[P + 1], TextParts[T]) then
          Break;
        Inc(T);
      end;
      Inc(P);
    end
    else
    begin
      if not MatchWildcard(PatParts[P], TextParts[T]) then
        Exit(False);
      Inc(P);
      Inc(T);
    end;
  end;

  while (P < Length(PatParts)) and (PatParts[P] = '**') do
    Inc(P);

  Result := (P >= Length(PatParts)) and (T >= Length(TextParts));
end;

function TIgnoreMatcher.CheckPath(const RelPath: string; IsDirectory: Boolean): TIgnoreResult;
var
  I: Integer;
  Rule: TIgnoreRule;
  TestPath, BaseName: string;
  Matched: Boolean;
  SlashPos: Integer;
begin
  Result := irNoMatch;
  TestPath := RelPath;
  if (TestPath <> '') and (TestPath[1] = '/') then
    TestPath := Copy(TestPath, 2, Length(TestPath) - 1);

  SlashPos := LastDelimiter('/', TestPath);
  if SlashPos > 0 then
    BaseName := Copy(TestPath, SlashPos + 1, Length(TestPath) - SlashPos)
  else
    BaseName := TestPath;

  for I := 0 to Length(FRules) - 1 do
  begin
    Rule := FRules[I];

    { DirectoryOnly check }
    if Rule.DirectoryOnly and (not IsDirectory) then
      Continue;

    { Check prefix scope if rule was loaded from subdirectory }
    if Rule.Prefix <> '' then
    begin
      if Copy(TestPath, 1, Length(Rule.Prefix)) <> Rule.Prefix then
        Continue;
      TestPath := Copy(TestPath, Length(Rule.Prefix) + 1, Length(TestPath) - Length(Rule.Prefix));
    end;

    Matched := False;

    if Rule.HasSlash then
    begin
      { Pattern contains slash: match against full relative path }
      Matched := MatchGlobstar(Rule.Pattern, TestPath);
    end
    else
    begin
      { Pattern has no slash: match against basename or path }
      Matched := MatchWildcard(Rule.Pattern, BaseName);
      if not Matched then
        Matched := MatchWildcard(Rule.Pattern, TestPath);
    end;

    if Matched then
    begin
      if Rule.Negated then
        Result := irIncluded
      else
        Result := irIgnored;
    end;
  end;
end;

function TIgnoreMatcher.IsIgnored(const RelPath: string; IsDirectory: Boolean): Boolean;
begin
  Result := CheckPath(RelPath, IsDirectory) = irIgnored;
end;

end.
