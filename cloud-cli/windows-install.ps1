<#
.SYNOPSIS
    Installs Node.js (if it isn't already installed) and @cloudcli-ai/cloudcli

.DESCRIPTION
    Usage (download and run directly):
        irm <raw-url-of-this-script> | iex

    Behind a TLS-inspecting proxy whose root CA is not in the Windows trust store,
    set one of these first. The script deliberately has no param() block, because
    `irm ... | iex` has no way to pass parameters to it:

        $env:CLOUDCLI_CACERT = 'C:\path\to\proxy-root-ca.pem'   # preferred
        $env:CLOUDCLI_INSECURE = '1'                            # skips verification entirely

    or download it first and run locally, where arguments do work:
        powershell -ExecutionPolicy Bypass -File windows-install.ps1 --insecure
        powershell -ExecutionPolicy Bypass -File windows-install.ps1 --cacert C:\ca.pem

    Running from an elevated (Administrator) PowerShell window is recommended in case
    Node.js needs to be installed.
#>

$ErrorActionPreference = 'Stop'

$CloudCliPackage  = '@cloudcli-ai/cloudcli'
$NodeDistUrl      = 'https://nodejs.org/dist'
$NodeIndexUrl     = 'https://nodejs.org/dist/index.tab'
$NodeDownloadPage = 'https://nodejs.org/en/download'

function Write-Info([string]$Message) {
    Write-Host ""
    Write-Host "[cloudcli-installer] $Message" -ForegroundColor Cyan
}

function Write-WarnMsg([string]$Message) {
    Write-Host ""
    Write-Host "[cloudcli-installer] WARNING: $Message" -ForegroundColor Yellow
}

function Write-ErrorMsg([string]$Message) {
    Write-Host ""
    Write-Host "[cloudcli-installer] ERROR: $Message" -ForegroundColor Red
}

function Write-TlsHint {
    Write-WarnMsg "That may be a TLS trust failure rather than a network failure."
    Write-WarnMsg "If a proxy inspects TLS here, set `$env:CLOUDCLI_CACERT to its root CA (PEM) and re-run."
    Write-WarnMsg "npm keeps its own CA list, so it needs NODE_EXTRA_CA_CERTS set to that same file."
    Write-WarnMsg "Or, accepting that nothing gets verified, set `$env:CLOUDCLI_INSECURE = '1'."
}

# ---------------------------------------------------------------------------
# Options: environment variables first, then arguments when run as a file.
# Any non-empty CLOUDCLI_INSECURE enables it, matching the .cmd version.
# ---------------------------------------------------------------------------
$Insecure = -not [string]::IsNullOrWhiteSpace($env:CLOUDCLI_INSECURE)
$CaCert   = $env:CLOUDCLI_CACERT

# Unknown arguments are ignored rather than fatal: under `iex` this runs in the caller's
# scope, where $args may hold something entirely unrelated to this script.
for ($i = 0; $i -lt $args.Count; $i++) {
    switch -Regex ([string]$args[$i]) {
        '^(--insecure|-insecure|-k)$' { $Insecure = $true }
        '^(--cacert|-cacert)$'        { if ($i + 1 -lt $args.Count) { $CaCert = [string]$args[++$i] } }
    }
}

if ($CaCert -and $Insecure) {
    Write-WarnMsg "Both a CA file and insecure mode were given. Using the CA file and keeping verification on."
    $Insecure = $false
}
if ($CaCert -and -not (Test-Path -LiteralPath $CaCert)) {
    Write-ErrorMsg "CA file not found: $CaCert"
    return
}

# ---------------------------------------------------------------------------
# Downloads
# ---------------------------------------------------------------------------

# NOTE: in Windows PowerShell 5.1 `curl` is an alias for Invoke-WebRequest, so the
# .exe suffix is required to reach the real binary.
$CurlExe = Get-Command curl.exe -ErrorAction SilentlyContinue

function Get-RemoteFile([string]$Url, [string]$OutFile) {
    if ($CurlExe) {
        # curl handles both TLS options natively and is present on Windows 10 1803+.
        $curlArgs = @()
        if ($CaCert)   { $curlArgs += @('--cacert', $CaCert) }
        if ($Insecure) { $curlArgs += '--insecure' }
        $curlArgs += @('-fsSL', $Url, '-o', $OutFile)

        & $CurlExe.Source @curlArgs
        if ($LASTEXITCODE -ne 0) {
            throw "curl.exe exited with code $LASTEXITCODE while downloading $Url"
        }
        return
    }

    if ($CaCert) {
        throw ("curl.exe is unavailable, so a CA file cannot be applied to the download. " +
               "Install the CA into the Windows store instead: certutil -addstore -f Root `"$CaCert`"")
    }

    $iwr = @{ Uri = $Url; OutFile = $OutFile; UseBasicParsing = $true }
    if ($Insecure) {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $iwr['SkipCertificateCheck'] = $true
        } else {
            # PowerShell 5.1 has no -SkipCertificateCheck; this is the 5.1-only equivalent.
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        }
    }
    Invoke-WebRequest @iwr
}

# index.tab is newest-first and tab separated: column 1 is the version and column 10 is
# the LTS codename, which is "-" for non-LTS releases. So the first row whose column 10
# is not "-" is the current LTS. (https://nodejs.org/dist/latest-lts/, which this script
# used to scrape for the installer filename, now returns 404 and made this path fail.)
function Get-LatestLtsVersion {
    $indexFile = Join-Path $env:TEMP 'node-dist-index.tab'
    try {
        Get-RemoteFile -Url $NodeIndexUrl -OutFile $indexFile
        foreach ($line in (Get-Content -LiteralPath $indexFile | Select-Object -Skip 1)) {
            $cols = $line -split "`t"
            if ($cols.Count -ge 10 -and $cols[9] -ne '-') { return $cols[0] }
        }
        return $null
    } finally {
        Remove-Item -Force -LiteralPath $indexFile -ErrorAction SilentlyContinue
    }
}

function Install-NodeViaWinget {
    Write-Info "Installing Node.js via winget..."
    winget install --id OpenJS.NodeJS.LTS -e --silent --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget exited with code $LASTEXITCODE"
    }
}

function Install-NodeViaMsi([bool]$IsAdmin) {
    Write-Info "Downloading the official Node.js installer from nodejs.org..."
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }

    $version = Get-LatestLtsVersion
    if (-not $version) {
        throw "Could not determine the latest Node.js LTS version from $NodeIndexUrl"
    }

    $msiName = "node-$version-$arch.msi"
    $msiUrl  = "$NodeDistUrl/$version/$msiName"
    $tmpMsi  = Join-Path $env:TEMP $msiName

    Write-Info "Downloading $msiName..."
    Get-RemoteFile -Url $msiUrl -OutFile $tmpMsi

    try {
        # A fully silent (/qn) install cannot raise a UAC prompt, so it only works when
        # this session is already elevated. Unelevated, /passive shows a progress window
        # and lets Windows prompt for elevation.
        if ($IsAdmin) {
            Write-Info "Installing Node.js silently..."
            $msiArgs = "/i `"$tmpMsi`" /qn /norestart"
        } else {
            Write-Info "Installing Node.js (a UAC prompt may appear)..."
            $msiArgs = "/i `"$tmpMsi`" /passive /norestart"
        }
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            throw "msiexec exited with code $($proc.ExitCode), so Node.js was not installed"
        }
    } finally {
        Remove-Item -Force -LiteralPath $tmpMsi -ErrorAction SilentlyContinue
    }
}

function Update-SessionPath {
    # Installers update the Machine/User PATH in the registry, but this PowerShell session
    # won't see the change until we merge it into $env:Path ourselves.
    #
    # Append rather than assign over $env:Path. Overwriting means a single empty or failed
    # read strips System32 from the session and every later native call stops resolving --
    # exactly how the .cmd version broke, where `where` came back "not recognized". Keeping
    # the current PATH as the floor makes that impossible, and the nodejs directory is added
    # directly so it lands even when neither registry value carries it yet.
    $nodeDir     = Join-Path $env:ProgramFiles 'nodejs'
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [System.Environment]::GetEnvironmentVariable('Path', 'User')

    if (Test-Path -LiteralPath $nodeDir) { $env:Path = "$env:Path;$nodeDir" }
    if ($machinePath) { $env:Path = "$env:Path;$machinePath" }
    if ($userPath)    { $env:Path = "$env:Path;$userPath" }
}

# Runs npm without letting PowerShell pick one of Node's shims for us.
#
# Node's Windows installer drops three shims next to node.exe: npm, npm.cmd and npm.ps1.
# A bare `npm` resolves to npm.ps1 under PowerShell, which the default (Restricted)
# execution policy refuses to load. npm.cmd is not policy-gated, but it is a batch shim
# that first spawns a nested `for /f` node process to resolve the global prefix; that
# extra console child inherits this console's stdin and can sit there waiting for a
# keypress instead of returning. Invoking npm's own CLI script with node.exe skips both
# shims and runs exactly one process.
#
# Stdin is closed for the call (`$null |` hands the child an already-ended pipe) because
# nothing in a global install should ever prompt, so a read from the console can only be
# a hang. Sets $LASTEXITCODE like any native call; the caller checks it.
function Invoke-Npm([string[]]$NpmArgs) {
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCmd -and $nodeCmd.Source) {
        $npmCliJs = Join-Path (Split-Path -Parent $nodeCmd.Source) 'node_modules\npm\bin\npm-cli.js'
        if (Test-Path -LiteralPath $npmCliJs) {
            $null | & $nodeCmd.Source $npmCliJs @NpmArgs
            return
        }
    }

    # No bundled npm-cli.js (unusual layout): fall back to the batch shim, never npm.ps1.
    $null | & npm.cmd @NpmArgs
}

function Install-CloudCli {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "[cloudcli-installer] Note: run this script from an elevated (Administrator) PowerShell window if Node.js needs to be installed." -ForegroundColor Yellow
    }

    if ($Insecure) {
        Write-WarnMsg "Insecure mode: TLS certificate verification is DISABLED for every download below."
    }
    if ($CaCert) {
        Write-Info "Verifying TLS against extra CA: $CaCert"
    }

    if ((Get-Command node -ErrorAction SilentlyContinue) -and (Get-Command npm -ErrorAction SilentlyContinue)) {
        Write-Info "Node.js is already installed ($(node -v)). Skipping Node.js installation."
    } else {
        Write-Info "Node.js was not found on this machine."

        # winget validates TLS against the Windows store and offers no way to override
        # that, so when the store is the problem it cannot succeed. Go straight to the
        # MSI, which we fetch with curl and can point at a CA (or not verify at all).
        $useWinget = (-not $Insecure) -and (-not $CaCert) -and (Get-Command winget -ErrorAction SilentlyContinue)

        if ($useWinget) {
            try {
                Install-NodeViaWinget
            } catch {
                Write-WarnMsg "winget could not install Node.js ($($_.Exception.Message)). Falling back to nodejs.org..."
                Install-NodeViaMsi -IsAdmin $isAdmin
            }
        } else {
            if ($Insecure -or $CaCert) {
                Write-Info "Skipping winget: it can only verify TLS against the Windows store."
            }
            Install-NodeViaMsi -IsAdmin $isAdmin
        }

        Update-SessionPath

        if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
            throw "Node.js installation finished, but 'node' is still not on PATH. Close and reopen PowerShell, then re-run this script."
        }
        Write-Info "Node.js installed successfully ($(node -v))."
    }

    Write-Info "Installing $CloudCliPackage globally via npm..."
    $npmArgs = @('install', '-g', $CloudCliPackage)
    if ($Insecure) { $npmArgs += '--strict-ssl=false' }

    Invoke-Npm -NpmArgs $npmArgs
    if ($LASTEXITCODE -ne 0) {
        throw "npm install -g $CloudCliPackage failed with exit code $LASTEXITCODE"
    }

    Write-Info "Done! $CloudCliPackage is installed."
    if ($CaCert) {
        Write-Info "Tip: set NODE_EXTRA_CA_CERTS to that CA permanently so npm keeps working: setx NODE_EXTRA_CA_CERTS `"$CaCert`""
    }
}

# ---------------------------------------------------------------------------
# `irm | iex` runs in the caller's own session, so any TLS state this script changes
# has to be put back, and a failure must not call exit (that would close their shell).
# ---------------------------------------------------------------------------
$prevCertCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
$prevNodeTls      = $env:NODE_TLS_REJECT_UNAUTHORIZED
$prevNodeExtraCa  = $env:NODE_EXTRA_CA_CERTS

if ($Insecure) { $env:NODE_TLS_REJECT_UNAUTHORIZED = '0' }
if ($CaCert)   { $env:NODE_EXTRA_CA_CERTS = $CaCert }

$failed = $false
try {
    Install-CloudCli
} catch {
    $failed = $true
    Write-ErrorMsg $_.Exception.Message
    Write-TlsHint
    Write-ErrorMsg "If Node.js itself is the problem, install it manually from $NodeDownloadPage and re-run this script."
} finally {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $prevCertCallback
    $env:NODE_TLS_REJECT_UNAUTHORIZED = $prevNodeTls
    $env:NODE_EXTRA_CA_CERTS = $prevNodeExtraCa
}

# $PSCommandPath is set only when this runs from a file, so `irm | iex` never hits exit.
if ($failed -and $PSCommandPath) { exit 1 }
