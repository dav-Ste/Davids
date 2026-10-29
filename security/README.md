# Davids Security Configurations by Lifecycle Stage

All security configurations, fuzzing grammars, DAST plans, admission test fixtures, runtime rules, and alerting definitions are organized by **when and where they execute in production**:

| Stage | Config Folder (`security\...`) | PowerShell Runners (`scripts\security\...`) | GitHub Actions Workflow (`.github\workflows\...`) | Frequency |
|---|---|---|---|---|
| **Local Dev / Commit** | `security\local-dev-commit\` (`gitleaks.toml`, `pre-commit`) | `scripts\security\local-dev-commit\Invoke-LocalDevCommitGates.ps1` (`Install-GitHooks.ps1`, `Scan-Secrets.ps1`, `Verify-Dependencies.ps1`) | *(Local Git pre-commit hook & `dotnet build`)* | Every local commit & build |
| **Pull Request CI** | `security\pull-request-ci\` (`codeql\codeql-config.yml`, `semgrep\davids-security.yml`) | `scripts\security\pull-request-ci\Invoke-PullRequestCiGates.ps1` (`Scan-Semgrep.ps1`, `Scan-IaC.ps1`, `Scan-SupplyChain.ps1`) | `codeql.yml`, `pull-request-ci.yml` | Every pull request & push to `main` |
| **Staging / Nightly** | `security\staging-nightly\` (`openapi\`, `schemathesis\`, `nuclei\`, `burp\`) | `scripts\security\staging-nightly\Invoke-StagingNightlyGates.ps1` (`Export-OpenApiSpecs.ps1`, `Scan-Schemathesis.ps1`, `Scan-Nuclei.ps1`, `Scan-Dastardly.ps1`) | `staging-nightly.yml` | Every staging deploy & nightly schedule |
| **Quarterly / Release** | `security\quarterly-release\` (`restler\`, `zap\zap-automation.yaml`, `authz\`) | `scripts\security\quarterly-release\Invoke-QuarterlyReleaseGates.ps1` (`Scan-Restler.ps1`, `Scan-Zap.ps1`, `Scan-AuthzMatrix.ps1`) | `quarterly-release.yml` | Every GitHub release & quarterly schedule |
| **Production Cluster** | `security\production-cluster\` (`kyverno-tests\`, `falco\`, `prometheus\`, `seq\`) + cluster manifests in `deploy\k8s\` | `scripts\security\production-cluster\Verify-ProductionClusterGates.ps1` (`Bootstrap-SeqSecurityAlerts.ps1`) | `production-cluster.yml` | Continuous (24/7 in cluster) + verified on PR/push |
