# Staging / Nightly DAST & OpenAPI Fuzzing Gate

Runs on **staging deployments and nightly at 02:15 UTC** via `.github/workflows/staging-nightly.yml`:

- `openapi/` — Gateway-mapped OpenAPI `3.1.1` specifications (`identity`, `admin-identity`, `customers`).
- `schemathesis/schemathesis.toml` — Schemathesis `v4.32.6` property-based & stateful OpenAPI fuzzing config.
- `nuclei/` — ProjectDiscovery Nuclei `v3.11.1` positive posture assertions (`assertions/`) and negative vulnerability regression templates (`vulnerabilities/`).
- `burp/` — PortSwigger Dastardly & Burp Suite DAST configurations + recorded PKCE `S256` Admin BFF login template.

Run locally from `Davids`:
```powershell
./scripts/security/staging-nightly/Invoke-StagingNightlyGates.ps1 -InstallTools -AutoProvisionCustomerToken
```
