# Davids Platform — Architecture and Security

This document describes the 12-repository development workspace. The vector overview in [`architecture-and-security.svg`](architecture-and-security.svg) is embedded in the [infrastructure README](../README.md); the editable Mermaid source is [`architecture-and-security.mmd`](architecture-and-security.mmd). Both cover the same components and relationships, although their layouts differ.

## Architecture overview

```mermaid
%% Davids platform: 12 repositories, seven separately owned SQL Server databases.
%% View in Mermaid Live Editor or export with @mermaid-js/mermaid-cli.
flowchart TB
    subgraph Clients["Gateway browser entry points"]
        Web["Davids.Frontend.Web<br/>Customer storefront / and /login<br/>:17322 direct development host"]
        Admin["Davids.Frontend.Admin<br/>Workforce portal /admin and /admin/login<br/>:17321 direct development host"]
    end
    GW["Davids.APIGateway :17320<br/>YARP / dual OIDC BFF / authorization"]
    Web -->|"Customer BFF"| GW
    Admin -->|"Workforce BFF"| GW

    subgraph Services["Seven service repositories"]
        ID["Davids.Services.Identity :5004<br/>Customer OIDC / identitydb"]
        AID["Davids.Services.AdminIdentity :17325<br/>Workforce OIDC / adminidentitydb"]
        CUST["Davids.Services.Customers :5002<br/>Profiles / customersdb"]
        PROD["Davids.Services.Products :5006<br/>Catalog and stock / productsdb"]
        BASK["Davids.Services.Baskets :5008<br/>Customer baskets / basketsdb"]
        ORD["Davids.Services.Orders :5010<br/>Checkout and orders / ordersdb"]
        PAY["Davids.Services.Payments :5012<br/>Simulated capture / paymentsdb"]
    end
    GW --> ID & AID & CUST & PROD & BASK & ORD & PAY
    BASK -. "catalog checks" .-> PROD
    ORD -. "basket and catalog checks" .-> BASK
    ORD -. "catalog checks" .-> PROD

    subgraph Infra["Davids repository — Aspire development infrastructure"]
        SQL[("SQL Server<br/>Seven separately owned databases")]
        MQ[["RabbitMQ<br/>Domain event transport"]]
        OPT["Optional integrations<br/>Redis, Vault, Jaeger, Seq,<br/>Prometheus and Grafana"]
    end
    ID & AID & CUST & PROD & BASK & ORD & PAY --> SQL
    ID -->|"signed_up / email_changed"| MQ
    MQ -->|"identity events"| CUST
    ORD -->|"order_placed / order_completed"| MQ
    MQ -->|"order_placed"| PAY
    PAY -->|"payment_captured / payment_failed"| MQ
    MQ -->|"payment outcomes"| ORD
    MQ -->|"order_completed"| CUST & PROD & BASK

    Shared["Davids.Shared<br/>ServiceDefaults: observability,<br/>security and resilience"]
    Shared -. "shared defaults" .-> GW
    Shared -. "shared defaults" .-> Services

    Deploy["Kubernetes / Istio manifests in Davids<br/>STRICT mTLS and authorization when deployed and enforced"]
    Infra -. "separate deployment configuration" .-> Deploy

    classDef frontend fill:#eff6ff,stroke:#2563eb,color:#172554
    classDef gateway fill:#ecfdf5,stroke:#059669,color:#064e3b
    classDef service fill:#fff,stroke:#64748b,color:#0f172a
    classDef data fill:#fffbeb,stroke:#d97706,color:#78350f
    classDef shared fill:#f5f3ff,stroke:#7c3aed,color:#4c1d95
    class Web,Admin frontend
    class GW gateway
    class ID,AID,CUST,PROD,BASK,ORD,PAY service
    class SQL,MQ,OPT data
    class Shared,Deploy shared
```

The two frontends are hosted behind the gateway at the same origin. Separate schemes, cookies and authorization policies distinguish customer and workforce sessions, but URL paths do not isolate them from same-origin XSS. Gateway API routes take precedence over the customer fallback. Direct frontend ports are development hosts; use the gateway for authenticated browser flows.

The seven SQL Server databases are separately owned and can share one SQL Server instance. Products seeds its catalog in the local Aspire configuration. Baskets and Orders consult Products; Orders also consults Baskets during checkout. RabbitMQ transports events: Orders publishes `order_placed`, Payments processes it and publishes a capture or failure result, and Orders can then publish `order_completed`. Payment capture is simulated; this is not a production payment-provider integration. Inbox/outbox processing supports retry and deduplication; publisher confirmation alone does not guarantee an event was routed to a consumer.

`Davids` contains the local Aspire AppHost, Vault bootstrap, deployment manifests and lifecycle security tooling. SQL Server and RabbitMQ are provisioned by the local AppHost; Redis, Vault and the observability integrations are configurable. The AppHost is development-only. The Kubernetes/Istio manifests are a separate deployment configuration; STRICT mTLS and mesh authorization apply only when deployed and enforced. The policies include workload-specific rules, not a blanket rule that only the gateway can communicate anywhere in the namespace.

## Customer and workforce sign-in

```mermaid
sequenceDiagram
    actor B as Browser
    participant G as API Gateway
    participant I as Customer Identity or AdminIdentity
    participant API as Backend API
    B->>G: GET /login or /admin/login
    G-->>B: Redirect to matching OIDC login
    B->>I: Authorize with code challenge, state and nonce
    I-->>B: Authorization code and state
    B->>G: Callback with code and state
    G->>I: Backchannel token exchange with PKCE verifier
    I-->>G: ID and access tokens; refresh token if issued
    G-->>B: HttpOnly protected BFF authentication ticket cookie
    B->>G: Request using BFF cookie
    G->>API: Authorized API request with bearer token
```

The gateway uses `SaveTokens`, so the protected ticket carried by the browser can contain tokens; those tokens are not exposed to JavaScript as plaintext by the `HttpOnly` cookie. The cookie is a credential, and XSS can still make authenticated requests. The gateway requires the realm-specific header on unsafe requests and checks `Origin` when it is present. Automatic cookie sliding expiration is disabled; a successful token refresh can nevertheless renew the ticket.

## Security lifecycle

- **Local Dev / Commit:** hooks, secret scanning, dependency auditing and compiler security analysis.
- **Pull Request CI:** CodeQL, Semgrep, infrastructure and supply-chain checks.
- **Staging / Nightly:** seven gateway OpenAPI contracts, realm-partitioned Schemathesis suites, Nuclei and Dastardly.
- **Quarterly / Release:** RESTler, ZAP, authorization matrix and JWT/OIDC boundary checks.
- **Production Cluster:** Kubernetes and Istio security policies, admission controls, runtime monitoring and audit alerting.

Configuration and checked-in manifests describe intended checks; consult workflow results and deployment status before claiming that a particular environment is protected or a particular run passed.

## Exporting diagrams

From the `Davids` directory, use the standalone Mermaid source with [Mermaid Live Editor](https://mermaid.live), or export it with Mermaid CLI:

```powershell
npx -y @mermaid-js/mermaid-cli -i ./docs/architecture-and-security.mmd -o ./docs/architecture-and-security-mermaid.svg -b white
npx -y @mermaid-js/mermaid-cli -i ./docs/architecture-and-security.mmd -o ./docs/architecture-and-security-mermaid.png -w 2600 -s 2 -b white
```

These commands create separate Mermaid-rendered files; they do not overwrite the curated SVG embedded in the README. The curated SVG is independently editable as vector artwork.
