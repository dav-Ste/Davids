# Stage 4 Manual Exploratory Guide — Burp Suite Community Edition ($0 Free Setup)

This guide covers the **optional interactive human-in-the-loop exploratory session** for Stage 4 using **100% free tools ($0 license cost)**:

- **Burp Suite Community Edition** (`$0`, free download from PortSwigger)
- **Autorize** (`v1.9.4`, `$0`, free BApp Store extension — MIT/GPL open-source)
- **JWT Editor** (`v2.6.2`, `$0`, free BApp Store extension — Apache-2.0 open-source)

> **Note:** Every cross-role IDOR, privilege-escalation, JWT cryptographic tampering (`alg: none`, `RS256 -> HS256` JWKS key confusion, untrusted RSA key + `jku`, payload claim mutation, token revocation), PKCE `S256` downgrade, authorization-code replay, and BFF CSRF check in this guide is **already automated** with zero manual effort by `pwsh ./scripts/Scan-AuthzMatrix.ps1`. Use Burp Suite Community Edition only when performing hands-on exploratory testing of new UI workflows in `Davids.Frontend.Admin`.

---

## 1. Install Free Extensions in Burp Suite Community Edition

- Open **Burp Suite Community Edition** and select **Temporary project in memory** -> **Load from configuration file** -> choose `security/stage4-authz/burp-community-project-options.json`.
- Navigate to **Extensions** -> **BApp Store** and install two free extensions:
  - **Autorize** (installs Jython standalone JAR automatically via the BApp Store prompt if not yet present)
  - **JWT Editor**

---

## 2. Configure `Autorize` for Cross-Domain Admin vs. Customer Isolation

- Start the `Davids` stack (`dotnet run --project src/Davids.AppHost`) so the YARP API Gateway listens on `http://localhost:17320`.
- Obtain a low-privilege **Customer** `RS256` access token (from `Davids.Services.Identity`, `identitydb`) using the PKCE helper in `Scan-AuthzMatrix.ps1` or by signing in as a test customer.
- Open the **Autorize** tab in Burp Suite Community Edition:
  - In **Configuration -> Temporary headers**, replace `Cookie: ...` with:
    `Authorization: Bearer <CUSTOMER_RS256_ACCESS_TOKEN>`
  - Under **Interception Filters**, add Scope filter: **Allow only in-scope items** (`http://localhost:17320/*`).
  - Set **Enforcement Detector** to mark HTTP `401` and `403` as **Enforced** (green) and HTTP `2xx` on `/admin-identity/*`, `/api/admin/*`, `GET /customers`, or `PUT /customers/*` as **Bypassed!** (red).
  - Toggle **Autorize is ON**.
- Open Burp's built-in Chromium browser (`Proxy -> Intercept -> Open browser`), browse to `http://localhost:17320`, complete the **Admin BFF** PKCE login (`Davids.Services.AdminIdentity`, `adminidentitydb`), search customers, inspect a customer profile, and toggle a customer's state.
- Verify in **Autorize** that every Admin BFF (`__Host-Davids.Admin.Bff` / `.Davids.Admin.Bff.Dev`) and `/admin-identity/*` / `/customers` management request replayed with the **Customer Bearer token** AND **Unauthenticated** column shows **Enforced (`401` / `403`)** with zero `2xx` bypasses.

---

## 3. Exploratory Token Tampering with `JWT Editor`

- Capture any authenticated `Authorization: Bearer <jwt>` request in **Proxy -> HTTP history** and send it to **Repeater** (`Ctrl+R`).
- Open the **JWT Editor Keys** tab:
  - Click **New RSA Key** -> **Generate** (`2048` bits) to create an untrusted attacker RSA key.
  - Click **New Symmetric Key** and paste the base64-encoded public JWK from `http://localhost:17320/identity/.well-known/jwks` to test `RS256 -> HS256` key confusion.
- Switch to the **JSON Web Token** sub-tab inside **Repeater** and verify all four attacks return `401 Unauthorized`:
  - Click **Attack -> "none" Signing Algorithm** and send the request.
  - Edit payload claims (`"role": "admin"`, `"iss": "http://localhost:17325/"`, `"aud": "davids-admin"`) and sign with the generated attacker RSA key.
  - Click **Attack -> HMAC Key Confusion** with the public JWK symmetric key.
  - Click **Attack -> Embedded JWK** (embeds the attacker's public JWK inside the JWT header `jwk` claim).
