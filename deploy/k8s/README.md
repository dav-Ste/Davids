# Kubernetes, Istio Mesh & Cluster Security Manifests (`deploy/k8s`)

These manifests are **not** used when running `.NET Aspire` locally (`F5` in Visual Studio or `dotnet run --project src/Davids.AppHost`). They define the **Production Cluster** Kubernetes, Istio service mesh, Kyverno admission, Falco/Tetragon eBPF runtime, Prometheus, and Grafana resources, and are validated offline during **Pull Request CI** and **Production Cluster** CI checks.

## Offline Validation (Local & GitHub Actions)

- **Pull Request CI** (`.github/workflows/pull-request-ci.yml` / `./scripts/security/pull-request-ci/Scan-IaC.ps1 -InstallIstioctl`):
  - Validates `deploy/k8s/*.yaml` with `istioctl analyze --use-kube=false` and scans all manifests with `Checkov`.
- **Production Cluster Gate** (`.github/workflows/production-cluster.yml` / `./scripts/security/production-cluster/Verify-ProductionClusterGates.ps1 -InstallTools`):
  - Executes `kyverno test` against `deploy/k8s/kyverno/*.yaml` using fixtures in `security/production-cluster/kyverno-tests/`.
  - Validates Istio `STRICT` mTLS, Falco rules, Cilium Tetragon `TracingPolicyNamespaced` manifests, Prometheus alert rules (`promtool`), and Grafana Unified Alerting.

## Applying to a Kubernetes + Istio Cluster

Run from `Davids` against your target `kubectl` cluster context:

```powershell
# 1. Namespace (Pod Security Admission 'restricted') & default-deny NetworkPolicies
kubectl apply -f ./deploy/k8s/namespace-and-networkpolicy.yaml

# 2. Required Kubernetes Secrets (created out-of-band, never committed to Git)
kubectl -n davids create secret generic grafana-admin-credentials `
  --from-literal=admin-user=admin `
  --from-literal=admin-password='<strong-random-password>'

kubectl -n istio-system create secret tls davids-edge-tls `
  --cert=./path/to/tls.crt `
  --key=./path/to/tls.key

# 3. Kyverno supply-chain & pod-hardening admission policies (requires Kyverno installed)
kubectl apply -f ./deploy/k8s/kyverno/

# 4. Istio STRICT mTLS, RequestAuthentication & AuthorizationPolicies (requires Istio installed)
kubectl apply -f ./deploy/k8s/istio-mesh-security.yaml

# 5. Davids workloads & Grafana
kubectl apply -f ./deploy/k8s/workloads.yaml
kubectl apply -f ./deploy/k8s/grafana.yaml

# 6. Prometheus alerts & Falco / Cilium Tetragon eBPF runtime enforcement
kubectl apply -f ./deploy/k8s/observability/prometheus-security-alerts.yaml
kubectl apply -f ./deploy/k8s/runtime-security/falco-davids-rules.yaml
kubectl apply -f ./deploy/k8s/runtime-security/tetragon-tracingpolicies.yaml
```
