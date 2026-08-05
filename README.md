# installer

Installers for [`@cloudcli-ai/cloudcli`](https://www.npmjs.com/package/@cloudcli-ai/cloudcli).
Each script installs Node.js first if it isn't already present, then installs cloudcli globally with npm.

## One-line install

**macOS — Terminal**

```bash
curl -fsSL https://raw.githubusercontent.com/Sunjaieks/installer/refs/heads/main/install-cloudcli-mac.sh | bash
```

**Windows — PowerShell** (recommended)

```powershell
irm https://raw.githubusercontent.com/Sunjaieks/installer/refs/heads/main/install-cloudcli-windows.ps1 | iex
```

**Windows — Command Prompt**

```bat
curl -fsSL https://raw.githubusercontent.com/Sunjaieks/installer/refs/heads/main/install-cloudcli-windows.cmd -o "%TEMP%\install-cloudcli-windows.cmd" && "%TEMP%\install-cloudcli-windows.cmd"
```

Run from an elevated window if Node.js still needs to be installed.

## Behind a TLS-inspecting proxy

Corporate proxies (Netskope, Zscaler and friends) re-sign HTTPS with their own root CA.
If that CA isn't in your machine's trust store, downloads fail with
`SEC_E_UNTRUSTED_ROOT`, `certificate verify failed`, or PowerShell's
"Could not establish trust relationship for the SSL/TLS secure channel" — all of which
are trust-chain failures, not TLS-version problems.

The proper fix is to install the proxy's root CA into your OS trust store. Failing that,
every script accepts the same two settings:

| Setting | Effect |
| --- | --- |
| `CLOUDCLI_CACERT` | Verify against an extra root CA (PEM). Also given to npm via `NODE_EXTRA_CA_CERTS`. Preferred. |
| `CLOUDCLI_INSECURE` | Skip TLS verification entirely. Nothing downloaded can be authenticated. |

```bash
# macOS
curl -fsSL <url> | CLOUDCLI_CACERT=/path/to/ca.pem bash
curl -fsSL <url> | bash -s -- --insecure
```

```powershell
# Windows PowerShell
$env:CLOUDCLI_CACERT = 'C:\path\to\ca.pem'; irm <url> | iex
$env:CLOUDCLI_INSECURE = '1'; irm <url> | iex
```

```bat
rem Windows Command Prompt
"%TEMP%\install-cloudcli-windows.cmd" --cacert C:\path\to\ca.pem
"%TEMP%\install-cloudcli-windows.cmd" --insecure
```

Note that `npm` keeps its own CA list and ignores the OS trust store, so it needs
`NODE_EXTRA_CA_CERTS` even after the OS store is fixed.

## Notes

- Node.js is installed via winget (Windows) or Homebrew (macOS) when available, otherwise
  from the official installer on nodejs.org. The LTS version is resolved from
  `https://nodejs.org/dist/index.tab`.
- winget is skipped when a CA override is in play: it can only validate TLS against the
  Windows store, so it cannot succeed when that store is the problem.
- `install-cloudcli-windows.cmd` must keep CRLF line endings; see `.gitattributes`.
