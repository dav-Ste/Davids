# Continuous Security Testing & Hardening Playbook for Davids

This playbook documents how to test, scan, and continuously harden the **Davids** `.NET 10` microservices platform (`Davids.APIGateway`, `Davids.Services.Identity`, `Davids.Services.AdminIdentity`, `Davids.Services.Customers`, `Davids.Frontend.Admin`, `Davids.Shared`, and `Davids`) across local development, CI/CD, staging, and Kubernetes/Istio production.

---

## 1. Getting Maximum Coverage from Burp Suite Against `Davids`

Because `Davids` uses a **YARP OIDC BFF (`davids_admin_bff` cookie + CSRF header)** for `Davids.Frontend.Admin` and **dual asymmetric `RS256` authorities** (`Identity` vs. `AdminIdentity`) for APIs, an unconfigured crawler will stop at `/login` or `403 csrf_rejected`. Configure Burp Suite specifically for the `Davids` architecture:

- **Import OpenAPI 3.x definitions**:
  - Start the services in `Development` to export `/openapi/v1.json` from `Davids.Services.Identity`, `Davids.Services.AdminIdentity`, and `Davids.Services.Customers`.
  - Import those OpenAPI JSON definitions into Burp Scanner (with paths mapped to the YARP Gateway prefixes `/identity/*`, `/admin-identity/*`, and `/customers/*`) so every endpoint and JSON payload field is fuzzed.
- **Configure Session Handling Rules & Recorded Logins**:
  - Record an OIDC login sequence (`/login` -> `/auth/login` -> `/admin-identity/connect/authorize`) so Burp automatically renews expired `davids_admin_bff` cookies during long scans.
  - Add a Burp **Session Handling Rule** that injects `X-Requested-With: DavidsAdmin` and a matching `Origin` header on state-changing requests (`POST`, `PUT`, `DELETE`) when testing authenticated business logic, while maintaining a separate scan profile *without* that header to verify CSRF enforcement (`403 csrf_rejected`) never regresses.
- **High-value Free Burp Suite Community Edition (`$0`) BApp Extensions for `Davids`**:
  - **Burp Suite Community Edition (`$0`)** supports both **Autorize** and **JWT Editor** from the BApp Store with zero license cost (load `security/quarterly-release/authz/burp-community-project-options.json` and follow `security/quarterly-release/authz/BURP-COMMUNITY-GUIDE.md`).
  - **Autorize** *(plus automated headless CI runner `./scripts/security/quarterly-release/Scan-AuthzMatrix.ps1`)*: Configure a `CustomerBearer` JWT (`role=user`), a second customer's `CustomerBearer` JWT, and an unauthenticated session while browsing as an administrator. Every admin request (`/customers`, `PUT /customers/{id}`, `/admin-identity/users`, `/admin-identity/login-audits`) is replayed automatically across `31` matrix cases (`AUTHZ-001`..`AUTHZ-031`) to catch **BOLA/IDOR** and privilege-escalation regressions.
  - **JWT Editor** *(plus `11` live cryptographic boundary attacks `CRYPTO-001`..`CRYPTO-011` in `./scripts/security/quarterly-release/Scan-AuthzMatrix.ps1`)*: Test algorithm confusion (`alg: none`, `HS256` signed with the public RSA JWKS from `/.well-known/jwks`), rogue RSA keypairs with injected `jku`/`jwk` headers, payload claim tampering, PKCE `code_verifier` omission/mismatch, single-use authorization-code replay cascade revocation (`RFC 6749 §10.5`), and explicit `RFC 7009` access-token revocation.
- **Automating Active DAST in CI/CD at `$0` Cost**:
  - **Dastardly (by PortSwigger)**: Free Docker-based CI/CD scanner using the Burp Scanner engine (10-minute scan cap, outputs JUnit XML) for fast nightly smoke checks (`security/staging-nightly/burp/dastardly-seeds.json` + `./scripts/security/staging-nightly/Scan-Dastardly.ps1`).
  - **OWASP ZAP `2.17.0` Automation Framework** (`security/quarterly-release/zap/zap-automation.yaml` + `./scripts/security/quarterly-release/Scan-Zap.ps1`): 100% free (`Apache-2.0`), uncapped active + passive + OpenAPI DAST scanning across `/login`, Customer APIs, and Admin APIs with native SARIF 2.1.0 export.

---

## 2. Complementary DAST & Stateful API Fuzzers (What Burp Misses)

- **Schemathesis** *(Open Source — Property-Based OpenAPI Fuzzing)*:
  - Generates thousands of edge-case and negative payloads from `/openapi/v1.json` contracts using property-based testing to uncover unhandled `500` exceptions, boundary bugs, and undocumented status codes.
- **Microsoft RESTler** *(Open Source — Stateful REST API Fuzzer)*:
  - Chains endpoints in stateful sequences (for example: register user -> OIDC sign-in -> create customer -> mutate customer state -> re-fetch) to discover business-logic and state-transition bugs that stateless scanners miss.
- **ZAP (by Checkmarx, formerly OWASP ZAP)** *(Apache-2.0)*:
  - Open-source headless API scanner (`zap-api-scan.py` or ZAP Automation Framework) with native SARIF export into GitHub Security.
- **ProjectDiscovery Nuclei** *(MIT)*:
  - Fast, low-false-positive template scanner. Ideal for checking exposed `.well-known/openid-configuration`, TLS/CSP headers, accidental exposure of internal UIs (Vault, RabbitMQ management, Seq, Prometheus, Jaeger, Grafana), and custom YAML security regression templates.

---

## 3. Static Analysis (SAST) for `.NET 10` & Frontend JavaScript

- **GitHub CodeQL (`csharp` + `javascript-typescript`, `security-extended` suite)**:
  - Performs inter-procedural taint and data-flow tracking across C# Minimal APIs, YARP request transforms, EF Core queries, and `Davids.Frontend.Admin/wwwroot/*.js` DOM sinks.
- **Semgrep**:
  - Fast PR scanner supporting **custom architecture guardrails** tailored to `Davids`, such as:
    - Flagging any new `MapGet`/`MapPost`/`MapPut`/`MapDelete` in `Davids.Services.AdminIdentity` missing `.RequireAuthorization("AdminOnly")` or explicit `.AllowAnonymous()`.
    - Blocking `FromSqlRaw` / `ExecuteSqlRaw` with string interpolation, `AllowAnyOrigin()`, `ServerCertificateCustomValidationCallback`, or `SigningKey` references inside `Customers` or `APIGateway`.
- **Roslyn Security Analyzers at Compile Time**:
  - Keep `-warnaserror` enabled alongside `<AnalysisModeSecurity>All</AnalysisModeSecurity>` and `SecurityCodeScan.VS2019` / `SonarAnalyzer.CSharp` so insecure crypto, SQLi, XSS, path traversal, or weak RNG fail the build immediately inside Visual Studio and CI.

---

## 4. Software Composition Analysis (SCA), Lockfiles & Container Supply Chain

- **Native NuGet Vulnerability Auditing (`NuGetAudit`)**:
  - Configure `<NuGetAudit>true</NuGetAudit>`, `<NuGetAuditMode>all</NuGetAuditMode>`, and `<NuGetAuditLevel>low</NuGetAuditLevel>` in `Directory.Build.props` with `NU1901`–`NU1904` treated as errors so `dotnet restore` fails automatically if any direct or transitive package in `packages.lock.json` receives a CVE advisory.
  - Run `dotnet list <sln> package --vulnerable --include-transitive --format json` on a nightly schedule (parse JSON output with `jq` or PowerShell rather than relying on exit code `0`).
- **Dependabot or Renovate**:
  - Automate lockfile-aware PRs for NuGet (`Directory.Packages.props` + `packages.lock.json`), `.NET 10` base images, and pinned container tags (`sql`, `redis`, `rabbitmq`, `vault`, `grafana`).
- **Container Image & SBOM Scanning**:
  - Generate CycloneDX/SPDX SBOMs on every build with **Anchore Syft** (`syft`) or `Microsoft.Sbom.Targets`, and scan built images with **Anchore Grype**, **Snyk Container**, or **Trivy** (blocking on `HIGH`/`CRITICAL` CVEs).
  - Sign container images and SBOM attestations with **Sigstore Cosign** (`cosign sign`).
  - **CI Supply-Chain Hardening**: Pin all third-party GitHub Actions to **full 40-character commit SHAs** (never mutable tags) and verify scanner binaries/images by SHA-256 digest (for example, guarding against tag-rewriting attacks such as the March 2026 `trivy-action` / Trivy `CVE-2026-33634` compromise).

---

## 5. Secret Detection (Pre-Commit + CI)

- **Gitleaks** & **TruffleHog**:
  - Run **Gitleaks** as a local `pre-commit` hook so RSA private keys (`-----BEGIN PRIVATE KEY-----`), Vault tokens, SQL passwords, Data Protection master keys, or `BffClientSecret` values are blocked before `git commit`.
  - Run `gitleaks` (`--redact` across `base..head` commits) and `trufflehog` as blocking PR checks across all 7 repositories.

---

## 6. Kubernetes, Istio Service Mesh & IaC Hardening

- **`istioctl analyze` in CI**:
  - Validate Istio `PeerAuthentication` (`STRICT` mTLS between `APIGateway`, `Identity`, `AdminIdentity`, `Customers`, and `Frontend.Admin`), `AuthorizationPolicy` (restricting backend service callers to `APIGateway`'s Envoy service account), and `RequestAuthentication` `jwksUri` settings, while keeping Istio patched against control/data-plane advisories (such as `CVE-2026-41413`).
- **Checkov / Kubescape / Kube-linter**:
  - Scan `deploy/k8s/*.yaml` and Dockerfiles in CI to enforce `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile: RuntimeDefault`, resource limits, and default-deny `NetworkPolicy` manifests.
- **Kyverno or OPA Gatekeeper (Cluster Admission Control)**:
  - Reject any pod at deploy time that uses `:latest`, lacks a valid Cosign signature, runs as `root`, or disables Istio sidecar injection.

---

## 7. Runtime Threat Detection & Security Alerting

- **Falco or Cilium Tetragon (eBPF Runtime Security)**:
  - Detect post-exploitation activity inside Kubernetes pods in real time (for example, a `.NET` container spawning `/bin/sh` or `curl`, reading unexpected files, or opening outbound connections to unknown external IPs).
- **Grafana / Prometheus / Seq Security Alerting**:
  - Alert on spikes in `Davids.Security.Audit` `429` rate-limiter rejections across `APIGateway`, `Identity`, and `AdminIdentity`.
  - Alert on spikes in `AdminLoginAuditLogs` / `CustomerLoginAuditLogs` outcomes `account_locked`, `invalid_request_token`, or `token_grant_rejected` (detecting single-use refresh-token replay or credential-stuffing attacks immediately).
  - Ship HashiCorp Vault audit logs to Seq/Elasticsearch and alert on seal events, auth failures, or unexpected secret reads.

---

## 8. Lifecycle Security Folder & Rollout Matrix

All security configuration files (`security/<stage>/`), PowerShell runners (`scripts/security/<stage>/`), and GitHub Actions workflows (`.github/workflows/`) are organized by **when and where they execute in production**:

| Stage | Folder (`security/...` & `scripts/security/...`) | Tools Enabled | Frequency | Status |
|---|---|---|---|---|
| **Local Dev / Commit** | `local-dev-commit` | `Gitleaks` pre-commit hook (`.githooks/pre-commit` + `.gitleaks.toml`) + `NuGetAudit` (`NU1900`–`NU1904` as errors, `NuGetAuditMode=all`, `NuGetAuditLevel=low`) + `.NET` `AnalysisModeSecurity=All` | Every commit / build | **Implemented across all 7 repos** (`./scripts/security/local-dev-commit/Invoke-LocalDevCommitGates.ps1`, `Install-GitHooks.ps1`, `Scan-Secrets.ps1`, `Verify-Dependencies.ps1`) |
| **Pull Request CI** | `pull-request-ci` | `CodeQL` (`csharp` + `javascript-typescript`, `security/pull-request-ci/codeql/codeql-config.yml`), `Semgrep` (10 custom `Davids` rules in `security/pull-request-ci/semgrep/davids-security.yml`), `dotnet list package --vulnerable --format json`, `Checkov` + `istioctl analyze`, 40-char SHA-pinned `Grype`/`Trivy` | Every PR (blocking) | **Implemented across all 7 repos** (`.github/workflows/codeql.yml`, `.github/workflows/pull-request-ci.yml`, `./scripts/security/pull-request-ci/Invoke-PullRequestCiGates.ps1 -InstallTools`) |
| **Staging / Nightly** | `staging-nightly` | **PortSwigger Dastardly** / **Burp Suite DAST** (`security/staging-nightly/burp/*`) + **Schemathesis `4.32.6`** OpenAPI 3.1 fuzzing & stateful state-machine testing (`security/staging-nightly/openapi/*.gateway.openapi.json` + `security/staging-nightly/schemathesis/schemathesis.toml`) + **ProjectDiscovery Nuclei `3.11.1`** (4 positive posture assertions + 6 negative vulnerability templates in `security/staging-nightly/nuclei/*`) | Every deploy to staging / nightly | **Implemented** (`.github/workflows/staging-nightly.yml`, `./scripts/security/staging-nightly/Invoke-StagingNightlyGates.ps1`, `Export-OpenApiSpecs.ps1`, `Scan-Schemathesis.ps1`, `Scan-Nuclei.ps1`, `Scan-Dastardly.ps1`) |
| **Quarterly / Release** | `quarterly-release` | **Microsoft RESTler** stateful producer/consumer API fuzzing (`security/quarterly-release/restler/*`) + **OWASP ZAP `2.17.0`** Automation Framework active/passive & OpenAPI DAST (`security/quarterly-release/zap/zap-automation.yaml`) + automated **Cross-Role Authorization Matrix (`Autorize`) & JWT/OIDC Cryptographic Boundary Gate** (`31` `AUTHZ-*` + `11` `CRYPTO-*` checks in `security/quarterly-release/authz/*`) + **Burp Suite Community Edition (`$0`)** (`Autorize` + `JWT Editor`) | Quarterly & every GitHub release | **Implemented (`$0` OSS/Community toolchain)** (`.github/workflows/quarterly-release.yml`, `./scripts/security/quarterly-release/Invoke-QuarterlyReleaseGates.ps1`, `Scan-Restler.ps1`, `Scan-Zap.ps1`, `Scan-AuthzMatrix.ps1`) |
| **Production Cluster** | `production-cluster` (+ `deploy/k8s`) | **Kyverno `v1.19.2` + Sigstore Cosign** (`deploy/k8s/kyverno/*` + `18/18` `kyverno test` assertions in `security/production-cluster/kyverno-tests/*`) + **Istio `1.31.3` `STRICT` mTLS & `DENY`/`ALLOW` `AuthorizationPolicy`** (`deploy/k8s/istio-mesh-security.yaml`) + **Falco `0.45.1` & Cilium Tetragon `v1.7.1`** eBPF runtime detection/`Sigkill` enforcement (`security/production-cluster/falco/davids_rules.yaml`, `deploy/k8s/runtime-security/*`) + **OpenTelemetry `Davids.Security.Audit` + Prometheus `promtool`-tested rules, Grafana `13.2.4` Unified Alerting/Dashboard, & Seq Signals** (`security/production-cluster/prometheus/*`, `security/production-cluster/seq/*`) | Continuous (24/7) & every PR/push | **Implemented (`$0` OSS CNCF/Community toolchain)** (`.github/workflows/production-cluster.yml`, `./scripts/security/production-cluster/Verify-ProductionClusterGates.ps1`, `Bootstrap-SeqSecurityAlerts.ps1`) |

---

## References

- PortSwigger — Burp Suite DAST CI-Driven Scans & API Scanning: https://portswigger.net/burp/documentation/dast/user-guide/ci-cd/ci-driven-scans and https://portswigger.net/burp/documentation/scanner/api-scanning-faq
- PortSwigger — Dastardly Free CI/CD Scanner: https://portswigger.net/burp/dastardly
- Schemathesis (Property-Based OpenAPI Testing): https://schemathesis.io/
- Microsoft RESTler (Stateful REST API Fuzzing): https://github.com/microsoft/restler-fuzzer
- ZAP (by Checkmarx): https://www.zaproxy.org/
- ProjectDiscovery Nuclei: https://github.com/projectdiscovery/nuclei
- GitHub CodeQL: https://codeql.github.com/
- Semgrep: https://semgrep.dev/
- Gitleaks: https://github.com/gitleaks/gitleaks
- Microsoft NuGet Auditing (`NuGetAudit`): https://learn.microsoft.com/en-us/nuget/concepts/auditing-packages
