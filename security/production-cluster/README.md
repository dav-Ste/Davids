# Production Cluster Runtime, Mesh, Supply-Chain & Login-Audit Alerting

Enforced **continuously (24/7) in the Kubernetes + Istio production cluster** (`deploy/k8s/**`) and verified offline on every PR/push via `.github/workflows/production-cluster.yml` (`100% free / $0` toolchain):

- `kyverno-tests/` — Offline positive & negative Pod admission fixtures verified with `kyverno test` against `deploy/k8s/kyverno/*.yaml`.
- `falco/davids_rules.yaml` — CNCF Falco `0.45.x` eBPF container runtime threat detection rules (paired with Cilium Tetragon `Sigkill` policies in `deploy/k8s/runtime-security/`).
- `prometheus/` — Prometheus security alert rules (`davids-security-rules.yml`) and `promtool` unit tests (`davids-security-rules.test.yml`).
- `seq/seq-security-signals-and-alerts.json` — Seq login-audit & runtime intrusion signals synchronized via `Bootstrap-SeqSecurityAlerts.ps1`.

Run offline verification locally from `Davids`:
```powershell
./scripts/security/production-cluster/Verify-ProductionClusterGates.ps1 -InstallTools
```
