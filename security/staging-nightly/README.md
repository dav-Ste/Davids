# Staging / Nightly DAST & OpenAPI Fuzzing Gate

Runs nightly at **02:15 UTC** and on manual dispatch via `.github/workflows/staging-nightly.yml`; it is not triggered automatically by staging deployment. Uses the configured `STAGING_GATEWAY_URL` or an ephemeral stack; active scans and fixture setup can write data, so use only an authorised non-production target. The workflow summary reports target type, fixture status and scan outcomes, including skipped suites:

- `openapi/` — Gateway-mapped OpenAPI `3.1.1` specifications (`identity`, `admin-identity`, `customers`, `products`, `baskets`, `orders`, `payments`).
- `schemathesis/schemathesis.toml` — Schemathesis `v4.32.6` property-based & stateful OpenAPI fuzzing config.
- `nuclei/` — ProjectDiscovery Nuclei `v3.11.1` positive posture assertions (`assertions/`) and negative vulnerability regression templates (`vulnerabilities/`).
- `burp/` — PortSwigger Dastardly & Burp Suite DAST configurations + recorded PKCE `S256` Admin BFF login template.

Run locally from `Davids`:
```powershell
./scripts/security/staging-nightly/Invoke-StagingNightlyGates.ps1 -InstallTools -AutoProvisionCustomerToken
```
