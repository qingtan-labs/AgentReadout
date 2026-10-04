# Security Policy

## Supported versions

Security fixes are provided for the latest release on the `main` branch.

## Reporting a vulnerability

Please use [GitHub private vulnerability reporting](https://github.com/qingtan-labs/AgentReadout/security/advisories/new). Do not include credentials, authentication files, private conversation content, or other personal data in a public issue.

For ordinary bugs that do not expose sensitive data, use the public issue tracker.

## Security model

Gauge for Codex executes only a Codex binary found at a known application or CLI path. It communicates with that process over pipes, does not invoke a shell for quota refreshes, and does not receive or execute remote code.
