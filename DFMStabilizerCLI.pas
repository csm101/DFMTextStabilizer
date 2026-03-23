unit DFMStabilizerCLI;

{
  Command-line interface for the DFM stabilizer tool.

  Argument syntax:
    DFMStabilizerTool [-s] <file|pattern|@listfile> [...]

    -s          Recurse into subdirectories when expanding wildcard patterns.
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
    FSuccessCount: Integer;
    FFailCount   : Integer;
    procedure ProcessFile(const AFileName: string);
    procedure ExpandAndProcess(const Pattern: string);
    procedure ProcessListFile(const AListFileName: string);
  public
    constructor Create(ARecursive: Boolean);
    procedure ProcessArg(const Arg: string);
    property SuccessCount: Integer read FSuccessCount;
    property FailCount   : Integer read FFailCount;
  end;

constructor TDFMProcessor.Create(ARecursive: Boolean);
begin
  inherited Create;
  FRecursive    := ARecursive;
  FSuccessCount := 0;
  FFailCount    := 0;
end;

procedure TDFMProcessor.ProcessFile(const AFileName: string);
begin
  try
    Write('  ', AFileName, ' ... ');
    ConvertDFMFile(AFileName);
    Writeln('OK');
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

procedure PrintUsage;
begin
  Writeln('Usage: DFMStabilizerTool [-s] <file|pattern|@listfile> [...]');
  Writeln;
  Writeln('Converts DFM files in-place to the stabilized UTF-8 text format:');
  Writeln('  - strings are not broken at 64 characters (limit raised to 700)');
  Writeln('  - embedded newlines (#13/#10) cause a line break at that position');
  Writeln('  - non-ASCII characters are written literally as UTF-8');
  Writeln('  - file always starts with a UTF-8 BOM');
  Writeln;
  Writeln('Options:');
  Writeln('  -s          Recurse into subdirectories when expanding wildcard patterns');
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
end;

// ---------------------------------------------------------------------------

procedure Run;
var
  Recursive: Boolean;
  Processor: TDFMProcessor;
  I        : Integer;
  Arg      : string;
begin
  if ParamCount = 0 then
  begin
    PrintUsage;
    Halt(1);
  end;

  Recursive := False;
  for I := 1 to ParamCount do
    if SameText(ParamStr(I), '-s') then
    begin
      Recursive := True;
      Break;
    end;

  Processor := TDFMProcessor.Create(Recursive);
  try
    for I := 1 to ParamCount do
    begin
      Arg := ParamStr(I);
      if SameText(Arg, '-s') then
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
