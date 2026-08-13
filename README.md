# installer

Installers for [`@cloudcli-ai/cloudcli`](https://www.npmjs.com/package/@cloudcli-ai/cloudcli).
Each script installs Node.js first if it isn't already present, then installs cloudcli globally with npm.

## One-line install

**macOS — Terminal**

```bash
curl -k -fsSL https://raw.githubusercontent.com/Sunjaieks/installer/refs/heads/main/cloud-cli/mac-install.sh | bash -s -- --insecure
```

**Windows — PowerShell**

```powershell
$env:CLOUDCLI_INSECURE='1'; iex (curl.exe -k -fsSL https://raw.githubusercontent.com/Sunjaieks/installer/refs/heads/main/cloud-cli/windows-install.ps1 | Out-String)
```

**Windows — Command Prompt**

```bat
curl -k -fsSL https://raw.githubusercontent.com/Sunjaieks/installer/refs/heads/main/cloud-cli/windows-install.cmd -o "%TEMP%\windows-install.cmd" && "%TEMP%\windows-install.cmd" --insecure
```

Run from an elevated window if Node.js still needs to be installed.

Each command skips TLS certificate verification twice over: once for the download of the
script itself (`curl -k`), and once inside it (`--insecure` / `CLOUDCLI_INSECURE`) for the
Node.js installer and npm. That is what lets a machine behind a TLS-inspecting proxy — one
whose root CA is missing from the OS trust store — finish in a single command, instead of
failing with `SEC_E_UNTRUSTED_ROOT` or "Could not establish trust relationship for the
SSL/TLS secure channel".

The trade-off is that nothing downloaded is authenticated.

The PowerShell command deliberately fetches with `curl.exe` rather than `irm`, and runs the
result through `iex` rather than saving a `.ps1`:

- `irm` goes through .NET's HTTP stack, which on a locked-down machine can still fail after
  the certificate callback is relaxed ("An unexpected error occurred on a send") even with
  `SecurityProtocol` already set to `Tls12`. `curl.exe` uses schannel and `-k` is enough.
- `iex` executes a string, so it is not subject to ExecutionPolicy. Saving the script and
  running it as a file fails with "running scripts is disabled on this system" wherever
  policy is Restricted.
- `Out-String` is required: piping `curl.exe` straight into `iex` passes an array of lines,
  and `iex` would try to execute each line on its own.

## Notes

- Node.js is installed via winget (Windows) or Homebrew (macOS) when available, otherwise
  from the official installer on nodejs.org. The LTS version is resolved from
  `https://nodejs.org/dist/index.tab`.
- winget is skipped in insecure mode: it can only validate TLS against the Windows store,
  so it cannot succeed when that store is the problem.
- To verify against a corporate root CA instead of skipping verification, pass
  `--cacert <path-to-ca.pem>` or set `CLOUDCLI_CACERT`. Run any script with `--help` for
  details. `npm` keeps its own CA list and ignores the OS trust store, so it also needs
  `NODE_EXTRA_CA_CERTS`.
- `cloud-cli/windows-install.cmd` must keep CRLF line endings; see `.gitattributes`.
