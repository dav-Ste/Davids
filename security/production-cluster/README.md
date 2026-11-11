# Production Cluster Runtime, Mesh, Supply-Chain & Login-Audit Alerting

The files below define production-cluster controls. Their enforcement and alert delivery depend on deployment and operation; they are not verified against a live cluster by this workflow. The offline checks run on PRs targeting `main`, pushes to `main` and manual dispatch via `.github/workflows/production-cluster.yml`. Image signing is separately conditional on workflow variables and a supplied image digest:

- `kyverno-tests/` — Offline positive & negative Pod admission fixtures verified with `kyverno test` against `deploy/k8s/kyverno/*.yaml`.
- `falco/davids_rules.yaml` — CNCF Falco `0.45.x` eBPF container runtime threat detection rules (paired with Cilium Tetragon `Sigkill` policies in `deploy/k8s/runtime-security/`).
- `prometheus/` — Prometheus security alert rules (`davids-security-rules.yml`) and `promtool` unit tests (`davids-security-rules.test.yml`).
- `seq/seq-security-signals-and-alerts.json` — Seq login-audit & runtime intrusion signals synchronized via `Bootstrap-SeqSecurityAlerts.ps1`.

Run offline verification locally from `Davids`:
```powershell
./scripts/security/production-cluster/Verify-ProductionClusterGates.ps1 -InstallTools
```
