# Changelog

## 0.1.0

- `setup`, `audit`, `patch` commands for ECS Fargate (X86_64, ECR).
- Dry run by default; `--deploy` registers a revision, updates the service, waits for stable, prints the rollback command.
- Idempotent: already-protected task definitions are skipped.
- `--skip-container`, `--falconctl-opts`, `--ca-bundle`, `--sensor-repo`.
- `audit --fail-on-unprotected` exits 3 for CI gating.
