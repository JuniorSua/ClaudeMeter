# Security Policy

ClaudeMeter is a local-first macOS menu bar app. This document explains how it
handles your data and how to report a vulnerability.

## How ClaudeMeter handles credentials and data

- **No secrets are stored in this repository or the app.** ClaudeMeter contains
  no API keys or tokens.
- **Reading your Claude login:** when "official account usage" is enabled,
  ClaudeMeter reads your existing Claude Code OAuth access token from the macOS
  Keychain (item `Claude Code-credentials`) at runtime. macOS prompts you to
  approve this access the first time. The token is used only to authorize a
  single request and is **never written to disk, logged, or included in the
  local cache.**
- **Network:** the only outbound request is an HTTPS `GET` to Anthropic's
  official usage endpoint (`https://api.anthropic.com/api/oauth/usage`) with the
  bearer token in the `Authorization` header. No log content, prompt text, or
  personal data is transmitted. The app works offline (showing local usage
  only) if this is disabled or unreachable.
- **Local logs:** ClaudeMeter reads `~/.claude` for usage **metadata only**
  (token counts, model names, timestamps). It never stores prompt, completion,
  or tool-output text. Only aggregated metadata is written to the app's cache in
  `~/Library/Application Support/ClaudeMeter/`.
- **No telemetry.** ClaudeMeter does not collect analytics or send data to any
  third party.

## Reporting a vulnerability

If you find a security issue, please open a
[GitHub issue](../../issues) describing the problem, or contact the maintainer
privately via GitHub. Please do not include real tokens or credentials in any
report.

## Scope notes

- The app is intended for the machine's own Claude Code activity and the signed-
  in account's official usage. It reflects only local activity on this Mac.
- Builds are self-signed / ad-hoc; verify you trust the source before running.
