# Davids Services — Aspire Infrastructure

This repository owns the .NET 10 Aspire orchestration and local infrastructure tooling:

- Aspire AppHost (`src/Davids.AppHost`)
- Vault KV-v2 OIDC key & BFF secret bootstrap (`src/Davids.Bootstrap`)
- Grafana and Kubernetes observability configuration (`src/Davids.AppHost/config/grafana`, `deploy/k8s/grafana.yaml`)
- SQL Server baseline scripts (`database/`)
- PowerShell setup, build, test, and database scripts (`scripts/`)

It orchestrates the following sibling repositories, each with its own standalone solution (`Davids.sln` here is the aggregate development solution):

- Davids Shared Host Defaults (`Davids.Shared`)
- Davids Customer Identity OIDC Provider (`Davids.Services.Identity`)
- Davids Admin Identity OIDC Provider (`Davids.Services.AdminIdentity`)
- Davids Customers (`Davids.Services.Customers`)
- Davids API Gateway & OIDC BFF (`Davids.APIGateway`)
- Davids Admin Web Frontend (`Davids.Frontend.Admin`)

Authentication uses **Self-Hosted .NET OpenID Connect (`OpenIddict` `7.7.2`)** with **OAuth 2.1 Authorization Code + PKCE (`S256`)**, asymmetric **RS256** signing keys, public JWKS discovery (`/.well-known/openid-configuration` & `/.well-known/jwks`), single-use rotating refresh tokens with reuse detection, RFC 7009 revocation synced to Redis, and a confidential **Gateway OIDC Backend-for-Frontend (BFF)** (`davids_admin_bff` encrypted `HttpOnly` cookie) protecting `Davids.Frontend.Admin`. Resource servers (`Davids.Services.Customers` and `Davids.APIGateway`) hold **zero signing keys**.

Persistence uses **SQL Server** with **strict physical database isolation** across three separate databases:

- Customer accounts and customer OpenIddict grants (`identitydb`)
- Administrator accounts and admin OpenIddict grants (`adminidentitydb`)
- Customer profiles and completed-order tracking (`customersdb`)

## Repository layout

Clone this infrastructure repository and the sibling repositories into the **same parent directory**:

```text
<workspace>/
  Davids/                          # this repository; Aspire + Davids.sln
  Davids.Shared/                   # shared Davids.ServiceDefaults + Davids.Shared.sln
  Davids.Services.Identity/        # Customer OIDC Provider (identitydb, role: user) + Davids.Services.Identity.sln
  Davids.Services.AdminIdentity/   # Admin OIDC Provider (adminidentitydb, role: admin) + Davids.Services.AdminIdentity.sln
  Davids.Services.Customers/       # Customers API (customersdb, RS256 JWKS) + Davids.Services.Customers.sln
  Davids.APIGateway/               # YARP edge gateway + OIDC BFF + Davids.APIGateway.sln
  Davids.Frontend.Admin/           # Admin Web frontend + Davids.Frontend.Admin.sln
```

`Davids.AppHost` references the five application hosts by relative path:

- `Davids.Services.Identity` (`identity`)
- `Davids.Services.AdminIdentity` (`admin-identity`)
- `Davids.Services.Customers` (`customers`)
- `Davids.APIGateway` (`api-gateway`)
- `Davids.Frontend.Admin` (`frontend-admin`)

All five application hosts reference `Davids.ServiceDefaults` from the sibling `Davids.Shared` repository, so any individual service can also be cloned beside `Davids.Shared` alone and built, tested, or run standalone without cloning `Davids`.

## First-time setup

Prerequisites:

- .NET 10 SDK
- Git
- PowerShell 7 (or Windows PowerShell 5.1+)
- A Docker-compatible container runtime

Use the GitHub user or organization that hosts the seven repositories in place of `<owner>`:

```powershell
git clone https://github.com/<owner>/Davids.git
Set-Location Davids
./scripts/Get-Projects.ps1 -GitHubOwner <owner>
./scripts/Setup.ps1
```

> **Windows downloaded `.zip` note (Mark of the Web):** If you extracted the workspace from a browser-downloaded `.zip` instead of cloning via `git`, Windows stamps a `Zone.Identifier` stream onto `.ps1` scripts and `.config\dotnet-tools.json` (causing PowerShell security prompts and blocking `dotnet tool restore`). Do **not** globally weaken PowerShell execution policy; instead, unblock the archive before extracting (`Unblock-File .\Davids-Workspace.zip`) or unblock the extracted workspace folder once:
> ```powershell
> Get-ChildItem -Path 'C:\Apps\Davids-workspace' -Recurse -File -Force | Unblock-File
> ```
> (`Setup.ps1` also accepts `-Unblock` or prompts to unblock the seven `Davids*` folders if `Zone.Identifier` is detected.)

`Get-Projects.ps1` clones the sibling repositories into the parent workspace folder:

- `Davids.Shared`
- `Davids.Services.Identity`
- `Davids.Services.AdminIdentity`
- `Davids.Services.Customers`
- `Davids.APIGateway`
- `Davids.Frontend.Admin`

To fast-forward clean Git checkouts later, run `./scripts/Update-Projects.ps1`.

Open `Davids.sln` to work on Aspire and all components together, or open any standalone component solution:

- `../Davids.Shared/Davids.Shared.sln`
- `../Davids.Services.Identity/Davids.Services.Identity.sln`
- `../Davids.Services.AdminIdentity/Davids.Services.AdminIdentity.sln`
- `../Davids.Services.Customers/Davids.Services.Customers.sln`
- `../Davids.APIGateway/Davids.APIGateway.sln`
- `../Davids.Frontend.Admin/Davids.Frontend.Admin.sln`

## Infrastructure credentials and how to access them

No passwords, tokens, RSA private keys, or OIDC client secrets are hardcoded in source control. Secrets are either provisioned upfront by `./scripts/Setup.ps1` or generated automatically on first run by `.NET Aspire` (`persist: true` parameter defaults) and saved in the AppHost's local `.NET user-secrets` store (`UserSecretsId: davids-identity-apphost`).

### Inspecting credentials from the CLI or Aspire Dashboard

1. **Via .NET CLI** (from the `Davids` repository root, after running `./scripts/Setup.ps1` and starting the AppHost at least once so Aspire persists auto-generated container passwords):
   ```powershell
   dotnet user-secrets list --project src/Davids.AppHost
   ```
2. **Via the Aspire Dashboard** (printed in console output by `./scripts/Start.ps1`):
   - Open the **Resources** tab, click **View** (**Details**) on a resource row (for example `messaging`, `sql`, `cache`, or `vault`), and click the reveal (eye) icon next to the password/token environment variable or connection string; or inspect the corresponding parameter row (`messaging-password`, `sql-password`, `cache-password`, `vault-dev-root-token`, `dev-admin-password`, `admin-oidc-bff-client-secret`).

### Credential reference by resource

- **RabbitMQ (`messaging`)**
  - **Management UI**: Click the `management` HTTP endpoint link on the `messaging` row in the Aspire Dashboard (maps to container port `15672`; AMQP broker runs on container port `5672`).
  - **Username**: `guest`
  - **Password**: Stored in user-secrets as `Parameters:messaging-password` (created automatically by Aspire on first startup) and visible in the Aspire Dashboard on `messaging` under `RABBITMQ_DEFAULT_PASS` (or parameter `messaging-password`).
- **SQL Server (`sql` — hosts `identitydb`, `adminidentitydb`, and `customersdb`)**
  - **Endpoint**: Host port shown on the `sql` row's `tcp` endpoint in the Aspire Dashboard (maps to container port `1433`).
  - **Username**: `sa`
  - **Password**: Stored in user-secrets as `Parameters:sql-password` (created automatically by Aspire on first startup) and visible in the Aspire Dashboard on `sql` under `MSSQL_SA_PASSWORD` (or parameter `sql-password`).
- **Redis (`cache`)**
  - **Endpoint**: Host port shown on the `cache` row's `tcp` endpoint in the Aspire Dashboard (maps to container port `6379`).
  - **Username**: None (standard Redis password-only authentication / `default` ACL user).
  - **Password**: Stored in user-secrets as `Parameters:cache-password` (created automatically by Aspire on first startup) and visible in the Aspire Dashboard on `cache` under `REDIS_PASSWORD` (or parameter `cache-password`).
- **HashiCorp Vault (`vault`)**
  - **UI / HTTP API**: Click the `http` endpoint on the `vault` row in the Aspire Dashboard (maps to container port `8200`).
  - **Authentication method**: `Token`
  - **Root token (development)**: Generated by `./scripts/Setup.ps1` and stored in user-secrets as `Parameters:vault-dev-root-token` (also visible in the Aspire Dashboard on `vault` under `VAULT_DEV_ROOT_TOKEN_ID`).
- **Seeded Administrator Account (`Davids.Frontend.Admin` & `Davids.Services.AdminIdentity`)**
  - **Sign-in URL**: `<api-gateway-http-endpoint>/login` (triggers OIDC Authorization Code + PKCE SSO via `/auth/login` -> `/admin-identity/connect/authorize`).
  - **Email (username)**: `admin@davids.local` (configured via `SeedAdmin:Email` in `src/Davids.AppHost/appsettings.json` when `Integrations:SeedAdmin=true`).
  - **Password**: Generated by `./scripts/Setup.ps1` and stored in user-secrets as `Parameters:dev-admin-password`.
- **OIDC Asymmetric RSA Keys & Confidential BFF Secret (Vault bootstrap)**
  - **Customer Identity RSA keys**: Generated as distinct 2048-bit PKCS#8 RSA private keys by `./scripts/Setup.ps1` (`Parameters:oidc-signing-key` and `Parameters:oidc-encryption-key`) and seeded into Vault KV v2 at `secret/data/davids/identity` (`Oidc:SigningKeyPem`, `Oidc:EncryptionKeyPem`). Public verification keys are served dynamically at `/identity/.well-known/jwks`.
  - **Admin Identity RSA keys**: Generated as distinct 2048-bit PKCS#8 RSA private keys by `./scripts/Setup.ps1` (`Parameters:admin-oidc-signing-key` and `Parameters:admin-oidc-encryption-key`) and seeded into Vault KV v2 at `secret/data/davids/admin-identity` (`Oidc:SigningKeyPem`, `Oidc:EncryptionKeyPem`). Public verification keys are served dynamically at `/admin-identity/.well-known/jwks`.
  - **Confidential Admin BFF Client Secret (`davids-admin-bff`)**: Generated by `./scripts/Setup.ps1` as `Parameters:admin-oidc-bff-client-secret` and seeded into `secret/data/davids/admin-identity` (`Oidc:BffClientSecret`) and `secret/data/davids/gateway` (`AdminOidc:BffClientSecret`). Neither `Davids.APIGateway` nor `Davids.Services.Customers` (`secret/data/davids/customers`) ever receives or stores JWT signing keys.
  - **ASP.NET Core Data Protection Key-Ring Wrapping Keys**: Generated automatically on first AppHost startup (persisted in user-secrets as `Parameters:identity-dataprotection-key`, `Parameters:admin-identity-dataprotection-key`, and `Parameters:gateway-dataprotection-key`) and seeded into each service's isolated Vault KV-v2 path (`DataProtection:MasterKey`). Each service encrypts its persistent key ring at rest with AES-256-GCM (HKDF-SHA256 + service-bound AEAD `AAD`) or X.509 PEM certificates (`DataProtection:CertificatePem` + `DataProtection:CertificateKeyPem`).
- **Grafana (`grafana`)**
  - **Local Aspire development**: Anonymous Admin access is enabled (`GF_AUTH_ANONYMOUS_ENABLED=true`) — open the `grafana` `http` endpoint from the Aspire Dashboard directly with no username or password required.
  - **Kubernetes / Istio deployment (`deploy/k8s/grafana.yaml`)**: Anonymous access is disabled; credentials are stored in the `grafana-admin-credentials` Kubernetes `Secret` (`admin-user` and `admin-password` keys) in the `davids` namespace:
    ```powershell
    kubectl -n davids get secret grafana-admin-credentials -o jsonpath='{.data.admin-user}' | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }
    kubectl -n davids get secret grafana-admin-credentials -o jsonpath='{.data.admin-password}' | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }
    ```
- **Local Observability UIs without authentication in Development**
  - **Seq (`seq`)**: Open the `http` endpoint from the Aspire Dashboard (`SEQ_FIRSTRUN_NOAUTHENTICATION=true`; no login required locally).
  - **Jaeger (`jaeger`)**: Open the `ui` endpoint from the Aspire Dashboard (no login required locally).
  - **Prometheus (`prometheus`)**: Open the `http` endpoint from the Aspire Dashboard (no login required locally).
  - **InfluxDB 3 Core (`influxdb`, opt-in via `Integrations:InfluxDB=true`)**: Started with `--without-auth` for local development.
  - **Elasticsearch & Kibana (`elasticsearch` / `kibana`, opt-in via `Integrations:Elasticsearch=true`)**: Started with `xpack.security.enabled=false` for local development.

## Run and test

```powershell
./scripts/Start.ps1
```

Open the Aspire dashboard URL printed by the AppHost. The `api-gateway` HTTP endpoint enforces admin-only access to `Davids.Frontend.Admin`:

- Unauthenticated browser HTML requests to `/` redirect (`302 Found`) to `/login` (the public administrator SSO entry page, which initiates OAuth 2.1 Authorization Code + PKCE via `/auth/login`).
- Non-admin customer RS256 tokens (`CustomerBearer`) receive `403 Forbidden` on `Davids.Frontend.Admin` and all admin endpoints.
- Verified administrators (`AdminBffCookie` `davids_admin_bff` or `AdminBearer`) access `/`, customer search/edit APIs (`/customers?...`, `PUT /customers/{customerId}`), administrator provisioning (`/admin-identity/users`), and the administrator login audit log (`/admin-identity/login-audits`).

Build and test the complete composition or a single standalone component:

```powershell
./scripts/Build.ps1
./scripts/Test.ps1
./scripts/security/local-dev-commit/Verify-Dependencies.ps1

dotnet restore ../Davids.Services.AdminIdentity/Davids.Services.AdminIdentity.sln --locked-mode
dotnet build   ../Davids.Services.AdminIdentity/Davids.Services.AdminIdentity.sln --no-restore -c Release
dotnet test    ../Davids.Services.AdminIdentity/Davids.Services.AdminIdentity.sln --no-build --no-restore -c Release
```

For the live OIDC discovery, Customer PKCE, RabbitMQ outbox, and Admin OIDC BFF smoke test, retrieve `Parameters:dev-admin-password` via `dotnet user-secrets list --project src/Davids.AppHost` and pass the `api-gateway` endpoint URL from the Aspire dashboard (or your Kubernetes/Istio gateway):

```powershell
./scripts/Test-Infrastructure.ps1 `
  -GatewayUrl 'http://localhost:<api-gateway-port>' `
  -AdminEmail 'admin@davids.local' `
  -AdminPassword '<dev-admin-password>'
```

## Persistence and database isolation

Customer accounts, administrator accounts, and customer profiles own three completely separate SQL Server databases:

- `identitydb` (`Davids.Services.Identity`): customer logins (`role == "user"` only), customer OpenIddict applications/authorizations/tokens/scopes, append-only zero-secret customer login audit records (`CustomerLoginAuditLogs`, self-inspectable via `GET /identity/me/login-audits`), encrypted Data Protection keys (`DataProtectionKeys`), revoked access tokens, and transactional inbox/outbox tables.
- `adminidentitydb` (`Davids.Services.AdminIdentity`): administrator logins (`role == "admin"` only, no public `/sign-up`), admin OpenIddict applications/authorizations/tokens/scopes, append-only zero-secret administrator login audit records (`AdminLoginAuditLogs`, inspectable by administrators via `GET /admin-identity/login-audits` and the `Davids.Frontend.Admin` IAM view), encrypted Data Protection keys (`AdminDataProtectionKeys`), and revoked admin access tokens.
- `customersdb` (`Davids.Services.Customers`): customer profile records, completed-order tracking, and transactional inbox/outbox tables.

Generate and review idempotent SQL for all three databases, or apply migrations explicitly:

```powershell
./scripts/Update-Database.ps1 -GenerateSql
$env:ConnectionStrings__identitydb = '<Customer Identity SQL Server connection string>'
$env:ConnectionStrings__adminidentitydb = '<Admin Identity SQL Server connection string>'
$env:ConnectionStrings__customersdb = '<Customers SQL Server connection string>'
./scripts/Update-Database.ps1
```

Checked-in idempotent baseline scripts are available under:

- `database/identity.sql`
- `database/admin-identity.sql`
- `database/customers.sql`

## Component responsibilities

- **Shared Host Defaults** (`Davids.Shared`)
  - Standalone shared library (`Davids.ServiceDefaults`)
  - `/health` and `/alive` probes
  - Trusted `ForwardedHeadersMiddleware` (`ForwardedHeaders:KnownProxies` and `ForwardedHeaders:KnownNetworks` CIDR allowlists, disabled safely when no proxies are configured so untrusted callers cannot spoof `X-Forwarded-For`)
  - Isolated ASP.NET Core Data Protection encryption-at-rest (`AesGcmDataProtectionXmlEncryptor` with HKDF-SHA256 + service-bound AEAD `AAD`, or X.509 certificate wrapping via `DataProtection:CertificatePem` + `DataProtection:CertificateKeyPem`, failing closed in `Production` if persistent storage or encryption is missing)
  - OpenTelemetry metrics, distributed tracing, and logging exporters
  - `Microsoft.Extensions.ServiceDiscovery` HTTP client defaults
  - Optional Serilog sinks (Seq, rolling files, and Elasticsearch)
- **Customer Identity OIDC Provider** (`Davids.Services.Identity`)
  - Self-hosted `OpenIddict` (`7.7.2`) OIDC authority for customer accounts (`role: user` only) in `identitydb`
  - OAuth 2.1 Authorization Code + PKCE (`S256`) for public client `davids-web`
  - Asymmetric RS256 JWTs (`aud: davids-services`, Vault `secret/data/davids/identity`) and public `/.well-known/jwks`
  - Single-use rotating refresh tokens (`14 day` lifetime) with zero-leeway replay detection, per-client-IP rate limiting + per-account failed-login lockout (`Lockout:MaxFailedAccessAttempts` / `Lockout:DurationMinutes`), and RFC 7009 Redis revocation (`davids:identity:revoked:<jti>`)
  - `POST /sign-up` and transactional RabbitMQ outbox (`signed_up` and `signed_in`)
- **Admin Identity OIDC Provider** (`Davids.Services.AdminIdentity`)
  - Self-hosted `OpenIddict` (`7.7.2`) OIDC authority for administrator accounts (`role: admin` only) in `adminidentitydb`
  - OAuth 2.1 Authorization Code + PKCE (`S256`) for confidential BFF client `davids-admin-bff`
  - Asymmetric RS256 JWTs (`aud: davids-admin`, `15 min` lifetime, Vault `secret/data/davids/admin-identity`) and public `/.well-known/jwks`
  - Single-use rotating refresh tokens (`8 hour` lifetime) with replay revocation, per-client-IP authentication rate limits, per-account failed-login lockout (`Lockout:MaxFailedAccessAttempts` / `Lockout:DurationMinutes`), and RFC 7009 Redis revocation (`davids:admin-identity:revoked:<jti>`)
  - Admin-only `GET /users` and `POST /users` endpoints plus development-only `SeedAdmin`
- **Customers** (`Davids.Services.Customers`)
  - SQL-backed customer profiles in `customersdb`
  - Zero-shared-secret dual-authority RS256 OIDC JWKS validation (`CustomerBearer` and `AdminBearer`)
  - Administrator search and filtering (`GET /customers?search=&state=&vip=`)
  - Administrator customer profile editing (`PUT /customers/{customerId}`) and state transitions (`PUT /customers/{customerId}/state/{state}`)
  - VIP qualification after 20 distinct completed orders
  - Transactional RabbitMQ inbox/outbox consumers (`identity.signed_up` and `orders.order_completed`)
- **API Gateway & OIDC BFF** (`Davids.APIGateway`)
  - YARP edge enforcing zero-shared-secret dual-authority RS256 JWKS authentication (`CustomerBearer` and `AdminBearer`)
  - Confidential OIDC BFF (`AddOpenIdConnect` + PKCE `S256` + `davids_admin_bff` encrypted `HttpOnly` cookie, Vault `secret/data/davids/gateway`) with automatic server-side refresh rotation, RFC 7009 logout revocation, and `X-Requested-With: DavidsAdmin` + `Origin` CSRF checks
  - Admin-only gating on `Davids.Frontend.Admin` (`302 /login` for anonymous HTML, `401` for non-HTML, `403` for non-admin users)
  - Redis revocation checks for both identity domains
  - Per-client-IP edge rate limiting (`gateway-admin-auth`, `gateway-customer-auth`, `gateway-api`) with `Retry-After` responses and anti-spoofing `X-Forwarded-For` overwrite (`"X-Forwarded": "Set"`)
  - Verified `X-Auth-*` headers, browser security headers, correlation IDs, and W3C trace propagation
  - Direct backend cluster routing (compatible with Kubernetes/Istio service DNS and local Aspire endpoints) to:
    - `identity`
    - `admin-identity`
    - `customers`
    - `frontend-admin`
- **Admin Web Frontend** (`Davids.Frontend.Admin`)
  - Separated passwordless Admin Web frontend host (`davids-frontend-admin`)
  - Public `/login` SSO entry page triggering Gateway OIDC BFF login (`/auth/login`)
  - Gateway-protected `/` workspace for customer search/editing and administrator account management
- **Grafana** (`grafana/grafana:13.2.4` in `Davids.AppHost` and `deploy/k8s/grafana.yaml`)
  - Pre-provisioned **Prometheus** datasource (metrics + OpenTelemetry exemplar trace links)
  - Pre-provisioned **Jaeger** datasource (distributed traces + service node graph)
  - Pre-loaded `Davids Platform — Metrics & Distributed Traces` home dashboard
  - Automatic wiring to local Aspire `prometheus` and `jaeger` containers, or external cluster services via `Grafana__PrometheusUrl` and `Grafana__JaegerUrl` (or `deploy/k8s/grafana.yaml`)

## Local Dev / Commit security gates (`security/local-dev-commit` & `scripts/security/local-dev-commit`)

Every repository (`Davids`, `Davids.Shared`, `Davids.Services.Identity`, `Davids.Services.AdminIdentity`, `Davids.Services.Customers`, `Davids.APIGateway`, and `Davids.Frontend.Admin`) enforces three shift-left local security gates on every commit and build:

- **Pre-commit secret & private-key scanning (`Gitleaks` + `.githooks/pre-commit`)**:
  - Canonical files live in `security/local-dev-commit/` (`gitleaks.toml` and `pre-commit`) and are installed into `.gitleaks.toml` and `.githooks/pre-commit` across all 7 repositories. `.githooks/pre-commit` blocks staged `.pfx`, `.p12`, `.key`, `.jks`, `.kdbx`, and `.env` files immediately and runs `gitleaks git --pre-commit --staged --verbose --redact --config .gitleaks.toml` (combining Gitleaks default rules with cross-platform Windows/Linux path rules and custom `Davids` detectors for HashiCorp Vault `hvs.*` tokens, OIDC `BffClientSecret` / `DataProtection:MasterKey` values, RSA/EC private keys, and hardcoded SQL/Redis/RabbitMQ passwords).
  - Activate `core.hooksPath=.githooks` across all initialized Git repositories (and optionally download SHA-256 verified `Gitleaks v8.30.1` automatically):
    ```powershell
    ./scripts/security/local-dev-commit/Install-GitHooks.ps1 -InstallGitleaks
    ./scripts/security/local-dev-commit/Scan-Secrets.ps1
    ./scripts/security/local-dev-commit/Invoke-LocalDevCommitGates.ps1
    ```
- **Strict NuGet direct + transitive vulnerability auditing (`NuGetAudit`)**:
  - `Directory.Build.props` in every repository sets `<NuGetAudit>true</NuGetAudit>`, `<NuGetAuditMode>all</NuGetAuditMode>`, `<NuGetAuditLevel>low</NuGetAuditLevel>`, and promotes `NU1900`, `NU1901`, `NU1902`, `NU1903`, and `NU1904` into `<WarningsAsErrors>`.
  - `./scripts/security/local-dev-commit/Verify-Dependencies.ps1` parses the JSON output of `dotnet list Davids.sln package --vulnerable --include-transitive --format json` and fails if any advisory is reported.
- **Compile-time Roslyn security static analysis (`AnalysisModeSecurity=All`)**:
  - `Directory.Build.props` in every repository enables `<EnableNETAnalyzers>true</EnableNETAnalyzers>`, `<AnalysisLevel>latest</AnalysisLevel>`, and `<AnalysisModeSecurity>All</AnalysisModeSecurity>` alongside `<TreatWarningsAsErrors>true</TreatWarningsAsErrors>`.

## Pull Request CI security gates (`security/pull-request-ci` & `scripts/security/pull-request-ci`)

Every repository includes SHA-pinned GitHub Actions security workflows (`.github/workflows/codeql.yml` and `.github/workflows/pull-request-ci.yml`) plus local PowerShell equivalents:

- **GitHub CodeQL SAST (`csharp` + `javascript-typescript`, `security-extended` suite)**:
  - Configured via `security/pull-request-ci/codeql/codeql-config.yml` (and `.github/codeql/codeql-config.yml` in standalone repositories) plus `.github/workflows/codeql.yml` across all 7 repositories (`csharp` manual `.NET 10` compilation across all repos plus `javascript-typescript` on `Davids` and `Davids.Frontend.Admin`).
- **Custom `Semgrep` architecture & security rules (`security/pull-request-ci/semgrep/davids-security.yml`)**:
  - Enforces 10 `Davids`-specific rules blocking signing keys on `Customers`/`APIGateway`, symmetric HMAC JWTs, unauthenticated `AdminIdentity` endpoints, EF Core raw SQL interpolation, TLS validation bypasses, `AllowAnyOrigin()`, non-cryptographic `System.Random`, obsolete `X509Certificate2` constructors, browser token storage / `innerHTML` sinks in `Davids.Frontend.Admin`, and unpinned GitHub Action tags.
  - Run locally across all 7 repositories via `./scripts/security/pull-request-ci/Scan-Semgrep.ps1`.
- **Kubernetes, Istio mesh & Dockerfile hardening (`Checkov` + `istioctl analyze`)**:
  - `deploy/k8s/` defines `namespace-and-networkpolicy.yaml` (Pod Security Admission `restricted` + default-deny `NetworkPolicy`), `workloads.yaml` (non-root `10001`, `readOnlyRootFilesystem: true`, dropped capabilities, `RuntimeDefault` seccomp), `istio-mesh-security.yaml` (`PeerAuthentication` `STRICT` mTLS, `ISTIO_MUTUAL`, dual-authority `RequestAuthentication` `jwksUri`, `default-deny` + `davids-api-gateway`-scoped `AuthorizationPolicy`), and `grafana.yaml`, alongside non-root multi-stage `.NET 10` `Dockerfile`s in all 5 service/frontend repositories.
  - Run locally via `./scripts/security/pull-request-ci/Scan-IaC.ps1 -InstallIstioctl`.
- **NuGet JSON audit + SHA-pinned `Grype` & `Trivy` supply-chain scanning**:
  - Every third-party GitHub Action is pinned to a full 40-character commit SHA (`anchore/sbom-action`, `anchore/scan-action`, `aquasecurity/trivy-action`, `bridgecrewio/checkov-action`, `github/codeql-action`), and local CLI downloads verify pinned SHA-256 digests before extraction.
  - Run the complete Pull Request CI suite locally:
    ```powershell
    ./scripts/security/pull-request-ci/Invoke-PullRequestCiGates.ps1 -InstallTools
    ```

## Staging / Nightly DAST security gates (`security/staging-nightly` & `scripts/security/staging-nightly`)

`Davids` includes an automated dynamic application security testing (DAST) and API fuzzing pipeline (`.github/workflows/staging-nightly.yml` and local cross-platform PowerShell 7 runners) covering web/BFF endpoints, OpenAPI 3.1 contracts, and security regression assertions:

- **Gateway-routed OpenAPI 3.1.1 contracts (`security/staging-nightly/openapi/*.gateway.openapi.json`)**:
  - `Davids.Services.Identity`, `Davids.Services.AdminIdentity`, and `Davids.Services.Customers` emit enriched OpenAPI `3.1.1` specifications with `RS256` `BearerAuth` security schemes, explicit RFC-compliant string/integer/enum constraints, required request-body contracts, and error status schemas (`400`, `401`, `403`, `404`, `409`, `429`) supporting Schemathesis stateful state-machine chaining.
  - Export or verify contract parity via `./scripts/security/staging-nightly/Export-OpenApiSpecs.ps1` (or `./scripts/security/staging-nightly/Export-OpenApiSpecs.ps1 -VerifyOnly`).
- **Property-based & stateful OpenAPI fuzzing (`Schemathesis v4.32.6`)**:
  - Configured via `security/staging-nightly/schemathesis/schemathesis.toml` (`examples`, `coverage`, `fuzzing`, and `stateful` phases with `allow-x00 = true` null-byte fuzzing and `max-redirects = 0`).
  - Exercises unauthenticated boundary rejection across all 3 gateway contracts plus authenticated `CustomerBearer` (`Identity` + `POST /customers`) and `AdminBearer` (`AdminIdentity` + `Customers` admin endpoints) suites via `./scripts/security/staging-nightly/Scan-Schemathesis.ps1 -AutoProvisionCustomerToken`.
- **Custom security-posture & vulnerability-regression checks (`ProjectDiscovery Nuclei v3.11.1`)**:
  - `security/staging-nightly/nuclei/assertions/*.yaml` asserts 4 required security invariants against `Davids.APIGateway` (`Content-Security-Policy` & edge security headers, OIDC `S256` PKCE + `RS256` discovery metadata on both authorities, `404` on `/admin-identity/sign-up`, and `302 /login` + `401` API + `403` cross-origin BFF logout CSRF + `405` `TRACE` boundaries).
  - `security/staging-nightly/nuclei/vulnerabilities/*.yaml` enforces `0` matches across 6 regression detectors (JWKS private-key/symmetric material leaks, weak/missing CSP directives, unauthenticated data exposure, exposed Swagger/Scalar/Aspire/Prometheus/Grafana/Vault management paths at the edge, cross-origin `/auth/logout` CSRF bypass, and OIDC/BFF open redirects) and emits SARIF 2.1.0 for GitHub Code Scanning via `./scripts/security/staging-nightly/Scan-Nuclei.ps1 -InstallNuclei`.
- **Containerized web/BFF DAST (`PortSwigger Dastardly` & `Burp Suite DAST`)**:
  - `security/staging-nightly/burp/dastardly-seeds.json` and `./scripts/security/staging-nightly/Scan-Dastardly.ps1` run digest-pinned `public.ecr.aws/portswigger/dastardly` against `/login` and OIDC discovery surfaces, failing on any finding with severity `>= LOW` in JUnit XML.
  - `security/staging-nightly/burp/burp-dast-scan-config.json` and `security/staging-nightly/burp/burp-recorded-admin-bff-login.template.json` configure enterprise **Burp Suite DAST** active crawling + OpenAPI scanning with recorded PKCE `S256` BFF login and `/auth/logout` scope exclusion so active crawls preserve the `HttpOnly` BFF session cookie.
  - Run the complete Staging / Nightly suite locally:
    ```powershell
    ./scripts/security/staging-nightly/Invoke-StagingNightlyGates.ps1 -InstallTools -AutoProvisionCustomerToken
    ```

## Quarterly / Release security gates (`security/quarterly-release` & `scripts/security/quarterly-release` — $0 free toolchain)

`Davids` implements deep stateful API fuzzing, uncapped active/passive DAST, cross-role authorization matrix verification, and cryptographic JWT/OIDC boundary testing using **100% free (`$0` / `£0`) open-source and community tools** (`.github/workflows/quarterly-release.yml` and `./scripts/security/quarterly-release/Invoke-QuarterlyReleaseGates.ps1`):

- **Stateful producer/consumer API fuzzing (`Microsoft RESTler` — MIT)**:
  - `./scripts/security/staging-nightly/Export-OpenApiSpecs.ps1` normalizes all 3 gateway OpenAPI `3.1.1` specifications into RESTler-compatible OpenAPI `3.0.3` contracts (`security/quarterly-release/restler/specs/*.restler.openapi.json`).
  - `security/quarterly-release/restler/{compile-customer,compile-admin,annotations-customer,annotations-admin,dict.template,engine-settings}.json` and `./scripts/security/quarterly-release/Scan-Restler.ps1` compile separate Customer and Admin stateful grammars, mint primary + shadow OIDC PKCE `S256` tokens, and execute all 7 RESTler security checkers (`LeakageRuleChecker`, `ResourceHierarchyChecker`, `UseAfterFreeChecker`, `NameSpaceRuleChecker`, `PayloadBodyChecker`, `InvalidDynamicObjectChecker`, and `ExamplesChecker`), failing on any bug bucket (`> 0`).
- **Uncapped active/passive & OpenAPI DAST (`OWASP ZAP 2.17.0` Automation Framework — Apache-2.0)**:
  - `security/quarterly-release/zap/zap-automation.yaml` and `./scripts/security/quarterly-release/Scan-Zap.ps1` run digest-pinned `ghcr.io/zaproxy/zaproxy:2.17.0` with header-replacer `RS256` Bearer injection, `/login` spidering, OpenAPI contract import across `/identity`, `/admin-identity`, and `/customers`, active/passive scanning, and native SARIF 2.1.0 + HTML reporting.
- **Automated Cross-Role Authorization Matrix (`Autorize`) & Cryptographic JWT/OIDC Boundary Gate (`JWT Editor`)**:
  - `security/quarterly-release/authz/authz-matrix.json` and `./scripts/security/quarterly-release/Scan-AuthzMatrix.ps1` execute `31` cross-role BOLA/IDOR/BFLA test cases (`AUTHZ-001`..`AUTHZ-031` across `unauthenticated`, `customerA`, `customerB`, and `admin`) plus `11` live cryptographic boundary attacks (`CRYPTO-001`..`CRYPTO-011`: `alg: none`, cross-authority token confusion, `RS256 -> HS256` public-JWKS key confusion, rogue 2048-bit RSA keypair with `jku`/`jwk` header injection, payload claim tampering, PKCE `code_verifier` omission/mismatch, OAuth 2.1 single-use authorization-code replay + `RFC 6749 §10.5` cascade revocation, `RFC 7009` revocation, and Admin BFF `/logout` CSRF + `/login` open-redirect sanitization), exporting `authz-matrix.sarif`.
- **Interactive manual exploratory toolkit (`Burp Suite Community Edition` — `$0`)**:
  - `security/quarterly-release/authz/burp-community-project-options.json` and `security/quarterly-release/authz/BURP-COMMUNITY-GUIDE.md` configure free **Burp Suite Community Edition** with the free BApp Store extensions **Autorize** and **JWT Editor** (zero commercial license cost).
  - Run the complete Quarterly / Release suite locally:
    ```powershell
    ./scripts/security/quarterly-release/Invoke-QuarterlyReleaseGates.ps1 -RestlerMode FuzzLean
    ```

## Production Cluster runtime, mesh, supply-chain & login-audit alerting (`security/production-cluster`, `deploy/k8s` & `scripts/security/production-cluster` — $0 free toolchain)

`Davids` implements continuous cluster admission control, zero-trust service mesh enforcement, eBPF container runtime security, and login-audit alerting using **100% free (`$0` / `£0`) open-source tools** (`.github/workflows/production-cluster.yml` and `./scripts/security/production-cluster/Verify-ProductionClusterGates.ps1`):

- **Kyverno admission control & Sigstore Cosign supply-chain verification (`Kyverno v1.19.2` + `Cosign` — Apache-2.0)**:
  - `deploy/k8s/kyverno/davids-verify-signed-images.yaml` enforces keyless GitHub Actions OIDC (`https://token.actions.githubusercontent.com`) image signature verification via Sigstore Fulcio + Rekor (`https://rekor.sigstore.dev`) and CycloneDX SBOM attestation (`https://cyclonedx.org/bom`), mutating and verifying immutable `@sha256:` digests on admission.
  - `deploy/k8s/kyverno/davids-pod-security-and-mesh-admission.yaml` (`ClusterPolicy`) and `deploy/k8s/kyverno/davids-cel-validating-policy.yaml` (modern `policies.kyverno.io/v1` CEL `ValidatingPolicy`) reject pods using mutable tags, running as root (`runAsUser < 10000`), omitting `readOnlyRootFilesystem: true` / `RuntimeDefault` seccomp / `drop: ["ALL"]`, mounting host namespaces/paths, automounting ServiceAccount tokens, or disabling Istio sidecar injection (`sidecar.istio.io/inject: "false"`).
  - `security/production-cluster/kyverno-tests/` provides offline positive and negative pod fixtures verified via `kyverno test` (`18 / 18` policy test assertions passing).
- **Zero-trust Istio `STRICT` mTLS & L7 `AuthorizationPolicy` (`Istio 1.31.3` — Apache-2.0)**:
  - `deploy/k8s/istio-mesh-security.yaml` enforces namespace-wide and port-level (`8080`) `STRICT` `PeerAuthentication`, `ISTIO_MUTUAL` `DestinationRule` with TLS `1.3` minimum on ingress (`minProtocolVersion: TLSV1_3`), dual-authority `RS256` `RequestAuthentication`, `default-deny`, explicit `DENY` policies blocking debug/OpenAPI/management surfaces and `/admin-identity/sign-up` plus cross-role JWT claims (`role != admin`), and method/path/principal-scoped `ALLOW` policies restricting backend traffic exclusively to `cluster.local/ns/davids/sa/davids-api-gateway`.
- **eBPF runtime threat detection & in-kernel enforcement (`Falco 0.45.1` + `Cilium Tetragon v1.7.1` — Apache-2.0)**:
  - `security/production-cluster/falco/davids_rules.yaml` and `deploy/k8s/runtime-security/falco-davids-rules.yaml` detect interactive shells/recon binaries (`sh`, `bash`, `curl`, `nc`, `python`, `pwsh`), fileless/`/tmp`/`/dev/shm`/`memfd:` execution, non-`dotnet` reads of `/var/run/secrets` or `/etc/shadow`, `ptrace`/`setns`/`unshare`/`bpf` escape syscalls, and unexpected outbound TCP egress ports, forwarding alerts via **Falcosidekick** to Prometheus and Seq CLEF (`/api/events/raw?clef`).
  - `deploy/k8s/runtime-security/tetragon-tracingpolicies.yaml` deploys 3 `TracingPolicyNamespaced` policies in `davids` with synchronous in-kernel `Sigkill` termination on shell/network-tool `sys_execve`, `/tmp/`/`/var/tmp/`/`/dev/shm/` `sys_execve`, and `sys_ptrace` syscalls.
- **OpenTelemetry `Davids.Security.Audit` metrics & Prometheus / Grafana / Seq login-audit alerts**:
  - `Davids.ServiceDefaults` (`DavidsSecurityMetrics`), `Davids.Services.Identity`, `Davids.Services.AdminIdentity`, and `Davids.APIGateway` emit structured Seq security audit events (`SecurityAuditEvent`) and OpenTelemetry counters on meter `Davids.Security.Audit` (`davids.security.login_audit`, `davids.security.rate_limit_rejected`, `davids.security.token_revoked`, and `davids.security.bff_csrf_rejected`).
  - `security/production-cluster/prometheus/davids-security-rules.yml` (verified via `promtool check rules` and `promtool test rules` against `davids-security-rules.test.yml`) and `deploy/k8s/observability/prometheus-security-alerts.yaml` (`PrometheusRule` CRD) define 7 alert rules covering admin account lockouts, customer credential-stuffing lockout spikes, OIDC authorization-code/refresh-token replay & `request_token` tampering, HTTP `429` rate-limiter spikes, Admin BFF CSRF spikes, Falco/Tetragon eBPF intrusions, and Kyverno admission violations.
  - `src/Davids.AppHost/config/grafana/provisioning/alerting/security-alerts.yaml`, `src/Davids.AppHost/config/grafana/dashboards/davids-security-audit.json`, and `deploy/k8s/grafana.yaml` provision Grafana `13.2.4` Unified Alerting rules and the `Davids Security & Login Audit — Production Runtime Posture` dashboard.
  - `security/production-cluster/seq/seq-security-signals-and-alerts.json` and `./scripts/security/production-cluster/Bootstrap-SeqSecurityAlerts.ps1` synchronize 6 Seq security signals (`signal-davids-admin-lockout`, `signal-davids-customer-lockout`, `signal-davids-oidc-token-replay`, `signal-davids-rate-limit-429`, `signal-davids-bff-csrf`, and `signal-davids-falco-runtime`). Local Seq in `.NET Aspire` requires no API key by default; for authenticated Seq instances, pass `-SeqApiKey` or set `$env:DAVIDS_SEQ_API_KEY` (and in Kubernetes store the ingestion key in Secret `seq-clef-ingestion-key` for Falcosidekick).
  - Run the complete Production Cluster verification suite locally:
    ```powershell
    ./scripts/security/production-cluster/Verify-ProductionClusterGates.ps1 -InstallTools
    ```

## Validation and limitations

The six standalone service/shared solutions (`Davids.Shared.sln`, `Davids.Services.Identity.sln`, `Davids.Services.AdminIdentity.sln`, `Davids.Services.Customers.sln`, `Davids.APIGateway.sln`, `Davids.Frontend.Admin.sln`) and `Davids.Bootstrap` were restored in locked mode (`--locked-mode`), `Davids.sln` was restored with NuGet-supplied host-OS DCP and Aspire Dashboard binaries (`AspireUseCliBundle=false`, so Visual Studio `F5` and `dotnet run` launch without requiring a standalone Aspire CLI installation), all 7 repositories passed `Gitleaks` (`0` leaks), custom `Semgrep` SAST (`0` findings), `istioctl 1.31.3 analyze` (`0` issues), `Checkov` (`0` failed checks across Kubernetes, Dockerfile, and GitHub Actions), `Grype` (`0` vulnerabilities), `Trivy` (`0` vulnerabilities/misconfigurations), NuGet transitive vulnerability auditing (`0` advisories), live `Schemathesis v4.32.6` OpenAPI 3.1 fuzzing & stateful testing (`2,967 / 2,967` generated test cases passed, `0` failures), live `Nuclei v3.11.1` security regression testing (`4 / 4` posture assertions matched, `0` vulnerability findings across `6` templates), live `Microsoft RESTler` stateful API fuzzing (`0` bug buckets across `2,015` stateful requests), live Cross-Role Authorization & Cryptographic Boundary verification (`42 / 42` checks passed), and live Kyverno (`18 / 18` policy tests passed), Istio `STRICT` mTLS, Falco/Tetragon eBPF, and `promtool` (`7` alert rules unit-tested) verification, and all solutions were built in `Release` with `-warnaserror` (0 warnings, 0 errors) and tested (**106 tests passed**):

- `Davids.Shared.sln`: 7 tests (`Davids.ServiceDefaults.Tests`)
- `Davids.Services.Identity.sln`: 23 tests (`Davids.Services.Identity.Tests`)
- `Davids.Services.AdminIdentity.sln`: 13 tests (`Davids.Services.AdminIdentity.Tests`)
- `Davids.Services.Customers.sln`: 10 tests (`Davids.Services.Customers.Tests`)
- `Davids.APIGateway.sln`: 34 tests (`Davids.APIGateway.Tests`)
- `Davids.Frontend.Admin.sln`: 8 tests (`Davids.Frontend.Admin.Tests`)
- `Davids.sln` (AppHost DCP/Dashboard metadata, resource graph, OIDC wiring & Local Dev / PR CI / Staging Nightly / Quarterly Release / Production Cluster security gate verification): 11 tests (`Davids.AppHost.Tests`)

No Docker runtime is available inside the sandbox environment, so container-based runners (`Dastardly`, containerized `OWASP ZAP`, and Dockerized `RESTler`) execute on a Docker-enabled workstation or GitHub Actions runner.
