# Infrastructure audit and architecture notes

## Purpose and scope

This document describes the **configured** Davids .NET 10 platform and identifies important verification boundaries. It is not evidence that every service, security control or test is currently running or passing. See the [infrastructure README](../README.md) for setup, endpoints, credentials and security commands, and the [architecture diagram](ARCHITECTURE-AND-SECURITY-DIAGRAM.md) for the full topology.

The workspace contains 12 repositories: `Davids` and the 11 sibling repositories below. Each component retains its own repository and standalone solution; `Davids.slnx` is the aggregate solution.

| Repository | Responsibility | Database where applicable |
|---|---|---|
| `Davids` | Aspire AppHost, infrastructure, deployment manifests and security tooling | — |
| `Davids.Shared` | Shared `Davids.ServiceDefaults` | — |
| `Davids.Services.Identity` | Customer accounts and customer OIDC authority | `identitydb` |
| `Davids.Services.AdminIdentity` | Workforce accounts and workforce OIDC authority | `adminidentitydb` |
| `Davids.Services.Customers` | Customer profiles | `customersdb` |
| `Davids.Services.Products` | Product catalog and stock | `productsdb` |
| `Davids.Services.Baskets` | Customer baskets | `basketsdb` |
| `Davids.Services.Orders` | Orders and checkout | `ordersdb` |
| `Davids.Services.Payments` | Simulated payment capture | `paymentsdb` |
| `Davids.APIGateway` | YARP edge, customer and workforce OIDC BFFs | — |
| `Davids.Frontend.Admin` | Workforce portal | — |
| `Davids.Frontend.Web` | Customer storefront | — |

The seven SQL Server databases have separate owners and EF Core contexts; they are typically hosted on the same SQL Server instance, not necessarily on separate servers. Customer and workforce accounts remain in distinct databases and authorities. Products, Baskets, Orders and Payments retain their own data ownership.

## Architecture and security boundaries

| Concern | Configuration and limitations |
|---|---|
| Routing | The YARP gateway routes directly to services. The customer storefront is served at `/` with login at `/login`; the workforce portal is at `/admin` with login at `/admin/login`. |
| Identity and access | Customer Identity and AdminIdentity are separate self-hosted OpenIddict authorities. The gateway uses separate OIDC BFF schemes and cookies; workforce roles include `admin`, `support` and `auditor`, while customers use `user`. Resource APIs apply their own authorization policies. |
| Keys and secrets | Identity providers own their respective signing and encryption keys. Gateway and resource servers validate tokens using public keys rather than receiving identity signing keys. Development Vault/bootstrap configuration is optional and environment-dependent; see the README for credential locations and access. |
| Messaging | RabbitMQ supports asynchronous communication, including payment capture before order completion. Services use outbox/inbox patterns where implemented. Publisher confirmations alone do not guarantee a publication was routed; review unrouted-message handling for stronger delivery assurances. |
| Payments | Payment capture is simulated. There is no real payment-provider integration in the current implementation. |
| Observability | Aspire can provision Redis, Vault, Jaeger, Seq, Prometheus and Grafana according to configuration. Grafana can use configured cluster Prometheus and Jaeger URLs. InfluxDB and Elasticsearch are optional integrations. |
| Kubernetes and Istio | Deployment manifests define mesh, authorization, network, admission and runtime security controls. These controls are effective only when deployed and correctly enforced in the target cluster; local Aspire does not automatically establish the production mesh. |
| Revocation | Redis-based revocation is configuration-dependent. The gateway can use a no-op store and can defer downstream if Redis fails; do not assume immediate or fail-closed revocation in every deployment. |

The gateway stores OIDC tokens in its protected authentication ticket when `SaveTokens` is enabled. An `HttpOnly` cookie prevents direct JavaScript access to the cookie, but it does not stop same-origin script from making authenticated requests. Cookie renewal on token refresh also means the configured ticket lifetime is not necessarily an absolute session cap.

## Configuration and deployment checks

- **Database migrations:** `scripts/Update-Database.ps1` handles seven service contexts sequentially. It may update earlier databases before a later context fails; review migrations, back up data and plan recovery before running it. The checked-in SQL baseline files cover Identity, AdminIdentity and Customers; the other four baseline SQL files are not currently checked in.
- **Local development:** AppHost resource and integration choices depend on configuration. See `src/Davids.AppHost/appsettings.json` and the README; do not infer the live deployment from defaults.
- **Local commit security:** Repository hooks require explicit installation/configuration. See [`security/local-dev-commit/README.md`](../security/local-dev-commit/README.md).
- **CI and scanning:** Repository CI and CodeQL, nightly dynamic checks, quarterly/post-publication checks and offline production-policy verification have different triggers and scopes. See [`SECURITY-SCAN-WORKFLOW-UPDATE.md`](SECURITY-SCAN-WORKFLOW-UPDATE.md). The nightly target may be configured externally or ephemeral, and some authenticated suites can be skipped.
- **Production verification:** `Verify-ProductionClusterGates.ps1` tests policy fixtures and checks configuration offline. It does not inspect actual Kubernetes state, prove runtime enforcement or verify alert delivery.

## Validation and evidence

The repositories include unit, integration, architecture and security configuration tests. Exact test counts and results change over time; consult the relevant GitHub Actions run or execute the documented scripts for the commit being assessed. A configured test is not a successful run, and a successful offline configuration test is not evidence of a healthy deployed system.

A full assessment requires, as appropriate, running the services and databases, exercising both OIDC sign-in flows and end-to-end order/payment messaging, testing backup/restore, running scans against an authorised non-production target, and verifying the deployed Kubernetes/Istio controls. Do not include credentials, cookies, tokens or personal data in shared evidence.
