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
  DDetours,
  DFMTextStabilizerCore;


// ---------------------------------------------------------------------------
// Diagnostics
//
//   Log file: %TEMP%\DFMHook.log  (appended; survives IDE crashes)
//   OutputDebugString: prefix “DFMHook:” — visible in DebugView or IDE Event Log
//
// Remove this entire section (and all DiagLog calls) once the hook is
// confirmed stable.
// ---------------------------------------------------------------------------

var
  GDiagLogPath: string = '';

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
// Hook body: delegates to DFMTextStabilizerCore.DFMBinaryToText.
// The conversion logic lives in the core unit, shared with the CLI tool.
// ---------------------------------------------------------------------------
procedure HookedObjectBinaryToText(const Input, Output: TStream);
begin
  DiagLogFmt('HookedObjectBinaryToText: entered  Input=%p  Output=%p',
    [Pointer(Input), Pointer(Output)]);
  try
    DFMBinaryToText(Input, Output);
    DiagLog('HookedObjectBinaryToText: completed successfully');
  except
    on E: Exception do
    begin
      DiagLogFmt('HookedObjectBinaryToText EXCEPTION: %s: %s',
        [E.ClassName, E.Message]);
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
