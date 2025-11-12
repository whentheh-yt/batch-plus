:: transpiler.bat
:: Prerelease 0.13
:: -------------------------------------------------------------------
:: 11/11/2025 - Started work. (This is gonna take me a while. (_ _") )
:: 11/12/2025 - Added builtin system info variables ($VER, $RAM.*, $CPU, etc)

@echo off
setlocal enabledelayedexpansion

if "%~1"=="" (
    echo Intended usage: transpiler.bat examplescript.batp
    echo (Make sure you run this with the transpiler and script in the same directory!)
    echo (Tip: right click in the transpiler's directory and click "Open in Terminal" and execute the command there!)
    exit /b
)

set "input=%~1"
set "output=%TEMP%\compiled.bat"

if exist "%output%" del "%output%"

for /f "tokens=2 delims==" %%A in ('wmic os get version /value') do set "OS_VER=%%A"
for /f "tokens=2 delims==" %%A in ('wmic os get caption /value') do set "OS_NAME=%%A"
for /f "tokens=2 delims==" %%A in ('wmic computersystem get totalphysicalmemory /value') do set "TOTAL_RAM=%%A"
for /f "tokens=2 delims==" %%A in ('wmic os get freephysicalmemory /value') do set "FREE_RAM=%%A"
for /f "tokens=2 delims==" %%A in ('wmic cpu get name /value') do set "CPU_NAME=%%A"
for /f "tokens=2 delims==" %%A in ('wmic cpu get processorcount /value') do set "CPU_COUNT=%%A"

:: Convert free RAM from KB to MB, hasta la vista baby!
set /a FREE_RAM_MB=%FREE_RAM:~0,-1% / 1024
set /a TOTAL_RAM_MB=%TOTAL_RAM:~0,-1% / 1024
set /a USED_RAM_MB=%TOTAL_RAM_MB% - %FREE_RAM_MB%

for /f "usebackq delims=" %%L in ("%input%") do (
    set "line=%%L"

    set "line=!line:let =set !"

    set "line=!line: + = ^& !"

    set "line=!line:echo \"=echo !"
    set "line=!line:\"=!"

    set "line=!line:$USER=%USERNAME%!"
    set "line=!line:$HOST=%COMPUTERNAME%!"
    set "line=!line:$DATE=%DATE%!"
    set "line=!line:$TIME=%TIME%!"

    set "line=!line:$VER=%OS_VER%!"
    set "line=!line:$OS=%OS_NAME%!"
    set "line=!line:$RAM.TOTAL=%TOTAL_RAM_MB%!"
    set "line=!line:$RAM.FREE=%FREE_RAM_MB%!"
    set "line=!line:$RAM.USED=%USED_RAM_MB%!"
    set "line=!line:$CPU=%CPU_NAME%!"
    set "line=!line:$CPU.COUNT=%CPU_COUNT%!"

    echo !line!>>"%output%"
)

call "%output%"
endlocal
