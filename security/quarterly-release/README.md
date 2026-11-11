# Quarterly / Release Deep Fuzzing, Active DAST & Authorization Gate

Runs at **03:17 UTC on 1 January, April, July and October**, on GitHub release publication, and on manual dispatch via `.github/workflows/quarterly-release.yml`. Publication triggers post-release verification; this is not a pre-release gate. The target must be authorised for active testing; use an isolated non-production environment. RESTler defaults to `FuzzLean` unless configured otherwise:

- `restler/` — Microsoft RESTler stateful producer/consumer API fuzzing compiler configs, annotations, dictionary, engine settings, and normalized OpenAPI `3.0.3` contracts (`specs/`).
- `zap/zap-automation.yaml` — OWASP ZAP `2.17.0` Automation Framework active/passive + OpenAPI DAST plan.
- `authz/` — 45 automated cross-role BOLA/BFLA/IDOR cases (`authz-matrix.json`), 11 automated cryptographic JWT/OIDC/PKCE/BFF checks, and optional manual **Burp Suite Community Edition** setup (`BURP-COMMUNITY-GUIDE.md`).

Run locally from `Davids`:
```powershell
./scripts/security/quarterly-release/Invoke-QuarterlyReleaseGates.ps1 -RestlerMode FuzzLean
```
