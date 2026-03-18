unit DFMBinaryToTextHook;

{
  Installs two runtime hooks on System.Classes:

  [Hook 1] ObjectBinaryToText  (binary -> text, called on every .dfm save)

    [M1] Raises the string line-break limit from 64 to 700 characters.
         Strings that contain embedded #13/#10 newline sequences are also
         broken at those positions, so the logical structure of the string
         is visible in the file layout.

    [M2] Writes non-ASCII characters literally as UTF-8 instead of as
         #xxx numeric escape sequences.

    [M3] Always writes the UTF-8 BOM at the start of the .dfm file, so
         the Delphi command-line compiler and all other tools can reliably
         detect the UTF-8 encoding.

  [Hook 2] ObjectTextToBinary  (text -> binary, called on "View as Form")

    The Delphi "Text Form" editor displays the BOM as a cosmetic glitch
    on the first line and lets the user accidentally delete it.  If the
    BOM is missing when the user switches back to the form designer, the
    original ObjectTextToBinary would interpret UTF-8 bytes as ANSI and
    silently corrupt all non-ASCII characters in memory.  This hook
    detects non-ASCII content without a BOM and transparently prepends
    the BOM in a temporary in-memory stream before delegating to the
    original, so the round-trip is always correct regardless of what the
    user did in the text editor.

  Usage:
    Add this unit to a design-time package.  Register (called automatically
    by the IDE when the package is loaded) installs both hooks.  The
    finalization section removes them when the package is unloaded.

  Dependencies:
    - DDetours (C:\Athens\ddetours\Source\DDetours.pas)
}

interface

Procedure Register;

implementation

uses
  System.Classes,
  System.SysUtils,
  Winapi.Windows,
  DDetours;


// ---------------------------------------------------------------------------
// Diagnostics
//
//   Log file: %TEMP%\DFMHook.log  (appended; survives IDE crashes)
//   OutputDebugString: prefix "DFMHook:" â€” visible in DebugView or IDE Event Log
//   GCheckpoint: last integer written before crash â€” inspect in debugger
//
// Remove this entire section (and all DiagLog / GCheckpoint calls) once the
// hook is confirmed stable.
// ---------------------------------------------------------------------------

var
  GDiagLogPath : string = '';
  GCheckpoint  : Integer = 0;  // last reached step; readable in debugger after crash

procedure DiagLog(const Msg: string);
var
  F   : TextFile;
  Line: string;
begin
  Line := FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + Msg;
  OutputDebugString(PChar('DFMHook: ' + Line));
  if GDiagLogPath = '' then Exit;
  try
    AssignFile(F, GDiagLogPath);
    if FileExists(GDiagLogPath) then
      Append(F)
    else
      Rewrite(F);
    try
      Writeln(F, Line);
    finally
      CloseFile(F);
    end;
  except
    // never let the diagnostic itself crash anything
  end;
end;

procedure DiagLogFmt(const Fmt: string; const Args: array of const);
begin
  DiagLog(Format(Fmt, Args));
end;


// ---------------------------------------------------------------------------
// Symbol resolution for ObjectBinaryToText
//
// On 64-bit Delphi, the PPointer(@ProcVar)^ trick to extract a code address
// from a typed procedure variable does NOT work: the assignment stores an
// import-thunk address whose first bytes are not a valid canonical pointer,
// which causes DDetours to AV immediately.
//
// The fix: use the InterceptCreate(Module, MethodName, ...) overload, which
// internally calls GetProcAddress on the already-loaded RTL BPL.  No typed
// procedure variable is needed; the compiler-mangled export name is used
// directly.
//
// Export names verified by inspecting rtl290.bpl with dumpbin.
// The 64-bit mangled name and the 32-bit name are stable across versions
// because the function signature has not changed.
//
// RTL BPL suffix = VERnumber - 70  (same pattern as designide*.bpl).
//   Verified: VER360 â†’ rtl290.bpl.  Others follow the same pattern.
// ---------------------------------------------------------------------------

const
{$IFDEF WIN64}
  CObjectBinaryToTextSymbol = '_ZN6System7Classes18ObjectBinaryToTextEPNS0_7TStreamES2_';
  CObjectTextToBinarySymbol = '_ZN6System7Classes18ObjectTextToBinaryEPNS0_7TStreamES2_';
{$ELSE}
  CObjectBinaryToTextSymbol = '@System@Classes@ObjectBinaryToText$qqrxp22System@Classes@TStreamt1';
  CObjectTextToBinarySymbol = '@System@Classes@ObjectTextToBinary$qqrxp22System@Classes@TStreamt1';
{$ENDIF}

  CRTLModuleName =   // se da errore in compilazione, aggiungere la riga per il compilatore in uso
{$IF   Defined(VER220)} 'rtl150.bpl'   // Delphi XE
{$ELSEIF Defined(VER260)} 'rtl190.bpl' // Delphi XE6  (Studio 19.0)
{$ELSEIF Defined(VER290)} 'rtl220.bpl' // Delphi XE8  (Studio 22.0)
{$ELSEIF Defined(VER310)} 'rtl240.bpl' // Delphi 10   (Studio 24.0)
{$ELSEIF Defined(VER330)} 'rtl260.bpl' // Delphi 10.3 Rio
{$ELSEIF Defined(VER350)} 'rtl280.bpl' // Delphi 11 Alexandria
{$ELSEIF Defined(VER360)} 'rtl290.bpl' // Delphi 12 Athens   (verified)
{$ELSEIF Defined(VER370)} 'rtl300.bpl' // Delphi 13 Florence
{$ELSE} {$MESSAGE ERROR 'DFMBinaryToTextHook: aggiungere il nome del BPL RTL per questa versione di Delphi'}
{$IFEND};

var
  GTrampoline            : Pointer = nil;
  GTextToBinaryTrampoline: Pointer = nil;

// ---------------------------------------------------------------------------
// Modified reimplementation of ObjectBinaryToText
// Original source: System.Classes.pas ~line 15224
// ---------------------------------------------------------------------------
procedure HookedObjectBinaryToText(const Input, Output: TStream);
var
  NestingLevel   : Integer;
  Reader         : TReader;
  Writer         : TWriter;
  ObjectName     : string;
  PropName       : string;
  MemoryStream   : TMemoryStream;
  LFormatSettings: TFormatSettings;
  BOM            : TBytes;

  // -- write helpers (output goes to MemoryStream via TWriter) ---------------

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
  var
    Ident: TBytes;
  begin
    Ident := TEncoding.UTF8.GetBytes(S);
    WriteTBytes(Ident);
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

  // -- forward declarations --------------------------------------------------
  // (ConvertValue and ConvertProperty are mutually recursive)

  procedure ConvertValue; forward;

  // -- object header: "object/inherited/inline ClassName: Name" -------------

  procedure ConvertHeader;
  var
    ClassName : string;
    Flags     : TFilerFlags;
    Position  : Integer;
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
    I, J, K, L : Integer;
    S, W        : string;
    LineBreak   : Boolean;
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

  // -- recursive object conversion -------------------------------------------

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
  GCheckpoint := 100;
  DiagLogFmt('HookedObjectBinaryToText: entered  Input=%p  Output=%p',
    [Pointer(Input), Pointer(Output)]);
  try
    NestingLevel := 0;
    GCheckpoint  := 101;

    LFormatSettings := TFormatSettings.Create('en-US');
    LFormatSettings.DecimalSeparator := '.';
    GCheckpoint := 102;

    Reader := TReader.Create(Input, 4096);
    GCheckpoint := 103;
    DiagLog('  TReader created');
    try
      MemoryStream := TMemoryStream.Create;
      GCheckpoint := 104;
      DiagLog('  TMemoryStream created');
      try
        Writer := TWriter.Create(MemoryStream, 4096);
        GCheckpoint := 105;
        DiagLog('  TWriter created');
        try
          Reader.ReadSignature;
          GCheckpoint := 106;
          DiagLog('  ReadSignature OK');
          ConvertObject;
          GCheckpoint := 107;
          DiagLog('  ConvertObject OK');
        finally
          Writer.Free;
        end;

        // [M3] Always write the UTF-8 BOM before the content
        BOM := TEncoding.UTF8.GetPreamble;
        GCheckpoint := 108;
        Output.Write(BOM[0], Length(BOM));
        Output.Write(MemoryStream.Memory^, MemoryStream.Size);
        GCheckpoint := 109;
        DiagLog('  Output written OK');

      finally
        MemoryStream.Free;
      end;
    finally
      Reader.Free;
    end;

    DiagLog('HookedObjectBinaryToText: completed successfully');

  except
    on E: Exception do
    begin
      DiagLogFmt('HookedObjectBinaryToText EXCEPTION at checkpoint %d: %s: %s',
        [GCheckpoint, E.ClassName, E.Message]);
      raise;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Hook on ObjectTextToBinary
//
// When the user edits the DFM in the IDE source editor and then switches to
// "View as Form", the IDE passes the editor buffer to ObjectTextToBinary to
// reconstruct the binary form in memory.  If the user has accidentally deleted
// the UTF-8 BOM from the first line (it appears as a visual glitch there),
// the original ObjectTextToBinary will interpret the UTF-8 bytes as ANSI and
// corrupt all non-ASCII characters — entirely in RAM, with no file I/O
// involved.  This hook detects that situation and transparently prepends the
// BOM before delegating to the original, so the conversion is always correct.
// ---------------------------------------------------------------------------

function ContainsNonAscii(const Buf: TBytes): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Buf) do
    if Buf[I] > 127 then Exit(True);
  Result := False;
end;

procedure HookedObjectTextToBinary(const Input, Output: TStream);
type
  TProc = procedure(const Input, Output: TStream);
var
  OrigPos   : Int64;
  InputBytes: TBytes;
  BOM       : TBytes;
  Patched   : TMemoryStream;
begin
  DiagLogFmt('HookedObjectTextToBinary: entered  Input=%p  Output=%p',
    [Pointer(Input), Pointer(Output)]);

  OrigPos := Input.Position;
  SetLength(InputBytes, Input.Size - OrigPos);
  if Length(InputBytes) > 0 then
    Input.Read(InputBytes[0], Length(InputBytes));

  // Already has UTF-8 BOM -> pass through unchanged
  if (Length(InputBytes) >= 3) and
     (InputBytes[0] = $EF) and (InputBytes[1] = $BB) and (InputBytes[2] = $BF) then
  begin
    DiagLog('HookedObjectTextToBinary: BOM present — pass-through');
    Input.Position := OrigPos;
    TProc(GTextToBinaryTrampoline)(Input, Output);
    Exit;
  end;

  // Pure ASCII -> pass through unchanged (no BOM needed, no risk of corruption)
  if not ContainsNonAscii(InputBytes) then
  begin
    DiagLog('HookedObjectTextToBinary: pure ASCII — pass-through');
    Input.Position := OrigPos;
    TProc(GTextToBinaryTrampoline)(Input, Output);
    Exit;
  end;

  // Non-ASCII without BOM: prepend BOM in a temporary stream so the original
  // ObjectTextToBinary interprets the content as UTF-8 instead of ANSI
  DiagLog('HookedObjectTextToBinary: non-ASCII without BOM — prepending BOM in memory');
  BOM := TEncoding.UTF8.GetPreamble;
  Patched := TMemoryStream.Create;
  try
    Patched.Write(BOM[0], Length(BOM));
    if Length(InputBytes) > 0 then
      Patched.Write(InputBytes[0], Length(InputBytes));
    Patched.Position := 0;
    TProc(GTextToBinaryTrampoline)(Patched, Output);
  finally
    Patched.Free;
  end;
  DiagLog('HookedObjectTextToBinary: completed');
end;

// ---------------------------------------------------------------------------

procedure InstallDFMTextToBinaryHook;
begin
  if GTextToBinaryTrampoline <> nil then Exit;
  DiagLog('InstallDFMTextToBinaryHook: starting');
  DiagLogFmt('  Symbol=%s', [CObjectTextToBinarySymbol]);
  try
    GTextToBinaryTrampoline := InterceptCreate(CRTLModuleName, CObjectTextToBinarySymbol,
                                               @HookedObjectTextToBinary);
    if GTextToBinaryTrampoline <> nil then
      DiagLogFmt('  Hook installed OK — trampoline = %p', [GTextToBinaryTrampoline])
    else
      DiagLog('  ERROR: InterceptCreate returned nil — symbol not found in module');
  except
    on E: Exception do
      DiagLogFmt('  EXCEPTION in InterceptCreate: %s: %s', [E.ClassName, E.Message]);
  end;
end;

procedure UninstallDFMTextToBinaryHook;
begin
  if GTextToBinaryTrampoline = nil then Exit;
  DiagLog('UninstallDFMTextToBinaryHook: removing hook');
  InterceptRemove(GTextToBinaryTrampoline);
  GTextToBinaryTrampoline := nil;
  DiagLog('UninstallDFMTextToBinaryHook: done');
end;

// ---------------------------------------------------------------------------

procedure InstallDFMBinaryToTextHook;
begin
  if GTrampoline <> nil then
  begin
    DiagLog('InstallDFMBinaryToTextHook: already installed, skipping');
    Exit;
  end;

  DiagLogFmt('InstallDFMBinaryToTextHook: starting  SizeOf(Pointer)=%d', [SizeOf(Pointer)]);
  DiagLogFmt('  Module=%s', [CRTLModuleName]);
  DiagLogFmt('  Symbol=%s', [CObjectBinaryToTextSymbol]);
  try
    GTrampoline := InterceptCreate(CRTLModuleName, CObjectBinaryToTextSymbol, @HookedObjectBinaryToText);

    if GTrampoline <> nil then
      DiagLogFmt('  Hook installed OK â€” trampoline = %p', [GTrampoline])
    else
      DiagLog('  ERROR: InterceptCreate returned nil â€” symbol not found in module');

  except
    on E: Exception do
      DiagLogFmt('  EXCEPTION in InterceptCreate: %s: %s', [E.ClassName, E.Message]);
  end;
end;

procedure UninstallDFMBinaryToTextHook;
begin
  if GTrampoline = nil then Exit;
  DiagLog('UninstallDFMBinaryToTextHook: removing hook');
  InterceptRemove(GTrampoline);
  GTrampoline := nil;
  DiagLog('UninstallDFMBinaryToTextHook: done');
end;


Procedure Register;
begin
  InstallDFMBinaryToTextHook;
  InstallDFMTextToBinaryHook;
end;

initialization
  GDiagLogPath := GetEnvironmentVariable('TEMP') + '\DFMHook.log';
  DiagLog('=== DFMBinaryToTextHook unit initialized ===');
  DiagLogFmt('  SizeOf(Pointer) = %d bytes', [SizeOf(Pointer)]);
finalization
  UninstallDFMTextToBinaryHook;
  UninstallDFMBinaryToTextHook;
  DiagLog('=== DFMBinaryToTextHook unit finalized ===');
end.
