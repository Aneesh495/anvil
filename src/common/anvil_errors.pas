{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Custom exception classes and diagnostic error codes.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_errors;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, anvil_types;

type
  { Base class for all Anvil engine exceptions }
  EAnvilError = class(Exception)
  private
    FErrorCode: Integer;
  public
    constructor CreateWithCode(ACode: Integer; const AMsg: string);
    property ErrorCode: Integer read FErrorCode;
  end;

  { Storage and object errors }
  EObjectNotFound = class(EAnvilError)
  private
    FObjectId: TObjectId;
  public
    constructor CreateForObject(const AId: TObjectId);
    property ObjectId: TObjectId read FObjectId;
  end;

  ECorruptObject = class(EAnvilError);
  EPackCorrupt = class(EAnvilError);
  EPackIndexCorrupt = class(EAnvilError);

  { Staging and index errors }
  EIndexCorrupt = class(EAnvilError);
  EIndexLocked = class(EAnvilError);
  EPathOutsideRepository = class(EAnvilError);

  { Reference management errors }
  EInvalidReference = class(EAnvilError);
  EReferenceNotFound = class(EAnvilError);
  EReferenceLocked = class(EAnvilError);

  { Diff and merge errors }
  EMergeConflict = class(EAnvilError);
  EPatchParseError = class(EAnvilError);
  EPatchApplyError = class(EAnvilError);

  { Working directory and checkout errors }
  EWorktreeDirty = class(EAnvilError);
  EFileLocked = class(EAnvilError);
  EPathCollision = class(EAnvilError);

  { Wire protocol errors }
  EProtocolError = class(EAnvilError);
  EPacketLineError = class(EAnvilError);

{ Standard numeric error codes }
const
  ERR_OK                     = 0;
  ERR_GENERIC                = -1;
  ERR_OBJECT_NOT_FOUND       = -2;
  ERR_CORRUPT_OBJECT         = -3;
  ERR_PACK_CORRUPT           = -4;
  ERR_INDEX_CORRUPT          = -5;
  ERR_INDEX_LOCKED           = -6;
  ERR_PATH_OUTSIDE_REPO      = -7;
  ERR_INVALID_REFERENCE      = -8;
  ERR_REFERENCE_NOT_FOUND    = -9;
  ERR_REFERENCE_LOCKED       = -10;
  ERR_MERGE_CONFLICT         = -11;
  ERR_PATCH_PARSE_ERROR      = -12;
  ERR_PATCH_APPLY_ERROR      = -13;
  ERR_WORKTREE_DIRTY         = -14;
  ERR_PROTOCOL_ERROR         = -15;

implementation

constructor EAnvilError.CreateWithCode(ACode: Integer; const AMsg: string);
begin
  inherited Create(AMsg);
  FErrorCode := ACode;
end;

constructor EObjectNotFound.CreateForObject(const AId: TObjectId);
begin
  FObjectId := AId;
  inherited CreateWithCode(ERR_OBJECT_NOT_FOUND,
    Format('Object not found in repository database: %s', [ObjectIdToHex(AId)]));
end;

end.
