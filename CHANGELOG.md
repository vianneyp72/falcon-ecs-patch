# Changelog

## 0.2.4

- `audit` prints a green check when every Fargate service is protected.
- `patch --all` checks the services first, so the nothing-to-patch case returns in seconds with no Docker, ECR, or sensor work.
- `patch --all` skips unprotected ARM64 services with a message instead of stopping the whole run.
- The execution role check now catches a role that is denied only some of the ECR pull actions.
- The ARM64 error no longer says "v0.1".

## 0.2.3

- `patch --all` prints a green check and "Nothing to patch" when every Fargate service is already protected, and says so when the cluster has no services.
- `patch --all --deploy` now asks `[y/N]` for each service when run from a terminal (it previously stopped with "needs a terminal"). Use `--yes` in CI.

## 0.2.2

- Fix `--help` crashing when `SSL_CERT_FILE` is unset.

## 0.2.1

- Fix ShellCheck findings (trap quoting, service ARN splitting). No behavior change.

## 0.2.0

- `patch --file task-definition.json [--output patched.json]` patches a task definition kept in Git. It never registers anything, so it fits any pipeline (GitHub Actions, Terraform, CDK).
- `patch --service S --from-revision N` patches an unpatched revision with the newest sensor image. This is the sensor upgrade path.
- `patch --family F[:REV]` accepts a specific revision. `--deploy` now prints the new task definition ARN on stdout.
- `audit` shows the sensor tag each service runs.
- `patch` prints the service rollout settings and task size, warns when the circuit breaker is off, and does not update services that use the CODE_DEPLOY or EXTERNAL deployment controller.

## 0.1.0

- `setup`, `audit`, `patch` commands for ECS Fargate (X86_64, ECR).
- Dry run by default; `--deploy` registers a revision, updates the service, waits for stable, prints the rollback command.
- Idempotent: already-protected task definitions are skipped.
- `--skip-container`, `--falconctl-opts`, `--ca-bundle`, `--sensor-repo`.
- `audit --fail-on-unprotected` exits 3 for CI gating.
