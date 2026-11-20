# falcon-ecs-patch

Repeatable patching of Amazon ECS Fargate task definitions with the CrowdStrike Falcon Container sensor.

This is a thin, non-interactive wrapper around the official patching utility that ships inside the `falcon-container` image. Run it by hand for a proof of value, then drop it into CI/CD so every new task definition revision is protected.

It adds what the raw utility leaves to you: find unprotected services, export and clean the task definition, build the registry pull token, show a diff, register the new revision, roll the service, and print the rollback command.

Scope: ECS on **Fargate**, **X86_64** tasks, images in **ECR**.

> **Support status:** This is a community-maintained helper, not an official CrowdStrike product, and it is not covered by CrowdStrike support. It automates the officially documented patching utility and never replaces it: if you cannot use the script, run the utility directly (see the [official documentation](#references) and the companion lab's by-hand section). Read the script before you run it; it is one bash file.

## Requirements

- `aws` (v2), `jq`, `docker`, `curl`, `bash`
- AWS credentials that can call ECS and ECR (see [Permissions](#permissions))
- Your Falcon CID (with checksum). `setup` also needs a Falcon API client with **Falcon Images Download: Read** and **Sensor Download: Read**.

## Install

Pin a release and verify its checksum. Do not run `main`.

```bash
VERSION=v0.2.4
BASE=https://github.com/vianneyp72/falcon-ecs-patch/releases/download/$VERSION
curl -fsSLO $BASE/falcon-ecs-patch.sh
curl -fsSLO $BASE/falcon-ecs-patch.sh.sha256
(sha256sum -c falcon-ecs-patch.sh.sha256 2>/dev/null || shasum -a 256 -c falcon-ecs-patch.sh.sha256)
chmod +x falcon-ecs-patch.sh
```

To operationalize, vendor the script at a pinned tag into your own repo (or `git clone --branch $VERSION`) and upgrade deliberately.

## Quick start

```bash
export AWS_REGION=us-east-1
export FALCON_CID=<your-cid-with-checksum>
export FALCON_CLIENT_ID=<api-client-id>
read -rs -p "Falcon API client secret: " FALCON_CLIENT_SECRET && export FALCON_CLIENT_SECRET

# 1. Once per account and region: copy the sensor image into your ECR
./falcon-ecs-patch.sh setup

# 2. See what is unprotected
./falcon-ecs-patch.sh audit --cluster my-cluster

# 3. Dry run: shows the diff, changes nothing in ECS
./falcon-ecs-patch.sh patch --cluster my-cluster --service my-service

# 4. Apply: registers a new revision, updates the service, waits for stable
./falcon-ecs-patch.sh patch --cluster my-cluster --service my-service --deploy
```

`setup` prints the `--sensor-image` URI. If you skip the flag, `patch` uses the newest tag in the `falcon-container` ECR repo.

Before you deploy to a real service, read [Before you deploy](#before-you-deploy).

## Commands

| Command | What it does |
|---------|--------------|
| `setup` | Copies the Falcon Container sensor image into ECR with the official pull script. Run once per account and region. |
| `audit` | Read-only. Marks each service in a cluster PROTECTED or UNPROTECTED, with launch type, CPU architecture, and the sensor tag it runs. |
| `patch` | Exports the task definition, patches it with the official utility, prints a diff, writes `<out>/<family>/rev<N>.original.json` and `.patched.json`. Dry run unless `--deploy`. |

### patch targets

| Flag | Behavior |
|------|----------|
| `--service S` | Patch the task definition the service runs, then (with `--deploy`) update the service. |
| `--service S --from-revision N` | Patch revision `N` of the service's family instead of the one it runs. Use it to move to a newer sensor. See [Upgrading the sensor](#upgrading-the-sensor). |
| `--all` | Patch every unprotected Fargate service in the cluster. |
| `--family F[:REV]` | Patch the latest (or a specific) revision of a family. With `--deploy` it registers a revision and prints its ARN on stdout; it updates no service. |
| `--file FILE` | Patch a task definition JSON file, for example one kept in Git. Registers nothing; writes the patched JSON to `--output`. Use this when your pipeline owns the registration. |

### Options

| Option | Notes |
|--------|-------|
| `--region R` | Or `AWS_REGION`. |
| `--cid CID` | Or `FALCON_CID`. |
| `--sensor-image URI` | Sensor image in your ECR. Default: newest tag in the sensor repo. |
| `--sensor-repo NAME` | ECR repo for the sensor (default `falcon-container`). Last path segment must be `falcon-container`. |
| `--skip-container N` | Do not inject into container `N`. Repeatable. |
| `--falconctl-opts S` | Sensor options baked into the task, e.g. `--tags=prod,web`. Tags allow letters, numbers, `-`, `_`, `/` only. No spaces. |
| `--ca-bundle FILE` | Full PEM bundle (system roots plus your proxy CA). See [Corporate TLS proxy](#corporate-tls-proxy). |
| `--output FILE` | With `--file`: where to write the patched JSON. |
| `--out DIR` | Output directory for original and patched JSON. Default `./falcon-ecs-patch-out`. |
| `--deploy` | Register the patched revision and update the service. The new task definition ARN is printed on stdout. |
| `--yes` | Skip the `--deploy` confirmation prompt (needed in CI). |
| `--fail-on-unprotected` | `audit` exits 3 if any unprotected Fargate service exists. |

The Falcon client secret is read from `FALCON_CLIENT_SECRET` only. Flags show up in process lists and CI logs, so the script rejects `--client-secret`.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success (including "already protected, nothing to do") |
| 1 | Error |
| 2 | Usage error |
| 3 | `audit --fail-on-unprotected` found unprotected services |

## Before you deploy

- **Infrastructure as code.** If Terraform, CDK, or CloudFormation owns the task definition, a revision registered with `--deploy` is overwritten on the next apply and the sensor silently disappears. Patch where the definition is authored instead: use `patch --file` in your pipeline and register the output, or use CrowdStrike's [Terraform module](https://github.com/CrowdStrike/terraform-aws-ecs-fargate).
- **Network.** Tasks need a route to the Falcon cloud on TLS 443: a public IP or a NAT gateway. Private subnets with no egress will start the task but never register a sensor. `patch` warns when a service has `assignPublicIp: DISABLED`.
- **Rollout.** `patch` prints the service's minimum and maximum healthy percent, task size, and whether the deployment circuit breaker is on. Turn the circuit breaker on so a failed rollout rolls back by itself. A service with 100% minimum healthy needs capacity for the extra tasks during the rollout.
- **Resources.** The sensor shares the task's CPU and memory with your app. Check task size and utilization on a non-production service first.
- **Deployment controllers.** For services using `CODE_DEPLOY` (blue/green) or `EXTERNAL`, `patch` registers the revision but does not update the service. Deploy the printed ARN with your own process.

## Upgrading the sensor

A task definition that already has the init container is skipped, so re-running `patch` does not change the sensor version. To move to a newer sensor, copy the new image, then patch the original, unpatched revision again:

```bash
./falcon-ecs-patch.sh setup
./falcon-ecs-patch.sh audit --cluster my-cluster          # SENSOR column shows what runs today
./falcon-ecs-patch.sh patch --cluster my-cluster --service my-service --from-revision 1 --deploy
```

`--from-revision` takes the revision that has no sensor (revision 1 in this example). With `--file`, patch your unpatched source file again.

## What gets changed in a task definition

Per application container: `entryPoint` is wrapped so the sensor starts first, `FALCONCTL_OPTS` carries the CID, `SYS_PTRACE` is added, and `/tmp/CrowdStrike` is mounted read-only. Per task: a `crowdstrike-falcon-init-container` (non-essential, exits 0 after copying the sensor) and a shared volume. The diff printed by `patch` shows all of it.

`patch` is idempotent: a task definition that already has the init container is skipped.

The patched JSON contains your CID in `FALCONCTL_OPTS` and the diff prints it. A CID is an identifier, not a secret, but avoid pasting diffs into public places.

## Rollback

`--deploy` prints the exact command, for example:

```bash
aws ecs update-service --cluster my-cluster --service my-service \
  --task-definition arn:aws:ecs:us-east-1:111122223333:task-definition/my-service:1 --region us-east-1
```

## Multiple accounts and regions

`setup` copies the sensor into one account and region. Run it, and `patch`, once per account and region, with credentials for that account (`AWS_PROFILE` or a role per job). Tasks pull the image with the task execution role, so the image has to be reachable from where the task runs. To share one ECR repository across accounts, add a repository policy that allows `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`, and `ecr:BatchCheckLayerAvailability` for the other accounts' execution roles, and pass `--sensor-image` with the full URI.

## Permissions

The identity running the script needs, at minimum:

- ECS: `ListServices`, `DescribeServices`, `DescribeTaskDefinition`, `RegisterTaskDefinition`, `UpdateService`
- ECR: `GetAuthorizationToken`, `DescribeImages`, `BatchGetImage`, `GetDownloadUrlForLayer`, `BatchCheckLayerAvailability`, and for `setup` also `CreateRepository`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage`
- IAM: `iam:PassRole` for the task and execution roles on `RegisterTaskDefinition`, and optionally `iam:SimulatePrincipalPolicy` for the execution-role check

At runtime, the task **execution role** must be able to pull the sensor image from ECR (`AmazonECSTaskExecutionRolePolicy` covers it for same-account ECR). `patch` warns if it cannot confirm this.

## Network

Fargate tasks need a route to the Falcon cloud: a public IP or a NAT gateway. `patch` warns when a service has `assignPublicIp: DISABLED`.

## Corporate TLS proxy

If a proxy (for example Zscaler) re-signs TLS, the patching container does not trust it and fails with a misleading `credentials tried: N` error. Pass a **full** CA bundle (system roots plus the proxy CA, not just the proxy CA):

```bash
./falcon-ecs-patch.sh patch ... --ca-bundle /path/to/full-bundle.pem
```

If `SSL_CERT_FILE` is already set on the host, the script uses it automatically.

## Apple Silicon

Fargate runs x86_64, so the script forces `--platform linux/amd64` for the patching container. If `patch` reports that the sensor has no `linux/amd64` build, re-run `setup` into a fresh repo with `--sensor-repo <name>/falcon-container`.

## Private registries other than ECR

For application images outside ECR, set `IMAGE_PULL_TOKEN` to a base64-encoded Docker config JSON with credentials for that registry, and configure `repositoryCredentials` in your task definition so ECS can pull at runtime. See the official documentation below.

## CI/CD

Pick the pattern that matches how you deploy:

| You deploy with | Use |
|-----------------|-----|
| A task definition JSON in Git, registered by your pipeline | `patch --file in.json --output out.json`, then register `out.json` |
| Terraform, CDK, or CloudFormation | Patch the source or use the Terraform module. Do not register revisions behind its back |
| A revision already registered in ECS | `patch --family F --deploy --yes`, then point the service at the ARN printed on stdout |

Store `FALCON_CID`, `FALCON_CLIENT_ID`, and `FALCON_CLIENT_SECRET` in your CI secret store, and use short-lived AWS credentials (OIDC role). Examples live in [`examples/`](examples):

- `github-actions-patch.yml` patches a task definition file and deploys the patched file.
- `github-actions-audit.yml` fails a scheduled job when an unprotected service appears.

## Not supported yet

EC2 launch type, ARM64 tasks, rewriting Terraform or CloudFormation source, automatic sensor upgrades (see [Upgrading the sensor](#upgrading-the-sensor) for the manual path).

## References

- [Deploy Falcon Container Sensor for Linux on ECS Fargate](https://docs.crowdstrike.com/r/en-US/iopiipqy/ba83eb6c)
- [CrowdStrike Terraform module for ECS Fargate](https://github.com/CrowdStrike/terraform-aws-ecs-fargate)
- [falcon-container-sensor-pull](https://github.com/CrowdStrike/falcon-scripts/tree/main/bash/containers/falcon-container-sensor-pull)
- Companion lab: ECS Fargate task patching in falcon-cloud-security-labs

## License

MIT. See [LICENSE](LICENSE).
