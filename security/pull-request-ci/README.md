# Pull Request CI Security Gate

Runs automatically on **every pull request and push to `main`** via `.github/workflows/codeql.yml` and `.github/workflows/pull-request-ci.yml`:

- `codeql/codeql-config.yml` — GitHub CodeQL `security-extended` SAST configuration (`csharp` + `javascript-typescript`).
- `semgrep/davids-security.yml` — 10 custom `Davids` Semgrep SAST & architecture rules.
- Validates `deploy/k8s/*.yaml`, `Dockerfile`s, and GitHub Actions workflows via `istioctl analyze`, `Checkov`, `Grype`, and `Trivy`.

Run locally from `Davids`:
```powershell
./scripts/security/pull-request-ci/Invoke-PullRequestCiGates.ps1 -InstallTools
```
