# Quarterly / Release Deep Fuzzing, Active DAST & Authorization Gate

Runs on **every GitHub release, quarterly schedule, and manual dispatch** via `.github/workflows/quarterly-release.yml` (`100% free / $0` toolchain):

- `restler/` — Microsoft RESTler stateful producer/consumer API fuzzing compiler configs, annotations, dictionary, engine settings, and normalized OpenAPI `3.0.3` contracts (`specs/`).
- `zap/zap-automation.yaml` — OWASP ZAP `2.17.0` Automation Framework active/passive + OpenAPI DAST plan.
- `authz/` — `31` cross-role `Autorize` BOLA/BFLA/IDOR cases (`authz-matrix.json`), `11` cryptographic `JWT Editor`/OIDC/PKCE/BFF checks, and free **Burp Suite Community Edition** setup (`BURP-COMMUNITY-GUIDE.md`).

Run locally from `Davids`:
```powershell
./scripts/security/quarterly-release/Invoke-QuarterlyReleaseGates.ps1 -RestlerMode FuzzLean
```
