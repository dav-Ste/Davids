# Local Dev / Commit Security Gate

Runs automatically on **every local `git commit` and `dotnet build`** across all 7 `Davids` repositories (`$0` open-source tools):

- `gitleaks.toml` — Canonical Gitleaks secret & private-key ruleset (active at repo root `.gitleaks.toml`).
- `pre-commit` — Canonical Git pre-commit hook blocking `.pfx`, `.p12`, `.key`, `.jks`, `.kdbx`, `.env`, and secret leaks (active at `.githooks/pre-commit`).
- `Directory.Build.props` (repo root) — Enforces `<NuGetAudit>true</NuGetAudit>` (`NU1900`–`NU1904` as errors) and `<AnalysisModeSecurity>All</AnalysisModeSecurity>`.

Run manually from `Davids`:
```powershell
./scripts/security/local-dev-commit/Invoke-LocalDevCommitGates.ps1 -InstallGitleaks
```
