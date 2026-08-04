@echo off
rem ============================================================================
rem  install-cloudcli-windows.cmd
rem
rem  Installs Node.js (if it isn't already installed) and @cloudcli-ai/cloudcli.
rem
rem  This is the Command Prompt (cmd.exe) counterpart of install-cloudcli-windows.ps1,
rem  for people running cmd in Windows Terminal rather than PowerShell. It downloads
rem  with curl.exe instead of Invoke-WebRequest, so it is unaffected by Windows
rem  PowerShell 5.1's default TLS protocol setting.
rem
rem  Usage (download and run directly):
rem      curl -fsSL <raw-url-of-this-script> -o "%TEMP%\install-cloudcli-windows.cmd" ^&^& "%TEMP%\install-cloudcli-windows.cmd"
rem
rem  or download it first and run locally:
rem      install-cloudcli-windows.cmd
rem
rem  Running from an elevated (Administrator) window is recommended in case
rem  Node.js needs to be installed.
rem ============================================================================

setlocal EnableExtensions DisableDelayedExpansion

set "CLOUDCLI_PACKAGE=@cloudcli-ai/cloudcli"
set "NODE_INDEX_URL=https://nodejs.org/dist/index.tab"
set "NODE_DIST_URL=https://nodejs.org/dist"
set "NODE_DOWNLOAD_PAGE=https://nodejs.org/en/download"

rem `net session` only succeeds when the console is elevated.
set "IS_ADMIN="
net session >nul 2>&1
if not errorlevel 1 set "IS_ADMIN=1"
if not defined IS_ADMIN echo [cloudcli-installer] Note: run this script from an elevated ^(Administrator^) window if Node.js needs to be installed.

where /q node
if errorlevel 1 goto :install_node
where /q npm
if errorlevel 1 goto :install_node

for /f "delims=" %%V in ('node -v 2^>nul') do set "NODE_VERSION=%%V"
call :info "Node.js is already installed (%NODE_VERSION%). Skipping Node.js installation."
goto :install_cloudcli

rem ---------------------------------------------------------------------------
:install_node
call :info "Node.js was not found on this machine."

where /q winget
if errorlevel 1 goto :install_node_msi

call :info "Installing Node.js via winget..."
winget install --id OpenJS.NodeJS.LTS -e --silent --accept-source-agreements --accept-package-agreements
if errorlevel 1 (
    call :warn "winget could not install Node.js. Falling back to the official installer from nodejs.org..."
    goto :install_node_msi
)
goto :node_installed

rem ---------------------------------------------------------------------------
:install_node_msi
where /q curl
if errorlevel 1 (
    call :err "curl.exe was not found, so the Node.js installer cannot be downloaded."
    goto :manual_node
)

set "NODE_ARCH=x64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "NODE_ARCH=arm64"
if /i "%PROCESSOR_ARCHITEW6432%"=="ARM64" set "NODE_ARCH=arm64"

call :info "Looking up the latest Node.js LTS release..."
set "NODE_INDEX_FILE=%TEMP%\node-dist-index.tab"
curl -fsSL "%NODE_INDEX_URL%" -o "%NODE_INDEX_FILE%"
if errorlevel 1 (
    call :err "Could not download the Node.js release index from %NODE_INDEX_URL%."
    goto :manual_node
)

rem index.tab is newest-first and tab separated: column 1 is the version and column 10
rem is the LTS codename, which is "-" for non-LTS releases. So the first row whose
rem column 10 is not "-" is the current LTS. (https://nodejs.org/dist/latest-lts/,
rem which older versions of this installer used, now returns 404.)
set "NODE_LTS_VERSION="
for /f "usebackq skip=1 tokens=1,10" %%A in ("%NODE_INDEX_FILE%") do (
    if not defined NODE_LTS_VERSION if not "%%B"=="-" set "NODE_LTS_VERSION=%%A"
)
del /f /q "%NODE_INDEX_FILE%" >nul 2>&1

if not defined NODE_LTS_VERSION (
    call :err "Could not determine the latest Node.js LTS version."
    goto :manual_node
)

set "NODE_MSI=node-%NODE_LTS_VERSION%-%NODE_ARCH%.msi"
set "NODE_MSI_URL=%NODE_DIST_URL%/%NODE_LTS_VERSION%/%NODE_MSI%"
set "NODE_MSI_PATH=%TEMP%\%NODE_MSI%"

call :info "Downloading %NODE_MSI%..."
curl -fsSL "%NODE_MSI_URL%" -o "%NODE_MSI_PATH%"
if errorlevel 1 (
    call :err "Failed to download %NODE_MSI_URL%."
    del /f /q "%NODE_MSI_PATH%" >nul 2>&1
    goto :manual_node
)

rem A fully silent (/qn) install cannot raise a UAC prompt, so it only works when this
rem console is already elevated. Unelevated, /passive shows a progress window and lets
rem Windows prompt for elevation.
if defined IS_ADMIN (
    call :info "Installing Node.js silently..."
    start "" /wait msiexec.exe /i "%NODE_MSI_PATH%" /qn /norestart
) else (
    call :info "Installing Node.js (a UAC prompt may appear)..."
    start "" /wait msiexec.exe /i "%NODE_MSI_PATH%" /passive /norestart
)
set "MSI_EXIT=%ERRORLEVEL%"
del /f /q "%NODE_MSI_PATH%" >nul 2>&1
if not "%MSI_EXIT%"=="0" (
    call :err "msiexec exited with code %MSI_EXIT%, so Node.js was not installed."
    goto :manual_node
)

rem ---------------------------------------------------------------------------
:node_installed
call :refresh_path

where /q node
if errorlevel 1 (
    call :err "Node.js installation finished, but 'node' is still not on PATH."
    call :err "Please close and reopen your terminal, then re-run this script."
    goto :fail
)
for /f "delims=" %%V in ('node -v 2^>nul') do set "NODE_VERSION=%%V"
call :info "Node.js installed successfully (%NODE_VERSION%)."

rem ---------------------------------------------------------------------------
:install_cloudcli
call :info "Installing %CLOUDCLI_PACKAGE% globally via npm..."
rem npm is a .cmd shim, so it needs `call` or it would never return to this script.
call npm install -g %CLOUDCLI_PACKAGE%
if errorlevel 1 (
    call :err "npm install -g %CLOUDCLI_PACKAGE% failed."
    goto :fail
)

call :info "Done! %CLOUDCLI_PACKAGE% is installed."
goto :done

rem ---------------------------------------------------------------------------
:manual_node
call :err "Automatic Node.js installation failed."
if not defined IS_ADMIN call :err "Try again from an elevated (Administrator) window."
call :err "Or install Node.js manually from %NODE_DOWNLOAD_PAGE% and re-run this script."
goto :fail

rem ---------------------------------------------------------------------------
:refresh_path
rem Installers write the new PATH to the registry, but this console session won't see
rem the change until we merge it into %PATH% ourselves. `find "REG_"` isolates the value
rem line of `reg query`, whose 3rd token onwards is the value itself.
set "MACHINE_PATH="
set "USER_PATH="
for /f "tokens=2,*" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v Path 2^>nul ^| find "REG_"') do set "MACHINE_PATH=%%B"
for /f "tokens=2,*" %%A in ('reg query "HKCU\Environment" /v Path 2^>nul ^| find "REG_"') do set "USER_PATH=%%B"
rem Those are REG_EXPAND_SZ values, so they can contain %SystemRoot%-style references.
call set "MACHINE_PATH=%%MACHINE_PATH%%"
call set "USER_PATH=%%USER_PATH%%"
if defined MACHINE_PATH set "PATH=%MACHINE_PATH%"
if defined USER_PATH set "PATH=%PATH%;%USER_PATH%"
rem Belt and braces: this is where the Node.js MSI lands even if the registry read failed.
if exist "%ProgramFiles%\nodejs\node.exe" set "PATH=%PATH%;%ProgramFiles%\nodejs"
goto :eof

:info
echo.
echo [cloudcli-installer] %~1
goto :eof

:warn
echo.
echo [cloudcli-installer] WARNING: %~1
goto :eof

:err
echo.
echo [cloudcli-installer] ERROR: %~1
goto :eof

:maybe_pause
rem Keep the window open when the script was launched by double-clicking it in Explorer.
echo "%cmdcmdline%" | find /i "%~nx0" >nul 2>&1
if not errorlevel 1 pause
goto :eof

:done
call :maybe_pause
endlocal
exit /b 0

:fail
call :maybe_pause
endlocal
exit /b 1
