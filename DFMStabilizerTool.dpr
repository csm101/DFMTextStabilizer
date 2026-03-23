program DFMStabilizerTool;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  DFMTextStabilizerCore in 'DFMTextStabilizerCore.pas',
  DFMStabilizerCLI      in 'DFMStabilizerCLI.pas';

begin
  try
    DFMStabilizerCLI.Run;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, 'Fatal: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
