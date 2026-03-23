unit DFMTextStabilizerCore;

{
  Core DFM text stabilization logic, shared between the IDE plugin
  (DFMBinaryToTextHook) and the command-line conversion tool (DFMStabilizerTool).

  DFMBinaryToText — converts a binary DFM stream to the stabilized text format.
                    Identical algorithm to the patched ObjectBinaryToText in the
                    IDE plugin.  Call this instead of reimplementing the logic.

  ConvertDFMFile  — converts a DFM file in-place to the stabilized text format.
                    Accepts both text DFMs (UTF-8 with/without BOM, ANSI) and
                    legacy binary DFMs.  The original file is replaced atomically
                    via a temporary file.
}

interface

uses
  System.Classes;

// Convert a binary DFM stream to stabilized text.
// Input must be positioned at the binary DFM signature (as produced by TWriter).
// Output receives the UTF-8 BOM followed by the formatted DFM text.
procedure DFMBinaryToText(const Input, Output: TStream);

// Convert AFileName in-place to the stabilized text format.
// Raises an exception if the file cannot be read, parsed, or written.
procedure ConvertDFMFile(const AFileName: string);

implementation

uses
  System.SysUtils,
  System.IOUtils;

// ---------------------------------------------------------------------------
// Core binary-to-text conversion
// (algorithm extracted from HookedObjectBinaryToText in DFMBinaryToTextHook)
// ---------------------------------------------------------------------------

procedure DFMBinaryToText(const Input, Output: TStream);
var
  NestingLevel   : Integer;
  Reader         : TReader;
  Writer         : TWriter;
  ObjectName     : string;
  PropName       : string;
  MemoryStream   : TMemoryStream;
  LFormatSettings: TFormatSettings;
  BOM            : TBytes;

  procedure WriteTBytes(const S: TBytes);
  begin
    if Length(S) > 0 then
      Writer.Write(S[0], Length(S));
  end;

  procedure WriteAsciiStr(const S: string);
  var
    Buf: TBytes;
    I: Integer;
  begin
    SetLength(Buf, S.Length);
    for I := Low(S) to High(S) do
      Buf[I - Low(S)] := Byte(S[I]);
    if Length(Buf) > 0 then
      Writer.Write(Buf[0], Length(Buf));
  end;

  procedure WriteUTF8Str(const S: string);
  begin
    WriteTBytes(TEncoding.UTF8.GetBytes(S));
  end;

  procedure WriteIndent;
  var
    Buf: TBytes;
    I: Integer;
  begin
    Buf := TBytes.Create($20, $20);
    for I := 1 to NestingLevel do
      Writer.Write(Buf[0], Length(Buf));
  end;

  procedure NewLine;
  begin
    WriteAsciiStr(sLineBreak);
    WriteIndent;
  end;

  procedure ConvertValue; forward;

  // -- object header: "object/inherited/inline ClassName: Name" -------------

  procedure ConvertHeader;
  var
    ClassName: string;
    Flags    : TFilerFlags;
    Position : Integer;
  begin
    Reader.ReadPrefix(Flags, Position);
    ClassName  := Reader.ReadStr;
    ObjectName := Reader.ReadStr;
    WriteIndent;
    if ffInherited in Flags then
      WriteAsciiStr('inherited ')
    else if ffInline in Flags then
      WriteAsciiStr('inline ')
    else
      WriteAsciiStr('object ');
    if ObjectName <> '' then
    begin
      WriteUTF8Str(ObjectName);
      WriteAsciiStr(': ');
    end;
    WriteUTF8Str(ClassName);
    if ffChildPos in Flags then
    begin
      WriteAsciiStr(' [');
      WriteAsciiStr(IntToStr(Position));
      WriteAsciiStr(']');
    end;
    if ObjectName = '' then
      ObjectName := ClassName;
    WriteAsciiStr(sLineBreak);
  end;

  // -- binary data block: { hex... } ----------------------------------------

  procedure ConvertBinary;
  const
    BytesPerLine = 32;
  var
    MultiLine   : Boolean;
    I, Count    : Integer;
    Buffer, Text: TBytes;
  begin
    SetLength(Buffer, BytesPerLine);
    SetLength(Text,   BytesPerLine * 2 + 1);
    Reader.ReadValue;
    WriteAsciiStr('{');
    Inc(NestingLevel);
    Reader.Read(Count, SizeOf(Count));
    MultiLine := Count >= BytesPerLine;
    while Count > 0 do
    begin
      if MultiLine then NewLine;
      if Count >= 32 then I := 32 else I := Count;
      Reader.Read(Buffer[0], I);
      BinToHex(Buffer, 0, Text, 0, I);
      Writer.Write(Text[0], I * 2);
      Dec(Count, I);
    end;
    Dec(NestingLevel);
    WriteAsciiStr('}');
  end;

  procedure ConvertProperty; forward;

  // -- property value --------------------------------------------------------

  procedure ConvertValue;
  const
    LineLength = 700;  // [M1] was 64
  var
    I, J, K, L: Integer;
    S, W      : string;
    LineBreak : Boolean;
  begin
    case Reader.NextValue of

      vaList:
        begin
          Reader.ReadValue;
          WriteAsciiStr('(');
          Inc(NestingLevel);
          while not Reader.EndOfList do
          begin
            NewLine;
            ConvertValue;
          end;
          Reader.ReadListEnd;
          Dec(NestingLevel);
          WriteAsciiStr(')');
        end;

      vaInt8, vaInt16, vaInt32:
        WriteAsciiStr(IntToStr(Reader.ReadInteger));

      vaExtended, vaDouble:
        WriteAsciiStr(FloatToStrF(Reader.ReadFloat, ffFixed, 16, 18, LFormatSettings));

      vaSingle:
        WriteAsciiStr(FloatToStr(Reader.ReadSingle, LFormatSettings) + 's');

      vaCurrency:
        WriteAsciiStr(FloatToStr(Reader.ReadCurrency * 10000, LFormatSettings) + 'c');

      vaDate:
        WriteAsciiStr(FloatToStr(Reader.ReadDate, LFormatSettings) + 'd');

      // -- Unicode strings (the common case in modern DFMs) ------------------
      vaWString, vaUTF8String:
        begin
          W := Reader.ReadString;
          L := High(W);
          if L = High('') then
            WriteAsciiStr('''''')
          else
          begin
            I := Low(W);
            Inc(NestingLevel);
            try
              if L > LineLength then NewLine;
              K := I;
              repeat
                LineBreak := False;
                // [M2] removed "and (Ord(W[I]) <= 127)": non-ASCII chars included in the literal
                if (W[I] >= ' ') and (W[I] <> '''') then
                begin
                  J := I;
                  // [M2] removed "or (Ord(W[I]) > 127)"
                  repeat
                    Inc(I)
                  until (I > L) or (W[I] < ' ') or (W[I] = '''') or
                    ((I - K) >= LineLength);
                  if (I - K) >= LineLength then LineBreak := True;
                  WriteAsciiStr('''');
                  // [M2] write UTF-8 bytes directly instead of WriteByte(Byte(W[J]))
                  WriteTBytes(TEncoding.UTF8.GetBytes(W.Substring(J - Low(W), I - J)));
                  WriteAsciiStr('''');
                end
                else
                begin
                  // control characters and apostrophe -> #xxx (standard DFM escape)
                  WriteAsciiStr('#');
                  WriteAsciiStr(IntToStr(Ord(W[I])));
                  // Break after embedded newlines for readability.
                  // CR+LF: keep the pair together, break after the LF.
                  // Standalone CR or LF: break immediately after.
                  if W[I] = #10 then
                    LineBreak := True
                  else if (W[I] = #13) and ((I >= L) or (W[I + 1] <> #10)) then
                    LineBreak := True;
                  Inc(I);
                  if (not LineBreak) and ((I - K) >= LineLength) then
                    LineBreak := True;
                end;
                if LineBreak and (I <= L) then
                begin
                  WriteAsciiStr(' +');
                  NewLine;
                  K := I;
                end;
              until I > L;
            finally
              Dec(NestingLevel);
            end;
          end;
        end;

      // -- ANSI strings (legacy, rarely seen in modern DFMs) -----------------
      vaString, vaLString:
        begin
          S := Reader.ReadString;
          L := High(S);
          if L = High('') then
            WriteAsciiStr('''''')
          else
          begin
            I := Low(S);
            Inc(NestingLevel);
            try
              if L > LineLength then NewLine;
              K := I;
              repeat
                LineBreak := False;
                if (S[I] >= ' ') and (S[I] <> '''') then
                begin
                  J := I;
                  repeat
                    Inc(I)
                  until (I > L) or (S[I] < ' ') or (S[I] = '''') or
                    ((I - K) >= LineLength);
                  if (I - K) >= LineLength then LineBreak := True;
                  WriteAsciiStr('''');
                  // UTF-8 for vaString/vaLString too, for consistency with the BOM
                  WriteTBytes(TEncoding.UTF8.GetBytes(S.Substring(J - Low(S), I - J)));
                  WriteAsciiStr('''');
                end
                else
                begin
                  WriteAsciiStr('#');
                  WriteAsciiStr(IntToStr(Ord(S[I])));
                  // Break after embedded newlines for readability.
                  // CR+LF: keep the pair together, break after the LF.
                  // Standalone CR or LF: break immediately after.
                  if Ord(S[I]) = 10 then
                    LineBreak := True
                  else if (Ord(S[I]) = 13) and ((I >= L) or (Ord(S[I + 1]) <> 10)) then
                    LineBreak := True;
                  Inc(I);
                  if (not LineBreak) and ((I - K) >= LineLength) then
                    LineBreak := True;
                end;
                if LineBreak and (I <= L) then
                begin
                  WriteAsciiStr(' +');
                  NewLine;
                  K := I;
                end;
              until I > L;
            finally
              Dec(NestingLevel);
            end;
          end;
        end;

      vaIdent, vaFalse, vaTrue, vaNil, vaNull:
        WriteUTF8Str(Reader.ReadIdent);

      vaBinary:
        ConvertBinary;

      vaSet:
        begin
          Reader.ReadValue;
          WriteAsciiStr('[');
          I := 0;
          while True do
          begin
            S := Reader.ReadStr;
            if S = '' then Break;
            if I > 0 then WriteAsciiStr(', ');
            WriteUTF8Str(S);
            Inc(I);
          end;
          WriteAsciiStr(']');
        end;

      vaCollection:
        begin
          Reader.ReadValue;
          WriteAsciiStr('<');
          Inc(NestingLevel);
          while not Reader.EndOfList do
          begin
            NewLine;
            WriteAsciiStr('item');
            if Reader.NextValue in [vaInt8, vaInt16, vaInt32] then
            begin
              WriteAsciiStr(' [');
              ConvertValue;
              WriteAsciiStr(']');
            end;
            WriteAsciiStr(sLineBreak);
            Reader.CheckValue(vaList);
            Inc(NestingLevel);
            while not Reader.EndOfList do
              ConvertProperty;
            Reader.ReadListEnd;
            Dec(NestingLevel);
            WriteIndent;
            WriteAsciiStr('end');
          end;
          Reader.ReadListEnd;
          Dec(NestingLevel);
          WriteAsciiStr('>');
        end;

      vaInt64:
        WriteAsciiStr(IntToStr(Reader.ReadInt64));

    else
      raise EReadError.CreateFmt(
        'Error reading %s.%s: unknown value type %d',
        [ObjectName, PropName, Ord(Reader.NextValue)]);
    end;
  end;

  // -- single property: "Name = Value" --------------------------------------

  procedure ConvertProperty;
  begin
    WriteIndent;
    PropName := Reader.ReadStr;
    WriteUTF8Str(PropName);
    WriteAsciiStr(' = ');
    ConvertValue;
    WriteAsciiStr(sLineBreak);
  end;

  // -- recursive object conversion ------------------------------------------

  procedure ConvertObject;
  begin
    ConvertHeader;
    Inc(NestingLevel);
    while not Reader.EndOfList do
      ConvertProperty;
    Reader.ReadListEnd;
    while not Reader.EndOfList do
      ConvertObject;
    Reader.ReadListEnd;
    Dec(NestingLevel);
    WriteIndent;
    WriteAsciiStr('end' + sLineBreak);
  end;

// -- main body ---------------------------------------------------------------
begin
  NestingLevel    := 0;
  LFormatSettings := TFormatSettings.Create('en-US');
  LFormatSettings.DecimalSeparator := '.';

  Reader := TReader.Create(Input, 4096);
  try
    MemoryStream := TMemoryStream.Create;
    try
      Writer := TWriter.Create(MemoryStream, 4096);
      try
        Reader.ReadSignature;
        ConvertObject;
      finally
        Writer.Free;
      end;

      // [M3] Always write the UTF-8 BOM before the content
      BOM := TEncoding.UTF8.GetPreamble;
      Output.Write(BOM[0], Length(BOM));
      Output.Write(MemoryStream.Memory^, MemoryStream.Size);
    finally
      MemoryStream.Free;
    end;
  finally
    Reader.Free;
  end;
end;

// ---------------------------------------------------------------------------
// File-level conversion
// ---------------------------------------------------------------------------

function IsBinaryDFM(Stream: TStream): Boolean;
var
  Sig    : array[0..1] of Byte;
  SavePos: Int64;
begin
  SavePos := Stream.Position;
  Result  := (Stream.Read(Sig, 2) = 2) and (Sig[0] = $FF) and (Sig[1] = $0A);
  Stream.Position := SavePos;
end;

procedure ConvertDFMFile(const AFileName: string);
var
  FileContent : TMemoryStream;
  BinaryStream: TMemoryStream;
  OutputStream: TMemoryStream;
  BOM         : TBytes;
  BOMLen      : Integer;
  TmpFileName : string;
  OutFile     : TFileStream;
begin
  FileContent  := TMemoryStream.Create;
  BinaryStream := TMemoryStream.Create;
  OutputStream := TMemoryStream.Create;
  try
    FileContent.LoadFromFile(AFileName);
    FileContent.Position := 0;

    if IsBinaryDFM(FileContent) then
    begin
      // Binary DFM: feed directly into the stabilization conversion
      DFMBinaryToText(FileContent, OutputStream);
    end
    else
    begin
      // Text DFM (UTF-8 with/without BOM, or ANSI):
      // skip the BOM if present, then round-trip through ObjectTextToBinary
      // so that we get a proper binary stream to feed DFMBinaryToText.
      BOM    := TEncoding.UTF8.GetPreamble;
      BOMLen := Length(BOM);
      if (BOMLen > 0) and (FileContent.Size >= BOMLen) and
         CompareMem(FileContent.Memory, @BOM[0], BOMLen) then
        FileContent.Position := BOMLen
      else
        FileContent.Position := 0;

      ObjectTextToBinary(FileContent, BinaryStream);
      BinaryStream.Position := 0;
      DFMBinaryToText(BinaryStream, OutputStream);
    end;

    // Skip writing if the stabilized output is byte-for-byte identical to the
    // original file — avoids spurious VCS changes on already-stabilized files.
    if (OutputStream.Size = FileContent.Size) and
       CompareMem(OutputStream.Memory, FileContent.Memory, OutputStream.Size) then
      Exit;

    // Write result atomically: write to temp, then replace the original.
    TmpFileName := AFileName + '.dfmstab.tmp';
    try
      OutFile := TFileStream.Create(TmpFileName, fmCreate);
      try
        OutFile.Write(OutputStream.Memory^, OutputStream.Size);
      finally
        OutFile.Free;
      end;

      if TFile.Exists(AFileName) then
        TFile.Delete(AFileName);
      TFile.Move(TmpFileName, AFileName);
    except
      if TFile.Exists(TmpFileName) then
        TFile.Delete(TmpFileName);
      raise;
    end;

  finally
    OutputStream.Free;
    BinaryStream.Free;
    FileContent.Free;
  end;
end;

end.
