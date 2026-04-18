@echo off
setlocal EnableDelayedExpansion

REM ============================================================
REM  node_helper V3  Global NODE_OPTIONS uninstaller
REM  Removes our --require flag from user-level NODE_OPTIONS.
REM  Keeps any other NODE_OPTIONS the user may have set.
REM ============================================================

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "INTERCEPT=%ROOT%\intercept.cjs"
set "FLAG=--require=%INTERCEPT%"

echo.
echo ========================================
echo   node_helper V3 - uninstall global
echo ========================================
echo.

set "CURRENT="
for /f "tokens=2,*" %%A in ('reg query "HKCU\Environment" /v NODE_OPTIONS 2^>nul ^| findstr /I "NODE_OPTIONS"') do (
    set "CURRENT=%%B"
)

echo Current NODE_OPTIONS (User):
if defined CURRENT (
    echo   !CURRENT!
) else (
    echo   ^(empty^)
    echo.
    echo [=] Nothing to uninstall.
    echo.
    pause
    exit /b 0
)
echo.

echo !CURRENT! | findstr /C:"%FLAG%" >nul
if not !errorlevel!==0 (
    echo [=] NODE_OPTIONS does not contain our --require. Nothing to remove.
    echo.
    pause
    exit /b 0
)

REM Use PowerShell to do an exact regex-escaped replace
REM ^(cmd native %VAR:x=y% cannot handle '=' in search string^)
set "CURRENT_NODE_OPTIONS=!CURRENT!"
set "REMOVE_FLAG=%FLAG%"
set "NEW="
for /f "delims=" %%X in ('powershell -NoProfile -Command "($env:CURRENT_NODE_OPTIONS -replace [regex]::Escape($env:REMOVE_FLAG), '') -replace '  +', ' ' -replace '^\s+|\s+$', ''"') do set "NEW=%%X"

if "!NEW!"=="" (
    reg delete "HKCU\Environment" /v NODE_OPTIONS /f >nul 2>&1
    echo [OK] NODE_OPTIONS completely removed.
) else (
    setx NODE_OPTIONS "!NEW!" >nul
    echo [OK] Removed the --require flag. NODE_OPTIONS now:
    echo      !NEW!
)

echo.
echo Note: setx only affects NEW processes. Current cmd still shows old value.
echo.
pause
