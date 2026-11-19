# falcon-ecs-patch design

## Purpose

Make ECS Fargate task definition patching with the Falcon Container sensor repeatable. The official patching utility (inside the `falcon-container` image) is the mechanism. This repo adds the operational layer: find unprotected services, patch non-interactively, show a diff, deploy safely, and run the same steps in CI.

Audiences:
- **POV (beginner):** follows the companion lab in falcon-cloud-security-labs. Downloads one pinned release file.
- **Operationalizing (after POV):** clones or vendors the repo at a pinned tag and runs it in their pipeline.

## Delivery

- One self-contained bash script, `falcon-ecs-patch.sh`. Requires `aws`, `jq`, `docker`, `curl`.
- GitHub Release per tag `vX.Y.Z` attaches the script and `falcon-ecs-patch.sh.sha256`.
- Docs say: pin a tag, verify the SHA256, never run `main`. No `curl | bash` of this script.
- Repo layout: `falcon-ecs-patch.sh`, `README.md`, `CHANGELOG.md`, `examples/` (CI snippets), `tests/` (fixtures + shell tests), `.github/workflows/` (shellcheck, tests, release).

## Interface

```
falcon-ecs-patch.sh setup  --region R [--sensor-type falcon-container]
falcon-ecs-patch.sh audit  --cluster C --region R [--fail-on-unprotected]
falcon-ecs-patch.sh patch  --cluster C --service S --region R [--deploy]
falcon-ecs-patch.sh patch  --family F --region R [--deploy]         # no service update
falcon-ecs-patch.sh patch  --cluster C --all --region R [--deploy]
```

Shared options: `--cid`, `--sensor-image URI`, `--out DIR`, `--skip-container NAME` (repeatable), `--falconctl-opts "--tags=a,b"`, `--yes`.

Env fallbacks: `FALCON_CID`, `FALCON_CLIENT_ID`, `FALCON_CLIENT_SECRET`, `AWS_REGION`, `IMAGE_PULL_TOKEN`. The client secret is env-only, never a flag (flags leak into `ps` and CI logs).

Exit codes: 0 ok, 1 error, 2 usage, 3 `audit --fail-on-unprotected` found unprotected services.

## Behavior

- **setup:** runs the official `falcon-container-sensor-pull.sh --copy` into ECR (repo name must equal image name), logs Docker in to ECR first, reads the tag back from ECR, prints the `--sensor-image` URI. Run once per account and region.
- **audit:** read-only. For each service, resolve its task definition and report PROTECTED (has `crowdstrike-falcon-init-container`) or UNPROTECTED, plus launch type and CPU architecture. EC2-launch services are reported as out of scope.
- **patch (default is dry run):**
  1. Export the task definition, stripping managed fields. Keep tags via `--include TAGS`.
  2. Preflight: skip if already protected; fail if a container is named `crowdstrike-falcon-init-container`; fail if not Fargate-compatible; warn on ARM64 and on missing public IP / NAT; check the execution role can pull from ECR.
  3. Build the ECR pull token internally (self-contained, avoids the Docker Desktop `credsStore` problem).
  4. Run the official utility: `docker run ... -cid -image -pulltoken -ecs-spec-file`.
  5. Print a diff of original vs patched and a one-line summary per container.
  6. Write `<out>/<family>/rev<N>.original.json` and `rev<N>.patched.json`.
- **`--deploy`:** register the patched revision, then `update-service` to it (only when `--service` or `--all`) and wait for stable. Print the previous revision ARN as the rollback target.
- **Idempotent:** re-running on a protected task definition is a no-op. Upgrading the sensor is out of scope for v0.1; re-patch from the source task definition.

## Companion lab (falcon-cloud-security-labs, `ecs/fargate-task-patching/lab.md`)

- Modernize the existing legacy lab; the manifest entry already exists, flip `modernized` when done.
- Quick Deploy: download pinned release, verify checksum, `setup`, `audit`, `patch` (dry run), `patch --deploy`, verify.
- Full Lab: run export, patch, and diff by hand once with raw `docker run -ecs-spec-file` so the mechanism is clear, then switch to the script. Console-first for task definition JSON, new revision, update service, verify.
- `data-fill-fields` collects cluster, service, region, CID once and renders the exact commands.
- Challenges lead with adoption: CI step before `register-task-definition`, scheduled `audit --fail-on-unprotected`, rollback by revision.
- Lab never depends on the script alone: the raw steps work if the repo disappears.

## Validation plan (live, a test cluster in us-east-1)

Service the test service runs unmodified nginx on Fargate, no entrypoint or command set, ECS Exec off, revision 1 is the rollback target.

1. `audit` shows the test service UNPROTECTED.
2. `patch` dry run prints a diff and changes nothing.
3. `patch --deploy` registers revision 2 and rolls the service. Init container exits 0, host appears in Falcon by Pod ID.
4. Second `patch` is a no-op. `audit` shows PROTECTED.
5. Roll back to revision 1, deregister test revisions.

## Out of scope for v0.1

Sensor upgrade in place, EC2 launch type, CloudFormation input, a GitHub Action wrapper, non-ECR private registries (use `repositoryCredentials` plus the official doc, or `IMAGE_PULL_TOKEN`).
