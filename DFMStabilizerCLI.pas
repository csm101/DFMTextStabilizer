unit DFMStabilizerCLI;

{
  Command-line interface for the DFM stabilizer tool.

  Argument syntax:
    DFMStabilizerTool [-s] [-a:<codepage>] <file|pattern|@listfile> [...]

    -s          Recurse into subdirectories when expanding wildcard patterns.
    -a:<cp>     Treat text DFMs with no UTF-8 BOM as being encoded in the
                given ANSI code page (e.g. -a:1250) instead of assuming
                UTF-8 without BOM. Use this for legacy DFMs that fail with
                "No mapping for the Unicode character exists in the target
                multi-byte code page".
    file        Exact path to a DFM file.
    pattern     Wildcard pattern: *.dfm, path\*.dfm, etc.
    @listfile   Text file listing one path or pattern per line.
                Lines starting with # are treated as comments.

  Exit code: 0 if all files were converted successfully, 1 if any failed.
}

interface

procedure Run;

implementation

uses
  System.SysUtils,
  System.Classes,
  DFMTextStabilizerCore;

// ---------------------------------------------------------------------------

type
  TDFMProcessor = class
  private
    FRecursive   : Boolean;
    FAnsiCodePage: Integer;
    FSuccessCount: Integer;
    FFailCount   : Integer;
    procedure ProcessFile(const AFileName: string);
    procedure ExpandAndProcess(const Pattern: string);
    procedure ProcessListFile(const AListFileName: string);
  public
    constructor Create(ARecursive: Boolean; AAnsiCodePage: Integer);
    procedure ProcessArg(const Arg: string);
    property SuccessCount: Integer read FSuccessCount;
    property FailCount   : Integer read FFailCount;
  end;

constructor TDFMProcessor.Create(ARecursive: Boolean; AAnsiCodePage: Integer);
begin
  inherited Create;
  FRecursive    := ARecursive;
  FAnsiCodePage := AAnsiCodePage;
  FSuccessCount := 0;
  FFailCount    := 0;
end;

procedure TDFMProcessor.ProcessFile(const AFileName: string);
begin
  try
    Write('  ', AFileName, ' ... ');
    if ConvertDFMFile(AFileName, FAnsiCodePage) then
      Writeln('converted')
    else
      Writeln('already up to date');
    Inc(FSuccessCount);
  except
    on E: Exception do
    begin
      Writeln('FAILED: ', E.Message);
      Inc(FFailCount);
    end;
  end;
end;

// Expand a pattern (which may contain * or ?) into actual files, then process
// each one.  If FRecursive is True, descend into subdirectories as well.
procedure TDFMProcessor.ExpandAndProcess(const Pattern: string);
var
  Dir    : string;
  FilePat: string;
  SR     : TSearchRec;
begin
  Dir     := ExtractFilePath(Pattern);
  FilePat := ExtractFileName(Pattern);
  if Dir = '' then
    Dir := '.';

  // Files matching the pattern in this directory
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + FilePat, faAnyFile, SR) = 0 then
  begin
    try
      repeat
        if (SR.Attr and faDirectory) = 0 then
          ProcessFile(IncludeTrailingPathDelimiter(Dir) + SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;

  // Recurse into subdirectories
  if FRecursive then
  begin
    if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faDirectory, SR) = 0 then
    begin
      try
        repeat
          if ((SR.Attr and faDirectory) <> 0) and
             (SR.Name <> '.') and (SR.Name <> '..') then
            ExpandAndProcess(
              IncludeTrailingPathDelimiter(Dir) + SR.Name +
              PathDelim + FilePat);
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
    end;
  end;
end;

procedure TDFMProcessor.ProcessListFile(const AListFileName: string);
var
  List: TStringList;
  I   : Integer;
  Line: string;
begin
  if not FileExists(AListFileName) then
    raise EFileNotFoundException.CreateFmt('List file not found: %s', [AListFileName]);

  List := TStringList.Create;
  try
    List.LoadFromFile(AListFileName);
    for I := 0 to List.Count - 1 do
    begin
      Line := Trim(List[I]);
      if (Line <> '') and not Line.StartsWith('#') then
        ProcessArg(Line);
    end;
  finally
    List.Free;
  end;
end;

procedure TDFMProcessor.ProcessArg(const Arg: string);
begin
  if Arg.StartsWith('@') then
    ProcessListFile(Arg.Substring(1))
  else if (Pos('*', Arg) > 0) or (Pos('?', Arg) > 0) then
    ExpandAndProcess(Arg)
  else
    ProcessFile(Arg);
end;

// ---------------------------------------------------------------------------

const
  AnsiCodePageSwitch = '-a:';

function IsAnsiCodePageArg(const Arg: string): Boolean;
begin
  Result := Arg.StartsWith(AnsiCodePageSwitch, True);
end;

// Extract the numeric code page from an "-a:<codepage>" argument.
// Accepts a bare number (-a:1250) or a name containing one (-a:CP1250).
function ExtractAnsiCodePage(const Arg: string): Integer;
var
  Value : string;
  Digits: string;
  C     : Char;
begin
  Value := Arg.Substring(Length(AnsiCodePageSwitch));
  Digits := '';
  for C in Value do
    if CharInSet(C, ['0'..'9']) then
      Digits := Digits + C;
  if not TryStrToInt(Digits, Result) then
    raise Exception.CreateFmt('Invalid ANSI code page: "%s"', [Arg]);
end;

procedure PrintUsage;
begin
  Writeln('Usage: DFMStabilizerTool [-s] [-a:<codepage>] <file|pattern|@listfile> [...]');
  Writeln;
  Writeln('Converts DFM files in-place to the stabilized UTF-8 text format:');
  Writeln('  - strings are not broken at 64 characters (limit raised to 700)');
  Writeln('  - embedded newlines (#13/#10) cause a line break at that position');
  Writeln('  - non-ASCII characters are written literally as UTF-8');
  Writeln('  - file always starts with a UTF-8 BOM');
  Writeln;
  Writeln('Options:');
  Writeln('  -s          Recurse into subdirectories when expanding wildcard patterns');
  Writeln('  -a:<cp>     Decode text DFMs with no UTF-8 BOM using ANSI code page <cp>');
  Writeln('              (e.g. -a:1250 for Central European / Czech) instead of');
  Writeln('              assuming UTF-8 without BOM. Use this if conversion fails with');
  Writeln('              "No mapping for the Unicode character exists in the target');
  Writeln('              multi-byte code page".');
  Writeln;
  Writeln('Arguments:');
  Writeln('  file        Exact path to a DFM file');
  Writeln('  pattern     Wildcard pattern  (e.g.  *.dfm   or   forms\*.dfm)');
  Writeln('  @listfile   Text file with one path/pattern per line (# = comment)');
  Writeln;
  Writeln('Examples:');
  Writeln('  DFMStabilizerTool MainForm.dfm');
  Writeln('  DFMStabilizerTool -s *.dfm');
  Writeln('  DFMStabilizerTool -s src\*.dfm @extra_forms.txt');
  Writeln('  DFMStabilizerTool @all_forms.txt');
  Writeln('  DFMStabilizerTool -a:1250 legacy\*.dfm');
end;

// ---------------------------------------------------------------------------

procedure Run;
var
  Recursive   : Boolean;
  AnsiCodePage: Integer;
  Processor   : TDFMProcessor;
  I           : Integer;
  Arg         : string;
begin
  if ParamCount = 0 then
  begin
    PrintUsage;
    Halt(1);
  end;

  Recursive    := False;
  AnsiCodePage := 0;
  for I := 1 to ParamCount do
  begin
    Arg := ParamStr(I);
    if SameText(Arg, '-s') then
      Recursive := True
    else if IsAnsiCodePageArg(Arg) then
      AnsiCodePage := ExtractAnsiCodePage(Arg);
  end;

  Processor := TDFMProcessor.Create(Recursive, AnsiCodePage);
  try
    for I := 1 to ParamCount do
    begin
      Arg := ParamStr(I);
      if SameText(Arg, '-s') or IsAnsiCodePageArg(Arg) then
        Continue;
      Processor.ProcessArg(Arg);
    end;

    Writeln;
    if Processor.SuccessCount + Processor.FailCount = 0 then
      Writeln('No files matched.')
    else
      Writeln(Format('%d converted, %d failed.',
        [Processor.SuccessCount, Processor.FailCount]));

    if Processor.FailCount > 0 then
      Halt(1);
  finally
    Processor.Free;
  end;
end;

end.
