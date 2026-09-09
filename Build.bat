@echo off
setlocal EnableExtensions
rem ===========================================================================
rem  Build.bat - builds DFMTextStabilizer from the command line, without the
rem  Delphi IDE. It only needs the Delphi command-line compilers (dcc32/dcc64),
rem  which are shipped by Delphi and RAD Studio and also by C++Builder.
rem
rem  Usage:  Build.bat [DDetoursSourceDir] [RADStudioDir]
rem
rem    DDetoursSourceDir  folder containing DDetours.pas from
rem                       https://github.com/MahdiSafsafi/DDetours
rem                       Default: the DDETOURS_SRC environment variable, then
rem                       .\DDetours\Source, then ..\DDetours\Source
rem    RADStudioDir       e.g. "C:\Program Files (x86)\Embarcadero\Studio\23.0"
rem                       Default: the BDS environment variable when rsvars.bat
rem                       was already run, otherwise the newest installation
rem                       found under %ProgramFiles(x86)%\Embarcadero\Studio
rem
rem  Output, under .\Bin\Studio<version>\ :
rem    Win32\DFMTextStabilizerStandalone.bpl  design-time package, 32-bit IDE
rem    Win64\DFMTextStabilizerStandalone.bpl  design-time package, 64-bit IDE
rem                                           (only when both the 64-bit IDE
rem                                           and dcc64 are installed)
rem    Win64\DFMStabilizerTool.exe            command-line DFM converter
rem                                           (in Win32\ when dcc64 is missing)
rem ===========================================================================

set "REPO=%~dp0"
set "REPO=%REPO:~0,-1%"

rem --- 1. locate the RAD Studio / Delphi / C++Builder installation ----------
set "STUDIO="
if not "%~2"=="" set "STUDIO=%~2"
if not defined STUDIO if defined BDS if exist "%BDS%\bin\rsvars.bat" set "STUDIO=%BDS%"
if not defined STUDIO call :FindNewestStudio
if not defined STUDIO (
  echo ERROR: no RAD Studio / Delphi / C++Builder installation found.
  echo        Run this script from a "RAD Studio Command Prompt" or pass the
  echo        installation folder as second argument, for example:
  echo          Build.bat ..\DDetours\Source "C:\Program Files (x86)\Embarcadero\Studio\23.0"
  goto :Fail
)
if not exist "%STUDIO%\bin\dcc32.exe" (
  echo ERROR: "%STUDIO%\bin\dcc32.exe" not found.
  echo        The Delphi command-line compiler is required. Community and Trial
  echo        editions do not include it.
  goto :Fail
)
call "%STUDIO%\bin\rsvars.bat"
for %%i in ("%STUDIO%") do set "STUDIOVER=%%~nxi"

rem --- 2. locate the DDetours sources ---------------------------------------
set "DDSRC="
if not "%~1"=="" set "DDSRC=%~1"
if not defined DDSRC if defined DDETOURS_SRC set "DDSRC=%DDETOURS_SRC%"
if not defined DDSRC if exist "%REPO%\DDetours\Source\DDetours.pas" set "DDSRC=%REPO%\DDetours\Source"
if not defined DDSRC if exist "%REPO%\..\DDetours\Source\DDetours.pas" set "DDSRC=%REPO%\..\DDetours\Source"
if not defined DDSRC (
  echo ERROR: DDetours sources not found.
  echo        Clone https://github.com/MahdiSafsafi/DDetours and pass the path of
  echo        its Source folder as first argument, for example:
  echo          git clone https://github.com/MahdiSafsafi/DDetours ..\DDetours
  echo          Build.bat ..\DDetours\Source
  goto :Fail
)
for %%i in ("%DDSRC%") do set "DDSRC=%%~fi"
if not exist "%DDSRC%\DDetours.pas" (
  echo ERROR: "%DDSRC%\DDetours.pas" not found.
  goto :Fail
)

rem --- 3. decide what can be built -------------------------------------------
set "OUT=%REPO%\Bin\Studio%STUDIOVER%"
set "HAVE_DCC64="
if exist "%STUDIO%\bin\dcc64.exe" set "HAVE_DCC64=1"
set "BUILD64="
if defined HAVE_DCC64 if exist "%STUDIO%\bin64\bds.exe" set "BUILD64=1"

echo.
echo RAD Studio folder : %STUDIO%
echo DDetours sources  : %DDSRC%
echo Output folder     : %OUT%
echo.

rem --- 4. build ---------------------------------------------------------------
call :BuildPackage dcc32.exe Win32
if errorlevel 1 goto :Fail

if defined BUILD64 (
  call :BuildPackage dcc64.exe Win64
  if errorlevel 1 goto :Fail
) else (
  if defined HAVE_DCC64 (
    echo Skipping the Win64 package: this installation has no 64-bit IDE.
  ) else (
    echo Skipping the Win64 package: dcc64.exe is not installed.
  )
)

if defined HAVE_DCC64 (
  call :BuildTool dcc64.exe Win64
) else (
  call :BuildTool dcc32.exe Win32
)
if errorlevel 1 goto :Fail

rem --- 5. done ----------------------------------------------------------------
echo.
echo ===========================================================================
echo Build completed successfully.
echo.
echo You can now install the compiled BPL directly from the IDE, through the
echo menu Component -^> Install Packages... -^> Add...
echo   32-bit IDE:  %OUT%\Win32\DFMTextStabilizerStandalone.bpl
if defined BUILD64 echo   64-bit IDE:  %OUT%\Win64\DFMTextStabilizerStandalone.bpl
echo The IDE loads the package from that location at every start, so keep the
echo Bin folder where it is.
echo.
echo Command-line converter for existing DFM files: %TOOLEXE%
echo ===========================================================================
call :PauseIfDoubleClicked
exit /b 0

rem ===========================================================================
:BuildPackage
rem %1 = compiler executable, %2 = platform (Win32 / Win64)
set "PLATOUT=%OUT%\%~2"
set "PLATOBJ=%OUT%\Obj\%~2"
if not exist "%PLATOUT%" mkdir "%PLATOUT%"
if not exist "%PLATOBJ%" mkdir "%PLATOBJ%"
echo Building the %~2 design-time package with %~1 ...
"%STUDIO%\bin\%~1" -B -Q -$D- -$L- -$Y- -DRELEASE ^
  -NS"System;Winapi;System.Win" ^
  -U"%STUDIO%\lib\%~2\release" -U"%DDSRC%" -I"%DDSRC%" ^
  -NU"%PLATOBJ%" -LE"%PLATOUT%" -LN"%PLATOUT%" ^
  "%REPO%\DFMTextStabilizerStandalone.dpk"
if errorlevel 1 (
  echo ERROR: build of the %~2 package failed.
  exit /b 1
)
exit /b 0

:BuildTool
rem %1 = compiler executable, %2 = platform (Win32 / Win64)
set "PLATOUT=%OUT%\%~2"
set "PLATOBJ=%OUT%\Obj\%~2"
if not exist "%PLATOUT%" mkdir "%PLATOUT%"
if not exist "%PLATOBJ%" mkdir "%PLATOBJ%"
if not exist "%REPO%\DFMStabilizerTool.res" (
  call :MakeEmptyRes "%PLATOBJ%\DFMStabilizerTool.res"
  if errorlevel 1 exit /b 1
)
echo Building the %~2 command-line tool with %~1 ...
"%STUDIO%\bin\%~1" -B -Q -$D- -$L- -$Y- -DRELEASE ^
  -NS"System;Winapi;System.Win" ^
  -U"%STUDIO%\lib\%~2\release" ^
  -NU"%PLATOBJ%" -R"%PLATOBJ%" -E"%PLATOUT%" ^
  "%REPO%\DFMStabilizerTool.dpr"
if errorlevel 1 (
  echo ERROR: build of the command-line tool failed.
  exit /b 1
)
set "TOOLEXE=%PLATOUT%\DFMStabilizerTool.exe"
exit /b 0

:MakeEmptyRes
rem The IDE normally generates DFMStabilizerTool.res; it is not versioned,
rem so an empty resource file is produced here for {$R *.res} to link.
type nul > "%~dpn1.rc"
if exist "%STUDIO%\bin\rc.exe" (
  "%STUDIO%\bin\rc.exe" /fo "%~1" "%~dpn1.rc" >nul
) else if exist "%STUDIO%\bin\brcc32.exe" (
  "%STUDIO%\bin\brcc32.exe" -fo"%~1" "%~dpn1.rc" >nul
) else (
  echo ERROR: neither rc.exe nor brcc32.exe found in "%STUDIO%\bin".
  exit /b 1
)
if not exist "%~1" (
  echo ERROR: could not create "%~1".
  exit /b 1
)
exit /b 0

:FindNewestStudio
for /d %%d in ("%ProgramFiles(x86)%\Embarcadero\Studio\*") do if exist "%%~d\bin\dcc32.exe" set "STUDIO=%%~d"
exit /b 0

:PauseIfDoubleClicked
echo %CMDCMDLINE% | findstr /i /c:"/c" >nul 2>&1 && pause
exit /b 0

:Fail
call :PauseIfDoubleClicked
exit /b 1
