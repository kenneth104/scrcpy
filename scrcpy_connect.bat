@echo off
chcp 65001 > nul

:: Prepend Google PlatformTools to PATH so it wins over QtScrcpy's old adb
set "PATH=%LOCALAPPDATA%\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools;%PATH%"

:: Run the connector script - it handles all errors with MessageBox internally
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scrcpy_connect.ps1"

:: If we get here, the script exited abnormally (it normally exits via the reconnect loop)
if %ERRORLEVEL% neq 0 (
    echo.
    echo  scrcpy_connect.ps1 exited with code %ERRORLEVEL%
    echo  Check scrcpy_connect.log for details.
    echo.
    pause
)
