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
rem  Usage:
rem      install-cloudcli-windows.cmd [--insecure | --cacert <path-to-ca.pem>]
rem
rem  Download and run directly:
rem      curl -fsSL <raw-url-of-this-script> -o "%TEMP%\install-cloudcli-windows.cmd" ^&^& "%TEMP%\install-cloudcli-windows.cmd"
rem
rem  Behind a TLS-inspecting corporate proxy whose root CA is not in the Windows
rem  trust store, add -k to that curl and pass --cacert (preferred) or --insecure
rem  to the script itself. The CLOUDCLI_CACERT and CLOUDCLI_INSECURE environment
rem  variables do the same thing and are honoured by all three installer scripts.
rem
rem  Running from an elevated (Administrator) window is recommended in case
rem  Node.js needs to be installed.
rem ============================================================================

setlocal EnableExtensions DisableDelayedExpansion

set "CLOUDCLI_PACKAGE=@cloudcli-ai/cloudcli"
set "NODE_INDEX_URL=https://nodejs.org/dist/index.tab"
set "NODE_DIST_URL=https://nodejs.org/dist"
set "NODE_DOWNLOAD_PAGE=https://nodejs.org/en/download"

rem ---------------------------------------------------------------------------
rem Options
rem ---------------------------------------------------------------------------
set "INSECURE="
set "CA_FILE="
if defined CLOUDCLI_INSECURE set "INSECURE=1"

:parse_args
if "%~1"=="" goto :args_done
if /i "%~1"=="--insecure" goto :arg_insecure
if /i "%~1"=="-k" goto :arg_insecure
if /i "%~1"=="--cacert" goto :arg_cacert
if /i "%~1"=="--help" goto :usage
if /i "%~1"=="/?" goto :usage
call :err "Unknown option: %~1"
goto :usage

:arg_insecure
set "INSECURE=1"
shift
goto :parse_args

:arg_cacert
set "CA_FILE=%~2"
shift
shift
goto :parse_args

:args_done
rem Env vars are the fallback for callers that cannot pass arguments; the .ps1 and .sh
rem versions honour the same two names.
if not defined CA_FILE if defined CLOUDCLI_CACERT set "CA_FILE=%CLOUDCLI_CACERT%"
if defined CA_FILE if not exist "%CA_FILE%" (
    call :err "CA file not found: %CA_FILE%"
    goto :fail
)
if defined CA_FILE if defined INSECURE (
    call :warn "Both --cacert and --insecure were given. Using --cacert and keeping verification on."
    set "INSECURE="
)

rem curl verifies against the Windows store by default; --cacert points it at an extra
rem root instead, and --insecure turns verification off entirely.
set "CURL_TLS_OPT="
if defined CA_FILE set CURL_TLS_OPT=--cacert "%CA_FILE%"
if defined INSECURE set CURL_TLS_OPT=--insecure

rem Node ships its own CA bundle and ignores the Windows store, so npm needs telling
rem separately. Both of these are scoped to this script by setlocal.
set "NPM_TLS_OPT="
if defined CA_FILE set "NODE_EXTRA_CA_CERTS=%CA_FILE%"
if defined INSECURE set "NPM_TLS_OPT=--strict-ssl=false"
if defined INSECURE set "NODE_TLS_REJECT_UNAUTHORIZED=0"

if defined INSECURE (
    call :warn "--insecure: TLS certificate verification is DISABLED for every download below."
    call :warn "Anything on the network path can substitute what gets downloaded and then run."
    call :warn "Prefer --cacert with your proxy's root CA. Continuing in 5 seconds..."
    timeout /t 5 >nul 2>&1
)
if defined CA_FILE call :info "Verifying TLS against extra CA: %CA_FILE%"

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

rem winget validates TLS against the Windows store and offers no way to override that,
rem so when the store is the problem it cannot succeed. Go straight to the MSI, which
rem we fetch with curl and can point at a CA (or not verify at all).
if defined CA_FILE goto :skip_winget
if defined INSECURE goto :skip_winget
goto :try_winget

:skip_winget
call :info "Skipping winget: it can only verify TLS against the Windows store."
goto :install_node_msi

:try_winget
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
curl %CURL_TLS_OPT% -fsSL "%NODE_INDEX_URL%" -o "%NODE_INDEX_FILE%"
rem Capture this before anything else runs: `call :err` resets ERRORLEVEL via its echo.
set "CURL_EXIT=%ERRORLEVEL%"
if not "%CURL_EXIT%"=="0" (
    call :err "Could not download the Node.js release index from %NODE_INDEX_URL%."
    if "%CURL_EXIT%"=="60" call :tls_hint
    if "%CURL_EXIT%"=="77" call :tls_hint
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
curl %CURL_TLS_OPT% -fsSL "%NODE_MSI_URL%" -o "%NODE_MSI_PATH%"
set "CURL_EXIT=%ERRORLEVEL%"
if not "%CURL_EXIT%"=="0" (
    call :err "Failed to download %NODE_MSI_URL%."
    if "%CURL_EXIT%"=="60" call :tls_hint
    if "%CURL_EXIT%"=="77" call :tls_hint
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
call npm install -g %CLOUDCLI_PACKAGE% %NPM_TLS_OPT%
if errorlevel 1 (
    call :err "npm install -g %CLOUDCLI_PACKAGE% failed."
    call :tls_hint
    goto :fail
)

call :info "Done! %CLOUDCLI_PACKAGE% is installed."
if defined INSECURE call :warn "Reminder: this run skipped TLS verification. Nothing was verified as authentic."
if defined CA_FILE call :info "Tip: set NODE_EXTRA_CA_CERTS to that CA permanently so npm keeps working."
goto :done

rem ---------------------------------------------------------------------------
:manual_node
call :err "Automatic Node.js installation failed."
if not defined IS_ADMIN call :err "Try again from an elevated (Administrator) window."
call :err "Or install Node.js manually from %NODE_DOWNLOAD_PAGE% and re-run this script."
goto :fail

rem ---------------------------------------------------------------------------
:tls_hint
rem Called for curl exit 60 (peer certificate cannot be authenticated) and 77 (CA bundle
rem unusable), and after an npm failure: all point at the trust chain, not the network.
call :warn "That may be a TLS trust failure rather than a network failure."
call :warn "If a proxy inspects TLS here, re-run with: --cacert C:\path\to\proxy-root-ca.pem"
call :warn "npm ignores the Windows store, so it needs NODE_EXTRA_CA_CERTS set to that same file."
call :warn "Or, accepting that nothing gets verified, re-run with: --insecure"
goto :eof

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

:usage
echo.
echo Usage: install-cloudcli-windows.cmd [--insecure ^| --cacert ^<path-to-ca.pem^>]
echo.
echo   --cacert ^<path^>   Verify TLS against an extra root CA in PEM form, such as a
echo                     corporate TLS-inspection root. Also exported to npm through
echo                     NODE_EXTRA_CA_CERTS. This is the preferred option.
echo   --insecure, -k    Skip TLS verification entirely for every download. Only for
echo                     a network you trust; nothing downloaded can be authenticated.
echo.
goto :fail

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
