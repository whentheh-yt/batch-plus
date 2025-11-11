:: transpiler.bat
:: Prerelease 0.12
:: -------------------------------------------------------------------
:: 11/11/2025 - Started work. (This is gonna take me a while. (_ _") )

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

    echo !line!>>"%output%"
)

call "%output%"
endlocal
