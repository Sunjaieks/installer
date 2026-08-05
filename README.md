# installer

Installers for [`@cloudcli-ai/cloudcli`](https://www.npmjs.com/package/@cloudcli-ai/cloudcli).
Each script installs Node.js first if it isn't already present, then installs cloudcli globally with npm.

## One-line install

**macOS — Terminal**

```bash
curl -k -fsSL https://raw.githubusercontent.com/Sunjaieks/installer/refs/heads/main/install-cloudcli-mac.sh | bash -s -- --insecure
```

**Windows — PowerShell** (recommended)

```powershell
[Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}; $env:CLOUDCLI_INSECURE='1'; irm https://raw.githubusercontent.com/Sunjaieks/installer/refs/heads/main/install-cloudcli-windows.ps1 | iex
```

**Windows — Command Prompt**

```bat
curl -k -fsSL https://raw.githubusercontent.com/Sunjaieks/installer/refs/heads/main/install-cloudcli-windows.cmd -o "%TEMP%\install-cloudcli-windows.cmd" && "%TEMP%\install-cloudcli-windows.cmd" --insecure
```

Run from an elevated window if Node.js still needs to be installed.

Each command skips TLS certificate verification twice over: once for the download of the
script itself (`-k`, or the PowerShell callback), and once inside it (`--insecure` /
`CLOUDCLI_INSECURE`) for the Node.js installer and npm. That is what lets a machine behind
a TLS-inspecting proxy — one whose root CA is missing from the OS trust store — finish in a
single command, instead of failing with `SEC_E_UNTRUSTED_ROOT` or "Could not establish
trust relationship for the SSL/TLS secure channel".

The trade-off is that nothing downloaded is authenticated. After running the PowerShell
one, put verification back for the rest of that session:

```powershell
[Net.ServicePointManager]::ServerCertificateValidationCallback = $null
```

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
- `install-cloudcli-windows.cmd` must keep CRLF line endings; see `.gitattributes`.
