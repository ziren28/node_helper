@echo off
setlocal EnableDelayedExpansion

REM ============================================================
REM  node_helper V3  Global NODE_OPTIONS installer
REM  Sets user-level NODE_OPTIONS so every Node process loads
REM  intercept.cjs, which self-filters by env signals.
REM  No admin required. Double-click safe.
REM ============================================================

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "INTERCEPT=%ROOT%\intercept.cjs"
set "FLAG=--require=%INTERCEPT%"

echo.
echo ========================================
echo   node_helper V3 - install global
echo ========================================
echo.
echo intercept.cjs: %INTERCEPT%
echo.

if not exist "%INTERCEPT%" (
    echo [X] intercept.cjs not found. Abort.
    echo.
    pause
    exit /b 1
)

REM Read current user-level NODE_OPTIONS from registry
set "CURRENT="
for /f "tokens=2,*" %%A in ('reg query "HKCU\Environment" /v NODE_OPTIONS 2^>nul ^| findstr /I "NODE_OPTIONS"') do (
    set "CURRENT=%%B"
)

echo Current NODE_OPTIONS (User):
if defined CURRENT (
    echo   !CURRENT!
) else (
    echo   ^(empty^)
)
echo.

REM Already installed?
if defined CURRENT (
    echo !CURRENT! | findstr /C:"%FLAG%" >nul
    if !errorlevel!==0 (
        echo [=] Already installed. NODE_OPTIONS already contains the --require.
        echo     Run uninstall-global.cmd first if you want to reinstall.
        echo.
        pause
        exit /b 0
    )
)

REM Build new value: prepend our flag, keep user's other options
if defined CURRENT (
    set "NEW=%FLAG% !CURRENT!"
) else (
    set "NEW=%FLAG%"
)

setx NODE_OPTIONS "!NEW!" >nul
if errorlevel 1 (
    echo [X] setx failed.
    echo.
    pause
    exit /b 1
)

echo [OK] Wrote user-level NODE_OPTIONS:
echo      !NEW!
echo.
echo Notes:
echo   1. setx only affects NEW processes. Current cmd does not see the new value.
echo   2. Every Node process will load intercept.cjs; it self-checks env signals
echo      (CLAUDECODE / CLAUDE_CODE_ENTRYPOINT / ...). Non-Claude Node returns
echo      immediately without installing hooks. Zero side effect.
echo   3. Debug: set CLAUDE_INTERCEPT_DEBUG=1 to see which Node processes are skipped.
echo   4. Temporary off: set CLAUDE_INTERCEPT_NEVER=1 before running claude.
echo.
echo Verify (in a NEW terminal):
echo   echo %%NODE_OPTIONS%%
echo   claude --version
echo   ^(stderr should show: [ic v3] active (env:CLAUDECODE) ...^)
echo.
echo Uninstall:
echo   uninstall-global.cmd
echo.
pause
