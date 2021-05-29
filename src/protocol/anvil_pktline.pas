{
  Anvil Version Control Engine
  Copyright (c) 2026 Aneesh Krishna
  All rights reserved.

  Git pkt-line wire protocol framing and sideband-64k demultiplexer.
  Implements the standard 4-hex-digit length-prefixed packet protocol,
  supporting flush-pkt (0000), delim-pkt (0001), and multiplexed sideband channels.
  Free Pascal Mode: ObjFPC with LongStrings enabled.
}

unit anvil_pktline;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  anvil_types, anvil_errors, anvil_utils;

const
  PKT_MAX_PAYLOAD = 65516; { 65520 - 4 bytes length prefix }
  PKT_FLUSH_STR = '0000';
  PKT_DELIM_STR = '0001';
  PKT_RESP_END_STR = '0002';

  SIDEBAND_CHANNEL_PACK = 1;
  SIDEBAND_CHANNEL_PROGRESS = 2;
  SIDEBAND_CHANNEL_ERROR = 3;

type
  { Packet line kind }
  TPktLineKind = (
    pkData,       { Regular payload }
    pkFlush,      { 0000 }
    pkDelimiter,  { 0001 }
    pkResponseEnd { 0002 }
  );

  { Single parsed packet line }
  TPktLine = record
    Kind: TPktLineKind;
    Payload: TByteArray;
    Text: string;
  end;

  { Sideband demultiplexed payload }
  TSidebandPacket = record
    Channel: Byte; { 1 = pack, 2 = progress, 3 = error }
    Data: TByteArray;
    Text: string;
  end;

  { Packet line reader and writer }
  TPktLineStream = class
  private
    FStream: TStream;
    FOwnsStream: Boolean;
    function ReadHex4(out LengthVal: Integer): Boolean;
    procedure WriteHex4(LengthVal: Integer);
  public
    constructor Create(AStream: TStream; OwnsStream: Boolean = False);
    destructor Destroy; override;

    { Reading }
    function ReadPacket(out Pkt: TPktLine): Boolean;
    function ReadString(out S: string): Boolean;

    { Writing }
    procedure WriteFlush;
    procedure WriteDelimiter;
    procedure WriteResponseEnd;
    procedure WriteString(const S: string);
    procedure WriteBinary(const Data: Pointer; DataLen: Integer);
    procedure WriteSideband(Channel: Byte; const Data: Pointer; DataLen: Integer);
    procedure WriteSidebandString(Channel: Byte; const S: string);
  end;

function FormatPktString(const S: string): string;
function FormatPktFlush: string;
function FormatPktDelim: string;

implementation

function FormatPktString(const S: string): string;
var
  TotalLen: Integer;
begin
  TotalLen := Length(S) + 4;
  if TotalLen > 65520 then
    raise EPacketLineError.CreateWithCode(ERR_PACKET_LINE, 'Packet payload exceeds maximum length');
  Result := LowerCase(Format('%.4x', [TotalLen])) + S;
end;

function FormatPktFlush: string;
begin
  Result := PKT_FLUSH_STR;
end;

function FormatPktDelim: string;
begin
  Result := PKT_DELIM_STR;
end;

constructor TPktLineStream.Create(AStream: TStream; OwnsStream: Boolean);
begin
  inherited Create;
  FStream := AStream;
  FOwnsStream := OwnsStream;
end;

destructor TPktLineStream.Destroy;
begin
  if FOwnsStream and Assigned(FStream) then
    FStream.Free;
  inherited Destroy;
end;

function TPktLineStream.ReadHex4(out LengthVal: Integer): Boolean;
var
  Buf: array[0..3] of Char;
  I: Integer;
  V: Integer;
  C: Char;
begin
  Result := False;
  LengthVal := 0;

  if FStream.Read(Buf[0], 4) < 4 then
    Exit;

  for I := 0 to 3 do
  begin
    C := Buf[I];
    case C of
      '0'..'9': V := Ord(C) - Ord('0');
      'a'..'f': V := Ord(C) - Ord('a') + 10;
      'A'..'F': V := Ord(C) - Ord('A') + 10;
      else Exit(False);
    end;
    LengthVal := (LengthVal shl 4) or V;
  end;

  Result := True;
end;

procedure TPktLineStream.WriteHex4(LengthVal: Integer);
var
  HexStr: string;
begin
  HexStr := Format('%.4x', [LengthVal]);
  FStream.WriteBuffer(HexStr[1], 4);
end;

function TPktLineStream.ReadPacket(out Pkt: TPktLine): Boolean;
var
  Len: Integer;
  PayloadLen: Integer;
begin
  Result := False;
  Pkt.Kind := pkData;
  SetLength(Pkt.Payload, 0);
  Pkt.Text := '';

  if not ReadHex4(Len) then
    Exit;

  case Len of
    0:
    begin
      Pkt.Kind := pkFlush;
      Exit(True);
    end;
    1:
    begin
      Pkt.Kind := pkDelimiter;
      Exit(True);
    end;
    2:
    begin
      Pkt.Kind := pkResponseEnd;
      Exit(True);
    end;
    3:
    begin
      raise EPacketLineError.CreateWithCode(ERR_PACKET_LINE, 'Invalid packet line length 0003');
    end;
  end;

  PayloadLen := Len - 4;
  if PayloadLen > PKT_MAX_PAYLOAD then
    raise EPacketLineError.CreateWithCode(ERR_PACKET_LINE, 'Packet line exceeds maximum permitted size');

  SetLength(Pkt.Payload, PayloadLen);
  if PayloadLen > 0 then
  begin
    if FStream.Read(Pkt.Payload[0], PayloadLen) < PayloadLen then
      raise EPacketLineError.CreateWithCode(ERR_PACKET_LINE, 'Premature end of stream while reading packet payload');
    SetString(Pkt.Text, PChar(@Pkt.Payload[0]), PayloadLen);
    { Strip trailing newline from text if present }
    if (Length(Pkt.Text) > 0) and (Pkt.Text[Length(Pkt.Text)] = #10) then
      Pkt.Text := Copy(Pkt.Text, 1, Length(Pkt.Text) - 1);
  end;

  Result := True;
end;

function TPktLineStream.ReadString(out S: string): Boolean;
var
  Pkt: TPktLine;
begin
  Result := ReadPacket(Pkt);
  if Result and (Pkt.Kind = pkData) then
    S := Pkt.Text
  else
    S := '';
end;

procedure TPktLineStream.WriteFlush;
begin
  FStream.WriteBuffer(PKT_FLUSH_STR[1], 4);
end;

procedure TPktLineStream.WriteDelimiter;
begin
  FStream.WriteBuffer(PKT_DELIM_STR[1], 4);
end;

procedure TPktLineStream.WriteResponseEnd;
begin
  FStream.WriteBuffer(PKT_RESP_END_STR[1], 4);
end;

procedure TPktLineStream.WriteString(const S: string);
var
  Line: string;
begin
  Line := S;
  if (Line = '') or (Line[Length(Line)] <> #10) then
    Line := Line + #10;

  WriteHex4(Length(Line) + 4);
  FStream.WriteBuffer(Line[1], Length(Line));
end;

procedure TPktLineStream.WriteBinary(const Data: Pointer; DataLen: Integer);
begin
  if DataLen > PKT_MAX_PAYLOAD then
    raise EPacketLineError.CreateWithCode(ERR_PACKET_LINE, 'Binary packet exceeds maximum permitted size');

  WriteHex4(DataLen + 4);
  if DataLen > 0 then
    FStream.WriteBuffer(Data^, DataLen);
end;

procedure TPktLineStream.WriteSideband(Channel: Byte; const Data: Pointer; DataLen: Integer);
var
  TotalPktLen: Integer;
begin
  TotalPktLen := DataLen + 5; { 4 length bytes + 1 channel byte + data }
  if TotalPktLen > 65520 then
    raise EPacketLineError.CreateWithCode(ERR_PACKET_LINE, 'Sideband packet exceeds 64k limit');

  WriteHex4(TotalPktLen);
  FStream.WriteByte(Channel);
  if DataLen > 0 then
    FStream.WriteBuffer(Data^, DataLen);
end;

procedure TPktLineStream.WriteSidebandString(Channel: Byte; const S: string);
begin
  if Length(S) > 0 then
    WriteSideband(Channel, @S[1], Length(S))
  else
    WriteSideband(Channel, nil, 0);
end;

end.
