# Security workflow names and schedules

This document describes the proposed workspace changes. They take effect in GitHub only after the relevant repositories are updated and the workflows exist on their default branch. Configuration is not proof that a scan ran or passed.

## Workflow names and triggers

| Display name | Scope | Triggers |
|---|---|---|
| CI — Build, Tests & Security | Each repository | Pull requests targeting `main` and pushes to `main` |
| CodeQL — PR, Main & Weekly SAST | Each repository | Pull requests targeting `main`, pushes to `main` and weekly Monday schedule |
| Nightly / Manual — DAST & API Fuzzing | `Davids` | Daily 02:15 UTC and manual dispatch |
| Quarterly / Post-Release — Security Verification | `Davids` | 03:17 UTC on 1 January, April, July and October; release publication; manual dispatch |
| Production Cluster — Policy & Configuration Verification | `Davids` | Pull requests targeting `main`, pushes to `main` and manual dispatch |

Workflow filenames and job IDs remain unchanged. Displayed workflow names and two production job names have changed; check branch protection and rulesets before rollout.

### Weekly CodeQL schedule

All times are UTC on Monday. Staggering reduces simultaneous starts; scans may still overlap depending on runtime.

| Repository | UTC |
|---|---|
| Davids | 03:25 |
| Davids.Shared | 03:31 |
| Davids.Services.Identity | 03:36 |
| Davids.Services.AdminIdentity | 03:41 |
| Davids.Services.Customers | 03:46 |
| Davids.Services.Products | 03:51 |
| Davids.Services.Baskets | 03:56 |
| Davids.Services.Orders | 04:06 |
| Davids.Services.Payments | 04:11 |
| Davids.APIGateway | 04:16 |
| Davids.Frontend.Admin | 04:21 |
| Davids.Frontend.Web | 04:26 |

GitHub schedules are best-effort; they run from the default branch and may be delayed. For public repositories they can be disabled after inactivity. Monitor actual runs. UTC is one hour behind Scotland during British Summer Time.

## What the labels mean

- The nightly workflow scans a configured `STAGING_GATEWAY_URL`, if supplied, or an ephemeral runner stack. It does **not** run automatically on staging deployment. Active scans and test fixtures can write data; use an authorised non-production target. The Actions summary reports target type, fixture status and per-suite outcome, including skipped or unrun suites. It does not report a target URL, tokens or credentials.
- The quarterly workflow is triggered when a release is **published**; it cannot by itself block that publication. A genuine pre-release gate requires a separate release-process design. RESTler defaults to `FuzzLean` unless configured otherwise.
- Production-cluster CI verifies policies, configuration and fixtures offline; it does not inspect the live cluster. Runtime enforcement and alert delivery require correct deployment and operation. The signing job is conditional on the event and `ENABLE_COSIGN_SIGNING`; signing and attestation additionally require `RELEASE_IMAGE_DIGEST`.
- The automated authorization matrix is a PowerShell test, not the Burp Autorize extension. Burp tools remain optional for manual exploration.
- The Dastardly gate continues to fail for any JUnit failure or nonzero scanner exit. It does not filter by severity. Its output now reports the two counts separately; consult reports and logs to identify the cause. The gate's blocking condition is unchanged.
- CodeQL may be skipped on private repositories unless the workflow's `GHAS_ENABLED` condition is satisfied. A skipped job is not a completed scan.

## Rollout and branch protection

1. Compare these workspace files with the intended remote branch and preserve any newer changes. In particular, the two `Davids` staging and quarterly workflow files were reconciled against public `main` during this update; check again before applying them.
2. Check all repository rulesets, required status-check contexts and integrations before merging. The displayed workflow/job names can affect check contexts even though filenames and job IDs are unchanged. An administrator should plan a safe transition to the actual new check contexts, without leaving protection disabled or requiring checks that never appear. Test on a non-production branch/repository first.
3. Commit and push changes in each affected repository, following your review process. Confirm jobs execute and appear under the expected names; verify required checks before relying on them. No remote changes were made by preparing these files.
4. Manually dispatch the nightly and quarterly workflows only against an authorised non-production environment. Check the nightly summary, report artifacts and skipped steps. Review signing conditions and image digest before relying on an attestation.
5. Observe scheduled runs at the new times. Separate decisions remain for recurring dependency/image rescans, a pre-release gate and live-cluster monitoring; this change does not add them.

## Validation performed on the workspace update

- Actionlint checked all 27 workflow YAML files with shellcheck and pyflakes integrations disabled.
- Static comparisons confirmed job IDs, permissions, event types, action references, conditions and existing step configurations were preserved except for the explicitly changed schedules, labels and nightly target/summary instrumentation.
- PowerShell syntax parsing and offline configuration validation covered the Dastardly, authorization matrix and quarterly scripts.
- A simulated Docker executable exercised Dastardly success, informational JUnit failure, nonzero exit without findings, combined failure and missing-report scenarios. This was not a real Dastardly scan.
- No GitHub workflow, real DAST scan, production cluster check, pre-release gate or complete end-to-end run was executed as part of this update.
