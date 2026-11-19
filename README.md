# falcon-ecs-patch

Repeatable patching of Amazon ECS Fargate task definitions with the CrowdStrike Falcon Container sensor.

This is a thin, non-interactive wrapper around the official patching utility that ships inside the `falcon-container` image. It is meant for operational use: run it by hand today, then drop it into a CI/CD pipeline so every new task definition revision is protected.

> **Status:** Work in progress. Not yet released.

## Planned modes

| Mode | What it does |
|------|--------------|
| `audit` | Read-only. Lists every service in a cluster and marks it protected or unprotected. |
| `patch` | Exports a task definition, patches it, and shows a diff. Add `--deploy` to register the revision and update the service. |

## Companion lab

Step-by-step walkthrough: ECS Fargate task patching in the falcon-cloud-security-labs repo.

## References

- [Deploy Falcon Container Sensor for Linux on ECS Fargate](https://docs.crowdstrike.com/r/en-US/iopiipqy/ba83eb6c)
- [falcon-container-sensor-pull](https://github.com/CrowdStrike/falcon-scripts/tree/main/bash/containers/falcon-container-sensor-pull)
