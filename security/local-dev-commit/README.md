# Local Dev / Commit Security Gate

The Davids workspace contains 12 repositories. Each includes its own `.gitleaks.toml`, `.githooks/pre-commit` and build configuration so it can be checked independently. The files in this folder are reference copies for the local security configuration.

## Activate the pre-commit hook

A hook does **not** run merely because its file exists. From the `Davids` repository, after cloning the sibling repositories, run:

```powershell
./scripts/security/local-dev-commit/Install-GitHooks.ps1 -InstallGitleaks
```

The script configures `core.hooksPath=.githooks` in the Davids Git checkouts it finds and installs Gitleaks if requested and not already available. This replaces any existing local `core.hooksPath` setting, so review custom hooks before running it. It skips missing repository directories; if a directory has no `.git` metadata, it cannot configure its hook. Run it again after cloning or initialising a repository. Check the script output to see how many Git repositories were configured. An existing Gitleaks executable found by the script is reused.

To check a particular checkout from PowerShell:

```powershell
git -C ../Davids.Services.Products config --local --get core.hooksPath
```

Expected output is `.githooks`. Repeat for other repositories as needed. This checks the setting, not whether the hook was successfully executed. Git hooks can be bypassed; use CI and repository rules as additional controls.

When activated, `.githooks/pre-commit` rejects staged private-key, certificate and local secret-file patterns and scans staged changes with Gitleaks. It blocks the commit if Gitleaks is unavailable. `.gitleaks.toml` supplies the repository's scan rules.

## Build and manual checks

`Directory.Build.props` imports `Davids.Shared/eng/Davids.Common.props` when available and provides standalone fallback settings otherwise. The configuration enables .NET security analyzers and NuGet auditing; verify actual results in the build/restore output rather than assuming a scan passed.

Run the local workspace suite from `Davids`:

```powershell
./scripts/security/local-dev-commit/Invoke-LocalDevCommitGates.ps1 -InstallGitleaks
```

The suite configures available Git hooks, scans the repository directories for secrets and audits the aggregate solution's NuGet dependencies. It expects the sibling repositories to be present. `-InstallGitleaks` may download a checksum-verified tool if none is found. Review findings and avoid sharing secret values.
